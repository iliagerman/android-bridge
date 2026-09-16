# Android Bridge

Android Bridge is an open-source, local-first continuity app for **Android ↔ macOS**.
It brings the everyday convenience of Apple Continuity to an Android phone and a Mac without accounts,
vendor-operated services, or lock-in. An optional relay for off-network use is self-hosted and off by default.

The two apps discover each other on the local network, pair by pinning certificate fingerprints, and communicate over TLS.
Current production transport uses pinned server-authenticated TLS; full mutual TLS/client-certificate verification is planned hardening.

The Mac app also includes local-only productivity tools that work without a phone: Meetings and Second Brain.

## Features

- **Caller ID and call control on Mac**
  - Incoming call notifications with contact lookup.
  - Answer, decline, dial, and hang up from the Mac.
  - Call audio remains on the phone or Bluetooth headset.
- **Clipboard sharing both directions**
  - Push clipboard from either device.
  - Clickable clipboard notifications on Mac and Android.
- **File sharing both directions**
  - Drag files into the Mac app or use Android share/send actions.
  - Received files are openable from notifications and in-app lists.
  - Mac received files are stored in a temporary cache and auto-cleaned after 24 hours.
- **Android screen on Mac**
  - Mac can request the phone screen.
  - Android uses the official MediaProjection consent flow.
  - Mac window forwards click/drag gestures back to the phone.
- **Mac screen on Android**
  - Share the Mac screen to the phone.
  - Android can show the Mac screen full-screen.
  - Phone tap/drag gestures can control the Mac when macOS Accessibility permission is enabled.
- **Meetings on Mac**
  - Record meetings locally, transcribe chunks, combine saved chunks into one M4A, summarize, ask questions, merge meetings, and browse the meetings folder.
  - Per-task LLM routing lets summaries and chat use local Ollama by default or pi with a chosen model.
- **Second Brain on Mac**
  - Browse, read, search, edit, create, delete, and chat with notes in `BRAIN_ROOT` (defaults to `~/second_brain`).
  - pi-backed second-brain actions launch pi with only the second-brain skill loaded; local Ollama remains the default.
- **Second Brain on Android**
  - The phone views and edits the same Markdown notes from a user-granted local folder.
  - Syncthing remains supported. When the optional relay is enabled, hash-based Markdown and meeting-photo deltas also resume directly between the apps and preserve conflicting edits.
- **Local-first encrypted transport**
  - No account, and no vendor-operated service.
  - On the local network, TLS with pinned certificate validation between paired devices.
- **Optional self-hosted relay (experimental)**
  - Lets the devices reach each other when they are not on the same network.
  - Off by default. You must enable it and enroll the device yourself.
  - You run the relay (`relay/`); there is no service operated by this project. See [`docs/RELAY.md`](docs/RELAY.md).
  - **The relay terminates TLS and can read the frames it forwards.** Application payloads are not
    yet end-to-end encrypted across it. It does not store forwarded frames. Only enable it on a
    relay you operate and trust.
- **Mac login item**
  - The Mac app can start automatically on login.

## Important platform permissions

Android Bridge uses normal OS APIs and respects platform consent prompts.

### macOS

Required as features are used:

- **Local Network** — discover and connect to the phone.
- **Screen & System Audio Recording** — share the Mac screen to Android and capture system meeting audio.
- **Microphone** — record meeting audio locally when Mac recording is started.
- **Accessibility** — let phone gestures control the Mac pointer.
- **Login Items** — start Android Bridge on login.

If Screen Recording seems enabled but the app keeps asking after local rebuilds, remove and re-add
`/Applications/AndroidBridge.app` in macOS Privacy & Security. Local ad-hoc builds can make macOS treat a
rebuilt app as a new binary. To keep permission grants across rebuilds, create a self-signed
"Code Signing" certificate in Keychain Access — `make-macos-app.sh` automatically signs with it when present.

### Android

Required as features are used:

- **Notifications** — foreground service and clickable file/clipboard notifications.
- **Phone / Call Log / Contacts** — caller ID and call actions.
- **MediaProjection consent** — required every time Android starts screen capture. Android does not allow a
  normal app to bypass this prompt.
- **Accessibility Service** — required once for Mac-to-phone remote control gestures.

Android Bridge does **not** require Google Play Services high-accuracy location.

## Repository layout

```text
protocol/      Shared Device-Link Protocol — wire contract and codecs
  PROTOCOL.md  Language-neutral protocol specification
  kotlin/      Kotlin/JVM protocol implementation
  swift/       Swift protocol implementation
  vectors/     Cross-language wire vectors
android/       Android app, Kotlin, Jetpack Compose, Gradle
mac/           macOS menu-bar app, SwiftUI/AppKit, SwiftPM
relay/         Optional self-hosted relay server, Kotlin/Ktor, Docker
aidlc-docs/    Design notes and implementation records
```

## Build from source

