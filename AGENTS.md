# Agent notes

Practical notes for AI agents working in this repo. These cover things that were
slow or non-obvious to find. Keep entries factual and update them when they drift.

## Installation work

When installing or configuring Android Bridge for another user, read `docs/AGENT-INSTALLATION.md` completely before running commands. It defines setup questions, consent gates, Mac-only behavior, and completion checks.

## Where things live

- `relay/` — Kotlin/Ktor relay server. Runs in Docker on the `homeserver` SSH host.
- `android/app/src/main/kotlin/com/androidbridge/` — Android app.
  - `relay/` — transport, sync, journal, replay.
  - `core/LinkManager.kt` — owns direct-vs-relay selection and both relay loops.
    This file is large; the relay logic is around lines 450–560.
- `mac/Sources/BridgeCore/Relay.swift` — the Mac peer of the sync protocol
  (single 784-line file; enrollment, transport, and replay are all in it).

The Android and Mac replay engines are **two independent implementations of the
same protocol**. When changing one, diff it against the other — they have already
drifted (see "Asymmetric validation" below).

## Getting relay logs

The relay is a Docker container named `android-bridge-relay` on the `homeserver`
SSH alias. There is no log file in the repo.

```sh
ssh homeserver 'docker logs --since 30m android-bridge-relay 2>&1'
```

Logs are one structured line per event, e.g.:

```
event=device_connected device_id=android-<uuid> result=connected byte_count=0
event=frame_forwarded  device_id=mac-<uuid>     result=forwarded byte_count=385
```

`device_id` is always the **sender**. Useful greps: `device_connected`,
`device_disconnected`, `frame_forwarded`, `request_rejected`, `request_failed`.

Log volume is high (~13k lines / 25 min while a sync loop is stuck), so always
pass `--since` and pipe through grep. Redirect to the scratchpad rather than
letting it land in context.

Undeliverable frames are recorded as `event=frame_undelivered` with
`result=peer_absent` or `result=peer_backpressure`.

**Durable logs:** the container also writes `/logs/relay.log` (volume
`android_bridge_relay_logs`), rolled daily with 4-day retention and a 512MB cap,
configured in `relay/src/main/resources/logback.xml`. `RELAY_LOG_DIR` relocates
it. Docker's `json-file` driver cannot rotate by time, so `docker logs` is capped
by size only (`max-size: 32m`, `max-file: 4`).

### Per-cycle analysis one-liner

macOS `awk` is BSD awk — it does **not** support 3-argument `match()`. Use `sed`
to reshape lines first, then `awk`. This prints frames/bytes per connection cycle:

```sh
grep -E "event=(frame_forwarded|device_connected|device_disconnected)" "$F" \
| sed -E 's/.*event=device_connected.*/CYCLE-START/;
          s/.*event=device_disconnected.*/CYCLE-END/;
          s/.*event=frame_forwarded device_id=([a-z]+)-.*byte_count=([0-9]+).*/\1 \2/' \
| awk '/CYCLE-START/{c++;a=0;m=0;ab=0;mb=0;next}
       /CYCLE-END/{if(c>0)printf "cycle %d: android=%d/%dB mac=%d/%dB\n",c,a,ab,m,mb;next}
       $1=="android"{a++;ab+=$2} $1=="mac"{m++;mb+=$2}'
```

Byte-identical totals across cycles is the signature of a replay loop.

## Getting Android logs

The phone is reachable over `adb`. The app logs through `System.out`, so lines
appear as `I/System.out(<pid>)`, **not** under a custom tag:

```sh
adb logcat -d -v time | grep -iE "relay"
```

Beware: a plain `grep -i relay` also matches Samsung platform noise
(`SconeRelayMetrics*`, `SconeAwareness`). Filter on `System.out` to get app lines.

App security events look like `[WARN] security.relay_sync_reject`. They carry
**no detail** — see the swallowed-exception note below.

## Fixed: one bad frame used to kill the whole relay connection

`LinkManager.relayReceiveLoop()` used to call `relayTransport.close()` whenever a
single inbound frame failed to decode or was rejected by the sync engine. Because
neither side committed progress before the socket died, the offending frame was
replayed on every reconnect — a permanent poison loop that flapped the link every
~6 seconds and re-sent the same journal batch indefinitely.

It now logs and skips only the offending frame:
`security.relay_frame_reject` carries `error=<exception class>`, and
`security.relay_sync_reject` carries `error=<exception class>` plus
`type=<protocol message type>`.

**Do not reintroduce a close here.** Dropping the link cannot discard a bad frame;
it only guarantees the frame comes back.

`RelayWebSocketTransport.onMessage(bytes)` had the same shape and was the close
that actually kept the link down: a full inbound channel produced
`close(1009, "receiver busy")`. The peer replays its whole journal on reconnect
(up to ~279 frames observed in one batch) which outran the 64-slot channel almost
immediately. It now blocks the OkHttp reader thread for up to 5s so TCP
backpressure reaches the relay, and drops the frame only if the consumer is still
behind. Capacity is 256. The 5s wait is deliberately under OkHttp's 10s
`pingInterval` so a slow consumer cannot trip the ping timeout instead.

