# Security Policy

Android Bridge is a local-first continuity app. Security reports are welcome.

## Supported versions

Only the latest published release receives fixes. The `main` branch is the active development line.
Older tags are not patched — upgrade before reporting an issue against an old build.

## Reporting a vulnerability

Report privately through GitHub:
<https://github.com/iliagerman/android-bridge/security/advisories/new>

Expect an acknowledgement within 7 days. Please do not publish exploit details before there is a fix
or a documented mitigation.

## Security expectations

Android Bridge should:

- communicate only with paired devices;
- use pinned TLS for device-to-device traffic;
- avoid cloud relays and third-party analytics;
- avoid logging private content such as clipboard text, SMS bodies, phone numbers, and file contents;
- store received files only where the user expects, with cleanup for temporary cache storage;
- require explicit platform permission for screen capture and remote control.

## Non-goals

Android Bridge does not try to bypass Android MediaProjection consent, Android Accessibility consent, or macOS privacy permissions.
