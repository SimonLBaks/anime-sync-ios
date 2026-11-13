#!/usr/bin/env python3
"""Generate the dependency-free, deterministic Xcode project and shared scheme."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'AnimeSync.xcodeproj'

class Ref(str):
    pass


def emit(value, level=0):
    if isinstance(value, Ref):
        return str(value)
    if isinstance(value, dict):
        pad = '    ' * level
        return '{\n' + ''.join('    ' * (level + 1) + str(key) + ' = ' + emit(item, level + 1) + ';\n' for key, item in value.items()) + pad + '}'
    if isinstance(value, (list, tuple)):
        return '(' + ', '.join(emit(item, level) for item in value) + ')'
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def generate():
    objects = {}
    def ident(name):
        return Ref(hashlib.sha256(name.encode()).hexdigest()[:24].upper())
    def add(object_name, isa, **values):
        key = ident(object_name)
        if key in objects:
            raise ValueError('Duplicate project object: ' + object_name)
        objects[key] = dict(isa=Ref(isa), **values)
        return key
    project_id = ident('project')
    app_target, unit_target, ui_target = (ident('target:' + name) for name in ('AnimeSync', 'AnimeSyncTests', 'AnimeSyncUITests'))
    app_swift = sorted(ROOT.glob('AnimeSync/**/*.swift'))
    unit_swift = sorted(p for p in ROOT.glob('Tests/**/*.swift') if p.name != 'QAAcceptanceTests.swift')
    ui_swift = sorted(ROOT.glob('Tests/**/QAAcceptanceTests.swift'))
    resources = sorted(ROOT.glob('AnimeSync/Provider/Resources/*.js'))
    fonts = sorted(ROOT.glob('AnimeSync/Resources/Fonts/*'))
    assets = ROOT / 'AnimeSync/Resources/Assets.xcassets'
    app_refs, test_refs, resource_refs, app_build, unit_build, ui_build, resource_build = [], [], [], [], [], [], []
    def file(path, kind):
        relative = path.relative_to(ROOT).as_posix()
        ref = add('file:' + relative, 'PBXFileReference', lastKnownFileType=kind, path=relative, sourceTree='<group>')
        return relative, ref
    for path in app_swift:
        relative, ref = file(path, 'sourcecode.swift'); app_refs.append(ref)
        app_build.append(add('build:app:' + relative, 'PBXBuildFile', fileRef=ref))
    for name, paths, builds in [('unit', unit_swift, unit_build), ('ui', ui_swift, ui_build)]:
        for path in paths:
            relative, ref = file(path, 'sourcecode.swift'); test_refs.append(ref)
            builds.append(add('build:' + name + ':' + relative, 'PBXBuildFile', fileRef=ref))
    for path in resources + fonts + [assets]:
        kind = 'folder.assetcatalog' if path == assets else 'sourcecode.javascript' if path.suffix == '.js' else 'text.json' if path.suffix == '.json' else 'text' if path.suffix == '.txt' else 'file'
        relative, ref = file(path, kind); resource_refs.append(ref)
        resource_build.append(add('build:resource:' + relative, 'PBXBuildFile', fileRef=ref))
    _, info_ref = file(ROOT / 'AnimeSync/Info.plist', 'text.plist.xml')
    app_refs.append(info_ref)
    products = []
    for name, product_type, extension in [('AnimeSync', 'wrapper.application', 'app'), ('AnimeSyncTests', 'wrapper.cfbundle', 'xctest'), ('AnimeSyncUITests', 'wrapper.cfbundle', 'xctest')]:
        products.append(add('product:' + name, 'PBXFileReference', explicitFileType=product_type, includeInIndex=0, path=name + '.' + extension, sourceTree=Ref('BUILT_PRODUCTS_DIR')))
    source_group = add('group:source', 'PBXGroup', name='AnimeSync Sources', children=app_refs, sourceTree='<group>')
    resource_group = add('group:resources', 'PBXGroup', name='Resources', children=resource_refs, sourceTree='<group>')
    test_group = add('group:tests', 'PBXGroup', name='Tests', children=test_refs, sourceTree='<group>')
    product_group = add('group:products', 'PBXGroup', name='Products', children=products, sourceTree='<group>')
    main_group = add('group:main', 'PBXGroup', children=[source_group, resource_group, test_group, product_group], sourceTree='<group>')
    def configs(name, settings):
        refs = []
        for mode in ['Debug', 'Release']:
            values = dict(settings)
            values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym')
            if mode == 'Debug':
                values.update(SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG', ENABLE_TESTABILITY=Ref('YES'))
            else:
                values.update(SWIFT_COMPILATION_MODE='wholemodule')
            refs.append(add('config:' + name + ':' + mode, 'XCBuildConfiguration', buildSettings=values, name=mode))
        return add('configlist:' + name, 'XCConfigurationList', buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
    project_settings = dict(CLANG_ENABLE_MODULES=Ref('YES'), IPHONEOS_DEPLOYMENT_TARGET='17.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0', SWIFT_STRICT_CONCURRENCY='minimal', ENABLE_USER_SCRIPT_SANDBOXING=Ref('YES'))
    project_configs = configs('project', project_settings)
    common = dict(CODE_SIGN_STYLE='Automatic', CURRENT_PROJECT_VERSION='30', MARKETING_VERSION='0.1.28', PRODUCT_NAME='$(TARGET_NAME)', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', TARGETED_DEVICE_FAMILY='1', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks'], SWIFT_VERSION='5.0')
    app_settings = dict(common, GENERATE_INFOPLIST_FILE=Ref('NO'), INFOPLIST_FILE='AnimeSync/Info.plist', PRODUCT_BUNDLE_IDENTIFIER='xyz.loibaks.animecompanion.ios', PRODUCT_MODULE_NAME='AnimeSync', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', APP_SOURCE_REVISION='local', OTHER_SWIFT_FLAGS=['$(inherited)', '-Xfrontend', '-warn-long-expression-type-checking=200', '-Xfrontend', '-warn-long-function-bodies=500'])
    unit_settings = dict(common, OTHER_SWIFT_FLAGS=app_settings['OTHER_SWIFT_FLAGS'], GENERATE_INFOPLIST_FILE=Ref('YES'), PRODUCT_BUNDLE_IDENTIFIER='xyz.loibaks.animecompanion.ios.tests', PRODUCT_MODULE_NAME='AnimeSyncTests', TEST_HOST='$(BUILT_PRODUCTS_DIR)/AnimeSync.app/AnimeSync', BUNDLE_LOADER='$(TEST_HOST)', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'])
    ui_settings = dict(common, OTHER_SWIFT_FLAGS=app_settings['OTHER_SWIFT_FLAGS'], GENERATE_INFOPLIST_FILE=Ref('YES'), PRODUCT_BUNDLE_IDENTIFIER='xyz.loibaks.animecompanion.ios.uitests', PRODUCT_MODULE_NAME='AnimeSyncUITests', TEST_TARGET_NAME='AnimeSync')
    for index, (name, builds, settings, kind) in enumerate([
        ('AnimeSync', app_build, app_settings, 'application'),
        ('AnimeSyncTests', unit_build, unit_settings, 'bundle.unit-test'),
        ('AnimeSyncUITests', ui_build, ui_settings, 'bundle.ui-testing'),
    ]):
        sources = add('phase:source:' + name, 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
        frameworks = add('phase:frameworks:' + name, 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
        resource_phase = add('phase:resources:' + name, 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=resource_build if index == 0 else [], runOnlyForDeploymentPostprocessing=0)
        dependencies = []
        if index:
            proxy = add('proxy:' + name, 'PBXContainerItemProxy', containerPortal=project_id, proxyType=1, remoteGlobalIDString=app_target, remoteInfo='AnimeSync')
            dependencies.append(add('dependency:' + name, 'PBXTargetDependency', target=app_target, targetProxy=proxy))
        add('target:' + name, 'PBXNativeTarget', buildConfigurationList=configs(name, settings), buildPhases=[sources, frameworks, resource_phase], buildRules=[], dependencies=dependencies, name=name, productName=name, productReference=products[index], productType='com.apple.product-type.' + kind)
    add('project', 'PBXProject', attributes=dict(BuildIndependentTargetsInParallel=Ref('YES'), LastUpgradeCheck='1640', TargetAttributes={app_target: dict(CreatedOnToolsVersion='16.4'), unit_target: dict(CreatedOnToolsVersion='16.4', TestTargetID=app_target), ui_target: dict(CreatedOnToolsVersion='16.4', TestTargetID=app_target)}), buildConfigurationList=project_configs, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=main_group, productRefGroup=product_group, projectDirPath='', projectRoot='', targets=[app_target, unit_target, ui_target])
    project = '// !$*UTF8*$!\n' + emit(dict(archiveVersion=1, classes={}, objectVersion=56, objects=dict(sorted(objects.items())), rootObject=project_id)) + '\n'
    def reference(target, product):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{product.split(".")[0]}" ReferencedContainer="container:AnimeSync.xcodeproj"/>'
    app_ref = reference(app_target, 'AnimeSync.app')
    entries = '\n'.join(f'<BuildActionEntry buildForTesting="YES" buildForRunning="{"YES" if index == 0 else "NO"}" buildForProfiling="{"YES" if index == 0 else "NO"}" buildForArchiving="{"YES" if index == 0 else "NO"}" buildForAnalyzing="YES">{reference(target, product)}</BuildActionEntry>' for index, (target, product) in enumerate([(app_target, 'AnimeSync.app'), (unit_target, 'AnimeSyncTests.xctest'), (ui_target, 'AnimeSyncUITests.xctest')]))
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>{entries}</BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO" codeCoverageEnabled="YES"><CommandLineArguments><CommandLineArgument argument="--qa-fixture" isEnabled="YES"/></CommandLineArguments><Testables>
  <TestableReference skipped="NO" parallelizable="NO">{reference(unit_target, 'AnimeSyncTests.xctest')}</TestableReference>
  <TestableReference skipped="NO" parallelizable="NO">{reference(ui_target, 'AnimeSyncUITests.xctest')}</TestableReference>
 </Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    return project, scheme, dict(appSwift=len(app_swift), unitSwift=len(unit_swift), uiSwift=len(ui_swift), javascript=len(resources), fonts=len([p for p in fonts if p.suffix == '.ttf']))


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
    project, scheme, counts = generate()
    files = {PROJECT / 'project.pbxproj': project, PROJECT / 'xcshareddata/xcschemes/AnimeSync.xcscheme': scheme}
    for path, content in files.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit('Generated project is stale: run python3 tools/generate-project.py')
        else:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(content)
    print(json.dumps(counts, sort_keys=True))

if __name__ == '__main__':
    main()