**Diagnosing closes:** `RelayEvent.Closed` now carries the WebSocket `code` and
`reason`, logged as `relay_closed code=<n>,reason=<text>`; `RelayEvent.Failure`
logs as `relay_failed error=<class>`. Both were previously discarded, which is
why the first two fixes looked like they had done nothing.

Two things still to know when reading these logs:

1. Exception *messages* are deliberately not logged. `LinkLogger` forbids the key
   `message`, and a kotlinx-serialization exception string can embed payload
   content, which would violate the app's no-message-bodies logging contract. The
   exception class plus the protocol message type narrows a failure to one or two
   `require` calls in `RelaySync.kt`.
2. `inboundChannel` has capacity 64, so a batch of bad frames produces a **burst**
   of reject lines. Do not read the burst count as distinct faults.

Skipping a bad frame stops the flapping, but it does **not** repair diverged
journals. If a specific operation is permanently unacceptable to the peer, it will
still be replayed on every reconnect — now without killing the link. Watch for a
repeating `relay_sync_reject` with a constant `type`.

## Known trap: relay reconnect backoff never grows

`RelayReconnectBackoff` is exponential, but `adoptRelay()` resets
`relayReconnectAttempt = 0` on **every** successful open. If the connection dies
shortly after opening, the attempt counter never advances and the delay stays at
the ~1s floor. Add `DIRECT_ATTEMPT_MS` (`LinkManager.kt:1026`, currently
`5_000L`) and the observed reconnect gap is a flat ~6s, forever, regardless of
how long the failure has persisted. A flat 6s gap in the relay logs is this bug,
not a network problem.

## Known trap: asymmetric validation between Android and Mac

The two replay engines validate the same `SyncOperation` differently. For
`SNAPSHOT`:

- Android (`RelaySync.kt` `validateIncoming`) requires
  `messageType == null && resultDigest != null && blobDigest == resultDigest`.
- Mac (`Relay.swift` `prepare`) requires all of the above **plus**
  `mediaType != nil` **and** a non-nil `snapshotHandler`.

An operation Android considers valid and will replay forever can be permanently
rejected by the Mac. Any change to validation on one side must be mirrored on the
other, or it creates an unacknowledgeable operation.

## Fixed: relay error frames were matched by exact string

The relay sends errors as a JSON **text** frame; `ErrorResponse(val error: String)`
serializes to `{"error":"<code>"}`. `RelayWebSocketTransport.onMessage(text)` used
to compare against the literal `{"error":"peer_absent"}` and close with code 1003
on anything else — including `{"error":"peer_backpressure"}`, which the relay emits
whenever a peer send exceeds `RELAY_SEND_TIMEOUT_MILLIS` (default 5000).

It now extracts the code with a regex and never closes over it. `peer_absent` still
raises `RelayEvent.Waiting`; other codes are ignored client-side because the relay
records them server-side as `frame_undelivered`.

## Deploy trap: pushing does not necessarily update the phone

The pre-push hook runs `scripts/update-local-apps.sh`, which rebuilds the Mac
app, then the Android app, then deploys the relay. Only the **relay** step can
fail the push. `update_android()` **silently skips** when `adb devices` lists no
authorized device, printing e.g.
`Skipping Android update: select exactly one authorized device or set ANDROID_SERIAL.`
That line scrolls past in a long build log, and the push still succeeds.

So a green push does **not** mean the phone is running your change. Verify:

```sh
ls -l android/app/build/outputs/apk/debug/app-debug.apk   # build time
adb shell dumpsys package com.androidbridge | grep lastUpdateTime
```

If the phone is off adb, install it yourself once reconnected:

```sh
cd android && ./gradlew :app:assembleDebug --no-daemon
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.androidbridge/.MainActivity
```

Also: a long-running `adb logcat -d` on a large buffer can hang and leave the
device unlisted. `adb kill-server && adb start-server` recovers it, but the phone
may need re-authorizing on-screen.

## Build and test gotchas

- Gradle's `--tests` filter needs the **fully-qualified** class name for these
  Kotest specs. `--tests '*RelayWebSocketTransportTest*'` fails with
  `No tests found for given includes`; use
  `--tests 'com.androidbridge.RelayWebSocketTransportTest'`.
- Piping gradle through `| grep`/`| tail` masks its exit code, so a `BUILD FAILED`
  looks like success. Use `set -o pipefail` when the exit code matters.
- `relay/justfile` has `just test`; the Android module has no justfile — run
  `./gradlew testDebugUnitTest` from `android/`.
- `LinkManager` has **no** test harness (it is Android-framework coupled), so the
  relay receive loop is not covered by an automated test. The transport and the
  relay server are covered.

## Shell gotchas in this repo

- The Bash tool's working directory **persists between calls**. A `cd` in one
  call changes the next one. Use absolute paths.
- zsh is the shell: `--include=*.kt` fails with `no matches found`. Quote it as
  `--include='*.kt'`.