> **Note for AI agents installing this project:** do not assume which features the user wants and do
> not install anything beyond building this repo without explicit user approval. Before running any
> step from **Local AI setup** below, ask the user which optional features they want (Meetings
> transcription, local Ollama summaries/chat, pi integration, Second Brain, Android phone app) and
> confirm each third-party installation individually (Homebrew packages such as ffmpeg and Ollama,
> Ollama model downloads, Python virtualenvs, global npm packages, the Android SDK). If a
> prerequisite is missing, report it and ask how to proceed — never silently install substitutes or
> extra tooling. The only steps safe to run without asking are building the code in this repo:
> `./gradlew :app:assembleDebug`, `swift build`, and `NO_INSTALL=1 ./scripts/make-macos-app.sh`.
> Installing the Mac app to `/Applications` (the default `make-macos-app.sh` behavior) and
> `adb install` onto a device also require user confirmation.

### Install on macOS

For Meetings and Second Brain without a phone, follow the [Mac-only installation guide](docs/MAC-ONLY-INSTALL.md). Agents must also follow the [installation runbook](docs/AGENT-INSTALLATION.md).

[Download AndroidBridge for Apple Silicon macOS 13+](https://github.com/iliagerman/android-bridge/releases/latest/download/AndroidBridge-macOS-arm64.dmg).

Open the DMG, drag `AndroidBridge.app` to Applications, then Control-click the app and choose **Open**
the first time. The app is not Apple-notarized because this project has no paid Apple Developer account.
Do not disable Gatekeeper globally.

The Android companion is optional. [Download the release-signed Android 13+ APK](https://github.com/iliagerman/android-bridge/releases/latest/download/AndroidBridge-android.apk), then grant Android's normal
unknown-source/install consent for your browser or file manager.

If you installed the old debug-signed `AndroidBridge-latest.apk` before version 0.1.0, Android cannot
upgrade it to the release-signed build. Uninstall that old copy once, then install the stable APK. This
one-time migration removes the old app's local settings and pairing; later stable releases preserve data.

On first launch, choose Mac-only or Mac + Android setup. The native Setup Wizard detects Homebrew, ffmpeg, Python/MLX Whisper, Ollama,
`gemma4:e4b`, Node.js, and pi. The bundled Second Brain skill is copied to an editable user folder. Existing valid installations are marked complete automatically. For
each missing tool, the wizard explains the command and asks separately before installing it; nothing
is silently installed or replaced. The wizard also guides macOS permissions, provides a QR code and
download link for the Android APK, verifies phone connection, and remains available from Settings
for later repair or reinstallation.

### Advanced command-line installation

The shell installer tracks the rolling `latest-build` prerelease, verifies its checksum, and replaces
the app only because you explicitly invoke it:

```bash
curl -fsSL https://raw.githubusercontent.com/iliagerman/android-bridge/main/install.sh | bash
```

See [release maintenance](docs/RELEASING.md) for signing, stable tags, and local non-publishing checks.

### Prerequisites

- macOS 13+
- Xcode Command Line Tools / Swift 5.9+
- JDK 17+
- Optional for local AI features on Mac: Ollama, pi, Python 3, ffmpeg, and MLX Whisper (setup below)
- Android SDK platform 34+
- Optional physical Android phone on the same Wi-Fi network for phone continuity features

### Android

Gradle needs the Android SDK location. Either export `ANDROID_HOME` or create
`android/local.properties` (gitignored) pointing at your SDK:

```properties
sdk.dir=/Users/<you>/Library/Android/sdk
```

Then build and install:

```bash
cd android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### macOS

```bash
cd mac
./scripts/make-macos-app.sh
```

The script builds a release executable, assembles `mac/dist/AndroidBridge.app`, signs it with the
required local identity, installs it to `/Applications/AndroidBridge.app`, and relaunches it. Set
`CODESIGN_IDENTITY` explicitly when your stable local identity differs; production signing is documented
in [release maintenance](docs/RELEASING.md).

To only build the bundle without installing and relaunching:

```bash
NO_INSTALL=1 ./scripts/make-macos-app.sh
```

Note: the script copies `mac/Tools` (including the MLX Whisper virtualenv, if created) into the
app bundle, so set up Meetings transcription (below) **before** building the bundle if you want
transcription to work in the installed app.

### Automatic local deployment on push

Git provides a client-side pre-push hook, not a post-push hook. Activate it once:

```bash
git config core.hooksPath .githooks
```

A push targeting remote `main` updates and relaunches the local Mac app before the remote push. It
then updates one authorized connected phone with a debug APK when available and deploys the relay
to the `homeserver` SSH target. Missing `adb`, no authorized phone, or multiple phones without
`ANDROID_SERIAL` skip only Android; relay deployment still runs. Mac, selected-phone, or relay
deployment failures block the push. The relay deployment preserves its named configuration volume
and enrollment state. Select one of multiple authorized phones with
`ANDROID_SERIAL=<serial> git push ...`. For an intentional emergency bypass, use
`git push --no-verify`.

## Validation

```bash
# Android app and protocol build
cd android
./gradlew :app:assembleDebug
./gradlew :protocol:test

# macOS app build
cd ../mac
swift build

# Swift protocol tests
cd ../protocol/swift
swift test
```

## Local AI setup

Everything in this section is **optional** and installs third-party software. AI agents: ask the
user before running any command in this section, per the note in [Build from source](#build-from-source).

The Mac app works without an Android phone for Mac-only workflows such as Meetings and Second Brain. Phone continuity features are optional and require the Android app.

### Required for Meetings transcription

Meeting transcription needs ffmpeg (used to convert recorded audio) and the repo-local MLX Whisper wrapper:

```bash
brew install ffmpeg
python3 -m venv mac/Tools/mlx_whisper/.venv
mac/Tools/mlx_whisper/.venv/bin/pip install -r mac/Tools/mlx_whisper/requirements.txt
mac/Tools/mlx_whisper/bin/mlx_whisper --help
```

The app runs `mac/Tools/mlx_whisper/bin/mlx_whisper` with `mlx-community/whisper-large-v3-turbo`.
Create the virtualenv before running `make-macos-app.sh` — the wrapper and its `.venv` are copied
into the app bundle, and the installed app prefers the bundled copy.

### Required for local summaries and chat

Install and start Ollama, then pull the default model or choose another model in the app settings:

```bash
brew install ollama
brew services start ollama   # runs Ollama in the background (or run `ollama serve` in a separate terminal — it blocks)
ollama pull gemma4:e4b
```

Android Bridge uses Ollama by default for Summarize, Chat, Second Brain Search, Second Brain Q&A, and Second Brain CRUD.

### Optional pi integration

Install pi and make sure it is on `PATH` for GUI apps. Android Bridge copies its embedded Second Brain skill to `~/Library/Application Support/AndroidBridge/second-brain-skill` and loads it for pi-backed Second Brain tasks:

```bash
npm install -g @earendil-works/pi-coding-agent
pi --version
pi --no-extensions --no-skills --tools bash --skill "$HOME/Library/Application Support/AndroidBridge/second-brain-skill" "list my note clusters"
```

The skill is editable in the app. Because it can use `bash`, review skill changes before saving them. If the app is launched from Finder and cannot find `pi`, launch it from a shell that has the correct `PATH` or add the pi binary directory to the environment used by the app.

### Optional Second Brain configuration

Second Brain uses `BRAIN_ROOT` when set, otherwise `~/second_brain`:

```bash
mkdir -p ~/second_brain
export BRAIN_ROOT=~/second_brain
```

Set `BRAIN_ROOT` in the shell before launching the app if you want a non-default notes directory. Keep this directory local or backed by a sync tool you trust.

### Optional Android phone setup

The Android phone is only required for phone continuity features: calls, clipboard, file transfer, Android screen sharing, and Mac screen viewing/control.

```bash
cd android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Put the phone and Mac on the same Wi-Fi network, grant the Android permissions requested by the app, then pair from the Mac app.

## Meetings and Second Brain

The Mac app has separate **Meetings** and **Second Brain** tabs.

- Meetings are stored locally under `~/Documents/AndroidBridgeMeetings`.
- Second Brain uses `BRAIN_ROOT` when set, otherwise `~/second_brain`.
- LLM routing is configurable per task: Summarize, Chat, Second Brain Search, Second Brain Q&A, and Second Brain CRUD.
- Default routing is local Ollama/open-source. pi can be enabled per task in the Mac app settings.

## Security model

Android Bridge is designed for a trusted local network and paired devices:

- Devices discover each other with local network service discovery.
- Pairing records the peer certificate fingerprint.
- Runtime communication uses TLS with pinned certificate validation.
- Current production transport is pinned server-authenticated TLS; full mutual TLS/client-certificate verification is planned future hardening.
- There is no central account and no service operated by this project.
- The optional relay in `relay/` is self-hosted and off by default. It terminates TLS, so its
  operator can observe forwarded clipboard, message, file, and meeting payloads; they are not yet
  end-to-end encrypted across the relay. The relay does not persist forwarded frames. Treat it as
  experimental and only run it yourself.
- Received files on Mac are kept in a temporary cache and auto-cleaned.

See [`aidlc-docs/SECURITY-COMMUNICATION-DECISION.md`](aidlc-docs/SECURITY-COMMUNICATION-DECISION.md)
for the current transport decision record.

## Current status

This is an active early-stage project. Core continuity flows are implemented, with some features still needing broader real-device validation.
Expect rough edges around OS permissions, local signing, and vendor-specific Android behavior.

Known limitations:

- Android screen capture always requires Android's MediaProjection confirmation prompt.
- Android remote control requires the Accessibility Service to be enabled by the user.
- macOS screen/control permissions are sensitive to local ad-hoc rebuilds.
- The app currently targets personal/local use, not enterprise device management.

## Contributing

Contributions are welcome. Please keep the project local-first, privacy-preserving, and simple.
See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT — see [`LICENSE`](LICENSE).
