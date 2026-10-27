# Validation — 2026-10-27, version 0.1.6

| Check | Result | What it establishes |
| --- | --- | --- |
| Release app build, bundled libraries, local signature | Pass | Native arm64 app compiles and bundle signature verifies |
| Swift protocol/credential/state/debug/device routing checks | 11 passed | Framing, redaction, credential encoding, readiness and routing validation |
| Two simultaneous local digest registrations | Pass | Accounts authenticate independently using delimiter-rich passwords |
| SIP Call-ID and first INVITE capture | Pass | Structured trace IDs match the actual SIP call events |
| Local/remote hold state and selected-call controls | Pass | Repeated local Hold/Resume button states, authoritative engine flags, actual SDP directions, automatic hold and selected-call resume across two simultaneous app calls |
| Audio during hold/resume | Pass | Outgoing file RTP stops during Hold and resumes after Resume for PCMA, PCMU, G722 and Opus |
| Codec order, headers, hold/resume, transfers | Pass | Local SDP and SIP signaling; REFER/Replaces generation |
| Raw engine input without a microphone (earlier reproduction) | Reproduced failure | Input AudioQueueStart returns -66680 / InvalidDevice, mapped to error 19 |
| Audio inventory on development host | 0 inputs, 1 output | No microphone is exposed by macOS; built-in speaker is present |
| Real explicitly selected speaker, incoming/outgoing receive-only local calls | Pass | PCMA, PCMU, G722 and Opus decoders and CoreAudio player opened by stable UID; RTP reception and hold/resume worked; zero microphone packets |
| App behavior without a microphone | Pass | Three real calls through Store establish in recvonly mode; accounts stay connected, file conversion and live playback reach the remote peer, EOF preserves the call, diagnostics and reconnect work |
| Missing/unplugged input or denied permission | Pass | Routing chooses listen-only instead of blocking a call; explicit file mode does not depend on microphone permission |
| File input | Pass | Live injection, incoming file input, file selected before dialing, EOF and stop-to-listen-only passed for all four codecs |
| Multiple-call isolation | Pass | File input remains on the selected call; a second simultaneous call sends zero RTP, for all four codecs |
| File conversion | Pass | WAV (44.1 kHz), AIFF and M4A convert to canonical mono 16 kHz PCM WAV; converted samples received over local PCMA RTP |
| Native visual control inspection | Blocked | Desktop automation returns “native pipe closed before response”; app main threads sampled in normal event waits |
| Real microphone send/receive audio | Not verified | Requires an available input device and OS permission |
| Provider calls, NAT, completed PBX transfers | Not verified | Loopback signaling and REFER generation do not prove provider behavior |

## Repeatable commands

Standard checks (no microphone capture; app media fixture requires a speaker):

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

To exercise file input with a local peer that discards the synthetic audio:

```sh
BARESIP_AUDIO_FILE_TEST=1 BARESIP_AUDIO_RECEIVE_ONLY=1 \
  BARESIP_AUDIO_OUTPUT_UID=BuiltInSpeakerDevice python3 macos/Tests/audio_integration.py
```

Set `BARESIP_AUDIO_CODEC` as above to repeat per codec. This also verifies that
file playback stays isolated to the selected call while a second call is active.
The fixture sends only digital silence back to the real speaker.

Opt-in full audio test when a default input is available:

```sh
python3 macos/Tests/audio_integration.py
```

The full test opens the default microphone and speaker, discards microphone RTP
payloads, and returns only silent audio over loopback. It exercises outgoing and
incoming calls. No media is saved. Text diagnostics are saved under the ignored
`build/audio-test.log`. It must not be included in unattended CI runs.
