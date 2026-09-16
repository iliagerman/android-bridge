# Installation runbook for agents

Use this runbook when a user asks an agent to install or configure Android Bridge. Ask the questions first. Do not infer optional features from the app name.

## Questions to ask

Ask these in one bounded message:

1. Is the Mac Apple Silicon and running macOS 13 or newer?
2. Which setup do you want?
   - Mac only for Meetings and Second Brain
   - Mac plus Android phone continuity
3. Do you want the latest stable DMG or the rolling command-line build? Recommend stable to normal users.
4. Which meeting audio should be captured?
   - Microphone only
   - Microphone and system audio
5. Where should meetings be stored? Default: `~/Documents/AndroidBridgeMeetings`.
6. Is this a new Second Brain or an existing one? What folder should it use? Default: `~/second_brain`.
7. If the brain already exists, is it backed up before the app writes to it?
8. Which AI option should summaries and Q&A use?
   - Local Ollama
   - pi and the user's configured provider
   - None
9. Should Android Bridge start at login?
10. May I install each missing third-party dependency? List the exact missing tools after detection and get approval before each install.

For Mac-only setup, state that no Android app, Android SDK, Java, ADB, relay, Local Network permission, or Accessibility permission will be installed or requested.

## Installation sequence

1. Record the user's answers.
2. Verify `uname -m` returns `arm64` and `sw_vers -productVersion` is at least 13.
3. Inspect existing installations. Do not replace a differently signed `/Applications/AndroidBridge.app` without explaining the signing mismatch.
4. Install the chosen app release only after approval.
5. Launch the app. Ask the user to complete Gatekeeper and macOS privacy prompts because these require human consent.
6. Select the requested setup mode in the wizard.
7. Detect dependencies before proposing installs.
8. For local transcription, request separate approval for missing Homebrew, ffmpeg, Python, and MLX Whisper components.
9. For Ollama, request separate approval for Ollama installation and model download. State the model name and approximate download impact when known.
10. For pi, request separate approval for Node.js and pi installation. Never request or expose model-provider secrets in chat or logs.
11. Set meeting and brain paths from the user's answers. Preserve an existing brain and skill directory.
12. Verify with one short recording and one disposable Second Brain note. Delete the test note only with user approval.

## Embedded skill rules

- The app bundles the Second Brain skill and copies an editable working version to `~/Library/Application Support/AndroidBridge/second-brain-skill` on first launch.
- Existing `~/.agents/skills/second-brain` installations remain selected.
- App updates preserve the editable working copy.
- Edit the skill through **Settings > Paths > Edit embedded Second Brain skill**.
- Never overwrite edited `SKILL.md` automatically. Use **Restore bundled version** only when the user requests it.
- Never edit notes as part of skill installation.

## Completion criteria

Installation is complete only when:

- the app launches from `/Applications`;
- setup mode matches the user's choice;
- selected dependencies show as installed;
- required macOS permissions are granted;
- a short recording produces an audio file and transcript;
- the configured Second Brain opens and can create a linked test note;
- AI summary or Q&A works when the user selected an AI provider;
- no Android component was installed for a Mac-only setup.

Report any failed criterion. Do not silently switch providers, paths, models, or setup modes.
