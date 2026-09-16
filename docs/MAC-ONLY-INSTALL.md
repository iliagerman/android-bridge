# Mac-only installation

This setup records and transcribes meetings on a Mac and manages a local Second Brain. It does not require an Android phone, Android Studio, the Android SDK, Java, ADB, a relay server, or phone permissions.

## Requirements

- Apple Silicon Mac
- macOS 13 or newer
- Internet access during installation and the first Whisper model download
- Enough free disk space for Python packages, the Whisper model, and recordings

## Install the app

1. Download [AndroidBridge for Apple Silicon](https://github.com/germanilia/android-bridge/releases/latest/download/AndroidBridge-macOS-arm64.dmg).
2. Open the DMG and drag `AndroidBridge.app` to Applications.
3. Control-click `AndroidBridge.app`, choose **Open**, then confirm **Open**. The app is signed but not Apple-notarized. Do not disable Gatekeeper.
4. In the setup wizard, choose **Mac only**.

The command-line installer is also available. It installs the rolling build rather than the latest stable release:

```bash
curl -fsSL https://raw.githubusercontent.com/germanilia/android-bridge/main/install.sh | bash
```

## Choose what to install

The setup wizard detects existing tools. It asks before every third-party installation.

For local transcription, install:

- Homebrew, only if it is not already installed
- ffmpeg
- Python
- MLX Whisper

For summaries and Q&A, choose one provider:

- **Ollama** keeps model inference local. Install Ollama and one model. The default is `gemma4:e4b`.
- **pi** uses the model provider configured in pi. Install Node.js and pi. Provider credentials remain pi's responsibility. Second Brain pi tasks load the editable skill and allow its `bash` tool, so review skill changes before saving them.
- **Neither** is valid when only recording, transcription, and manual Second Brain editing are needed. AI summaries and Q&A will be unavailable.

The Second Brain skill ships inside the app. On first launch, Android Bridge copies it to:

```text
~/Library/Application Support/AndroidBridge/second-brain-skill
```

The copy survives app updates. Edit `SKILL.md` in **Settings > Paths > Edit embedded Second Brain skill**. **Restore bundled version** replaces only `SKILL.md` after explicit confirmation by button click. It does not replace notes.

Existing installations that already use `~/.agents/skills/second-brain` keep that skill path.

## Choose storage locations

Defaults:

```text
Meetings:     ~/Documents/AndroidBridgeMeetings
Second Brain: ~/second_brain
```

Change either path in **Settings > Paths**. Choose an existing Second Brain folder to keep using it. Back it up before first use if it contains important notes. Android Bridge initializes a new brain with a root `index.md` when the first Second Brain operation runs.

## Grant Mac permissions

Grant only permissions needed by the selected features:

- **Microphone** records your microphone.
- **Screen & System Audio Recording** captures the other participants' audio.
- **Calendar** is optional. It matches recordings with local calendar events.
- **Notifications** is optional but useful for recording and processing status.

Mac-only setup does not need Local Network or Accessibility permission.

## Verify the setup

1. Open **Meetings** and record a short test containing microphone and system audio.
2. Stop the recording. Confirm the meeting folder contains audio, `transcript.jsonl`, and `notes.md`.
3. If summaries are enabled, confirm a summary appears.
4. Open **Second Brain** and create a test note.
5. Confirm `~/second_brain/index.md` exists and links remain valid after editing or deleting the test note.

If transcription fails, reopen **Settings > Setup Wizard**, verify ffmpeg, Python, and MLX Whisper, then use **Re-transcribe** on the test meeting.
