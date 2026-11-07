# Anime Sync for iPhone

A native iPhone companion for an Anime Sync server, an Anime Sync TV receiver and the Miruro website. The interface includes an automatically hidden sidebar, three-poster portrait rows with sideways scrolling, a synced library, named episode windows with watched markers, native playback and TV controls.

## Build and validate

Requires macOS with Xcode16.4 and Python3; the deployment target is iOS17. No third-party Swift packages are required. Roboto Bold and its OFL1.1 license are bundled for the native subtitle renderer.

```sh
python3 tools/generate-project.py --check
python3 -m unittest discover -s tools -p 'test_*.py'
QA_FOCUS=fixtures bash tools/test-simulator.sh
bash tools/build-device.sh
```

The workflow uses pinned actions and the standard `macos-15-intel` runner. Standard GitHub-hosted runners are free for public repositories; larger runners and other usage limits have different rules. See [GitHub runner documentation](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories).

Mac jobs are gated to public repositories to avoid private-runner charges. The device workflow runs on branches `main` and `codex/ios-companion` when `.github/ios-device-build.json` changes. Ordinary source and documentation pushes do not start a Mac build. The `[qa-fixtures]` commit tag also selects app-hosted units and deterministic UI fixtures. The separate live public-site check can require human verification and is not counted as passed by fixture selection. See [QA.md](QA.md).

## Personal configuration stays local

The public source and public IPA contain generic example server settings. No account, TV pairing, Apple signing identity or private network routing is supplied by CI. A public artifact containing `Deployment.json` is rejected before publication.

Create an ignored `.private/Deployment.json` locally using the documented configuration fields:

```json
{
  "homeURL": "https://home.example",
  "tailnetURL": "https://remote.example:8443",
  "connectOverrides": {"home.example": "10.0.0.10"},
  "defaultTVHost": "10.0.0.20"
}
```

Use your own server origins and private addresses. Origins must use HTTPS without credentials, a path, query or fragment, on port443 or8443. Routing overrides are limited to configured server hostnames and RFC1918 IPv4 destinations; TLS still verifies the original server hostname. The override object and default TV address may be empty. Keep this file private.

After downloading and verifying an unsigned public device IPA, apply the profile locally:

```sh
python3 tools/personalize-ipa.py \
  --input dist/AnimeSync-for-local-signing.ipa \
  --profile .private/Deployment.json \
  --output .private/AnimeSync-personal.ipa
```

The tool preserves the input, validates its device platform and resources, adds the profile only to a separate output, and prints a receipt without endpoint values. Never upload the personalized IPA or profile to a public repository or workflow artifact.

Sign and install the personalized IPA locally with your chosen signing tool. Apple credentials and verification codes stay in that tool. Preserve the bundle identifier and signing identity when updating an existing installation so its device Keychain and cookies remain accessible. Free Apple accounts require periodic signing renewal.

## Sign in and TV control

Open Anime Sync in the sidebar and sign in on the device. Dashboard cookies stay in a dedicated dashboard profile; native sync and TV pairing tokens stay in the device Keychain. Provider pages do not receive those credentials.

Choose Connect TV and enter its private address and the six-digit code shown by the receiver. Allow Local Network access when iOS asks. Pairing is device-local. The TV has one controller; another paired device must explicitly confirm a takeover. Commands and handoffs retain the observed control revision.

For remote use, enable your VPN and its home subnet route. Remote-network playback and TV control need separate device testing.

## Playback and progress

Native playback supports available HLS and MP4 sources. Unsupported formats and website-only players have an explicit website fallback. Source and audio options come from the current website player.

Subtitles use bold white text, a crisp black outline and a transparent background, with adjustable size and position. External VTT/SRT and plain ASS/SSA text are supported; complex typesetting can differ, and text baked into video cannot be restyled. The bundled face matches the visual reference; it is not a verified identification of the website font.

Continue reads current server history before playback. Ownership generations and monotonically increasing saves prevent a stale device from overwriting a newer session. Watched markers use actual completion records. Automatic restoration needs captured ownership; explicit Play can deliberately resume the latest checkpoint.

Miruro supplies catalogue and playback sources. This integration is independent of that service. Third-party artwork, icons and font notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
