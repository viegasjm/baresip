# Validation — 2026-10-27, version 0.1.4

| Check | Result | What it establishes |
| --- | --- | --- |
| Release app build, bundled libraries, local signature | Pass | Native arm64 app compiles and bundle signature verifies |
| Swift protocol/credential/state/debug/device routing checks | 10 passed | Framing, redaction, credential encoding, readiness and routing validation |
| Two simultaneous local digest registrations | Pass | Accounts authenticate independently using delimiter-rich passwords |
| SIP Call-ID and first INVITE capture | Pass | Structured trace IDs match the actual SIP call events |
| Codec order, headers, hold/resume, transfers | Pass | Local SDP and SIP signaling; REFER/Replaces generation |
| Real default microphone call | Reproduced failure | Input AudioQueueStart returns -66680 / InvalidDevice, mapped to error 19 |
| Audio inventory on development host | 0 inputs, 1 output | No microphone is exposed by macOS; built-in speaker is present |
| Real explicitly selected speaker, incoming/outgoing receive-only local calls | Pass | PCMA, PCMU, G722 and Opus decoders and CoreAudio player opened by stable UID; RTP reception and hold/resume worked; zero microphone packets |
| App behavior without a microphone | Pass | Three call attempts through Store leave accounts connected, clear busy state, show a microphone error, preserve diagnostics and allow reconnect |
| Missing/unplugged input preflight | Pass | Returns a microphone-specific error before requesting permission or starting a call |
| Native visual control inspection | Blocked | Desktop automation returns “native pipe closed before response”; app main threads sampled in normal event waits |
| Real microphone send/receive audio | Not verified | Requires an available input device and OS permission |
| Provider calls, NAT, completed PBX transfers | Not verified | Loopback signaling and REFER generation do not prove provider behavior |

## Repeatable commands

Standard checks (no microphone recording):

```sh
macos/scripts/test.sh
```

Opt-in speaker-only test, using digital silence and a local SIP peer:

```sh
BARESIP_AUDIO_RECEIVE_ONLY=1 BARESIP_AUDIO_OUTPUT_UID=BuiltInSpeakerDevice \
  python3 macos/Tests/audio_integration.py
```

Set `BARESIP_AUDIO_CODEC` to `PCMA` (default), `PCMU`, `G722` or `opus` to
repeat with another codec. Silence is encoded with the bundled Opus/Spandsp
libraries; each run checks both outgoing and incoming calls plus hold/resume.

Use the desired speaker UID shown in a Debug snapshot on other Macs. This test
never opens a microphone and never contacts a provider.

Opt-in full audio test when a default input is available:

```sh
python3 macos/Tests/audio_integration.py
```

The full test opens the default microphone and speaker, discards microphone RTP
payloads, and returns only silent audio over loopback. It exercises outgoing and
incoming calls. No media is saved. Text diagnostics are saved under the ignored
`build/audio-test.log`. It must not be included in unattended CI runs.
