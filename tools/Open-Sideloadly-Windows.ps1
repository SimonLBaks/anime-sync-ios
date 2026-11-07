# Opens a previously validated unsigned device IPA in the signed-in desktop.
# This does not sign in, enter credentials, approve prompts, or claim installation.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IpaPath,
    [switch]$AutoStart
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$taskName = 'AnimeSync-OpenSideloadly-' + [Guid]::NewGuid().ToString('N')
$jobDirectory = Join-Path ([IO.Path]::GetTempPath()) $taskName
$helperPath = Join-Path $jobDirectory 'interactive.ps1'
$configPath = Join-Path $jobDirectory 'config.json'
$resultPath = Join-Path $jobDirectory 'result.json'
$folder = $null
$registered = $null
$running = $null
$status = [ordered]@{
    schema = 1; status = 'not_started'; fileLoaded = $false
    autoStartRequested = [bool]$AutoStart; startInvoked = $false
    localUserRequired = $false; credentialPromptDetected = $false
    windowFound = $false; idleConfirmed = $false; uiScanComplete = $false
    sessionVerified = $false; taskRemoved = $true; taskLeftovers = 0
    helperRemoved = $false; configRemoved = $false; resultPath = $resultPath
}
$exitCode = 1
try {
    $file = Get-Item -LiteralPath $IpaPath
    if ($file.PSIsContainer -or $file.Extension -ine '.ipa' -or $file.PSProvider.Name -ne 'FileSystem') { throw 'Expected an existing IPA file' }
    $executable = Join-Path $env:LOCALAPPDATA 'Sideloadly\sideloadly.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Sideloadly executable unavailable' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $status.ipaName = $file.Name
    $status.ipaSHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    [ordered]@{ ipa = $file.FullName; executable = $executable; user = $identity; result = $resultPath; autoStart = [bool]$AutoStart } |
        ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    @'
param([Parameter(Mandatory=$true)][string]$ConfigPath)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$answer = [ordered]@{
    status='failed'; fileLoaded=$false; startInvoked=$false; localUserRequired=$false
    credentialPromptDetected=$false; windowFound=$false; idleConfirmed=$false
    uiScanComplete=$false; sessionVerified=$false
}
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    if ((Get-Process -Id $PID).SessionId -ne 1 -or [Security.Principal.WindowsIdentity]::GetCurrent().Name -ine $config.user) {
        $answer.status='wrong_interactive_session'
    } else {
        $answer.sessionVerified=$true
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        # ArgumentList is a Windows command line, not a PowerShell expression.
        # A literal Windows filename cannot contain the enclosing double quote.
        Start-Process -FilePath $config.executable -ArgumentList ('"' + $config.ipa + '"') | Out-Null
        $expectedName = [IO.Path]::GetFileName([string]$config.ipa)
        while ($clock.Elapsed.TotalSeconds -lt 15) {
            $processes = @(Get-Process -Name sideloadly -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 1 -and $_.MainWindowHandle -ne [IntPtr]::Zero })
            $root = $null
            foreach ($candidate in $processes) {
                if ($candidate.Path -ieq $config.executable) { $root = [Windows.Automation.AutomationElement]::FromHandle($candidate.MainWindowHandle); break }
            }
            if ($null -eq $root) { Start-Sleep -Milliseconds 250; continue }
            $answer.windowFound=$true
            $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
            $queue = New-Object 'System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]'
            $queue.Enqueue($root)
            $nodes = New-Object 'System.Collections.Generic.List[System.Windows.Automation.AutomationElement]'
            $seen=0; $password=$false; $modal=$false
            while ($queue.Count -gt 0 -and $seen -lt 300 -and $clock.Elapsed.TotalSeconds -lt 15) {
                $node=$queue.Dequeue(); $seen++
                $kind=$node.Current.ControlType
                if ($kind -eq [Windows.Automation.ControlType]::Edit) {
                    # Never read Name/Value/Text or any descendant of an edit.
                    $secret=$node.GetCurrentPropertyValue([Windows.Automation.AutomationElement]::IsPasswordProperty,$true)
                    if ($secret -is [bool] -and $secret) { $password=$true }
                    continue
                }
                $nodes.Add($node)
                if ($node -ne $root -and $kind -eq [Windows.Automation.ControlType]::Window) { $modal=$true }
                $windowPattern=$null
                if ($kind -eq [Windows.Automation.ControlType]::Window -and $node.TryGetCurrentPattern([Windows.Automation.WindowPattern]::Pattern,[ref]$windowPattern)) {
                    if ($windowPattern.Current.IsModal) { $modal=$true }
                }
                $child=$walker.GetFirstChild($node)
                while ($null -ne $child -and ($queue.Count + $seen) -lt 300 -and $clock.Elapsed.TotalSeconds -lt 15) {
                    $queue.Enqueue($child); $child=$walker.GetNextSibling($child)
                }
            }
            $answer.uiScanComplete=($queue.Count -eq 0 -and $seen -lt 300 -and $clock.Elapsed.TotalSeconds -lt 15)
            $answer.credentialPromptDetected=($password -or $modal)
            if ($password -or $modal) { $answer.localUserRequired=$true; $answer.status='local_prompt_requires_user'; break }
            $start=$null; $idle=$false; $busy=$false; $loaded=$false
            foreach ($node in $nodes) {
                if ($clock.Elapsed.TotalSeconds -ge 15) { $answer.uiScanComplete=$false; break }
                # Read bounded non-edit labels only. No labels are ever emitted.
                $name=[string]$node.Current.Name
                if (-not $node.Current.IsOffscreen -and ($name.Trim() -ieq $expectedName -or $name.Trim() -ieq [string]$config.ipa)) { $loaded=$true; continue }
                if ($name.Length -gt 260 -or $name -match '@|(?i)apple\s*(id|account)|[0-9a-fA-F]{24,}') { continue }
                $name=$name.Trim()
                if ($name -match '(?i)password|verification code|two.factor|authentication required') {
                    $answer.credentialPromptDetected=$true; $answer.localUserRequired=$true; continue
                }
                if ($name -in @('Idle','Idle.','Ready','Ready.','Done','Done.')) { $idle=$true }
                if ($node.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $node.Current.IsEnabled -and -not $node.Current.IsOffscreen) {
                    if ($name -ceq 'Start') { $start=$node }
                    if ($name -in @('Stop','Cancel signing','Cancel installation')) { $busy=$true }
                }
            }
            $answer.fileLoaded=$loaded
            $answer.idleConfirmed=($idle -and -not $busy -and $null -ne $start -and -not $answer.credentialPromptDetected -and $answer.uiScanComplete)
            if ($answer.credentialPromptDetected) { $answer.status='local_prompt_requires_user'; break }
            if ($loaded) {
                $answer.status='ipa_loaded'
                if ($config.autoStart) {
                    if ($answer.idleConfirmed) {
                        # Revalidate the one exact, enabled Start control; do not
                        # invoke any login/password/2FA/file-picker controls.
                        $pattern=$null
                        if ($clock.Elapsed.TotalSeconds -lt 15 -and (Test-Path -LiteralPath $ConfigPath) -and $start.Current.IsEnabled -and $start.Current.Name -ceq 'Start' -and $start.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) {
                            $pattern.Invoke(); $answer.startInvoked=$true
                            $answer.localUserRequired=$true; $answer.status='start_invoked_check_local_prompts'
                        } else { $answer.localUserRequired=$true; $answer.status='start_not_invokable' }
                    } else { $answer.localUserRequired=$true; $answer.status='idle_not_proven' }
                }
                break
            }
            # A single-instance existing POC window may ignore the IPA argument.
            $answer.status='ipa_not_loaded'; Start-Sleep -Milliseconds 250
        }
        if (-not $answer.windowFound) { $answer.status='window_not_found' }
    }
} catch { $answer.status='interactive_helper_failed'; $answer.errorType=$_.Exception.GetType().Name }
finally {
    $answer.timestampUtc=[DateTime]::UtcNow.ToString('o')
    $pending=[string]$config.result + '.pending'
    $answer | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pending -Encoding UTF8
    [IO.File]::Move($pending,[string]$config.result)
}
'@ | Set-Content -LiteralPath $helperPath -Encoding UTF8
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $folder = $service.GetFolder('\')
    $definition = $service.NewTask(0)
    $definition.RegistrationInfo.Description = 'Temporary Anime Sync Sideloadly desktop opener; no saved credentials'
    $definition.Principal.UserId = $identity
    $definition.Principal.LogonType = 3 # TASK_LOGON_INTERACTIVE_TOKEN
    $definition.Principal.RunLevel = 0 # TASK_RUNLEVEL_LUA
    $definition.Settings.Enabled = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT2M'
    $definition.Settings.MultipleInstances = 2
    # No triggers: this GUID task is demand-only and deleted below.
    $action = $definition.Actions.Create(0)
    $action.Path = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $helperPath + '" -ConfigPath "' + $configPath + '"'
    $action.WorkingDirectory = $jobDirectory
    $registered = $folder.RegisterTaskDefinition($taskName,$definition,2,$identity,$null,3)
    $status.taskRemoved=$false; $status.taskLeftovers=1
    # TASK_RUN_USE_SESSION_ID (4), exact interactive session1, no password.
    # https://learn.microsoft.com/en-us/windows/win32/taskschd/registeredtask-runex
    $running = $registered.RunEx($null,4,1,$null)
    $wait = [Diagnostics.Stopwatch]::StartNew()
    while ($wait.Elapsed.TotalSeconds -lt 20 -and -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { Start-Sleep -Milliseconds 200 }
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $child = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        foreach ($property in $child.PSObject.Properties) { $status[$property.Name]=$property.Value }
        if ($status.fileLoaded -and (-not $AutoStart -or $status.startInvoked)) { $exitCode=0 }
    } else { $status.status='interactive_helper_timeout' }
} catch { $status.status='launcher_failed'; $status.errorType=$_.Exception.GetType().Name }
finally {
    # Delete only this invocation's exact GUID task and temporary helper/config.
    # On timeout stop this task first; never kill arbitrary Sideloadly/user tasks.
    if ($null -ne $folder) {
        try { if (-not (Test-Path -LiteralPath $resultPath) -and $null -ne $running -and $running.State -eq 4) { $running.Stop() } } catch { }
        try { $folder.DeleteTask($taskName,0) } catch { }
        try {
            $left = @($folder.GetTasks(0) | Where-Object { $_.Name -ceq $taskName })
            $status.taskLeftovers=$left.Count; $status.taskRemoved=($left.Count -eq 0)
        } catch { $status.taskRemoved=$false }
    }
    foreach ($path in @($helperPath,$configPath)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
    $status.helperRemoved=(-not (Test-Path -LiteralPath $helperPath))
    $status.configRemoved=(-not (Test-Path -LiteralPath $configPath))
    if (-not $status.taskRemoved -or -not $status.helperRemoved -or -not $status.configRemoved) { $exitCode=1; $status.status='cleanup_incomplete' }
    $status.timestampUtc=[DateTime]::UtcNow.ToString('o')
    if (Test-Path -LiteralPath $jobDirectory -PathType Container) {
        $status | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    }
}
$status | ConvertTo-Json -Depth 5
exit $exitCode
