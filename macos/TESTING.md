# Validation — 2026-10-27, version 0.1.7

| Check | Result | What it establishes |
| --- | --- | --- |
| Release app build, bundled libraries, local signature | Pass | Native arm64 app compiles and bundle signature verifies |
| Swift protocol/credential/state/debug/device routing checks | 12 passed | Framing, redaction, credential encoding, readiness and routing validation |
| Two simultaneous local digest registrations | Pass | Accounts authenticate independently using delimiter-rich passwords |
| SIP Call-ID and first INVITE capture | Pass | Structured trace IDs match the actual SIP call events |
| Same-app A → B call | Pass | Both accounts register in one app process; distinct local legs survive shared and rewritten SIP Call-IDs; no mutual auto-hold; selected-leg hold/resume and hangup work |
| Same-app file playback | Pass | Live injection and preselected file input reach B, with B listen-only; PCMA, PCMU, G722 and Opus; media payloads are not recorded |
| Receive-only NAT opening | Pass locally | Empty RTP keepalives open a simulated NAT gate without sending audio or starting a microphone |
| Local/remote hold state and selected-call controls | Pass | Repeated local Hold/Resume button states, authoritative engine flags, actual SDP directions, automatic hold and selected-call resume across two simultaneous app calls |
| Audio during hold/resume | Pass | Outgoing file RTP stops during Hold and resumes after Resume for PCMA, PCMU, G722 and Opus |
| Codec order, headers, hold/resume, transfers | Pass | Local SDP and SIP signaling; REFER/Replaces generation |
| Raw engine input without a microphone (earlier reproduction) | Reproduced failure | Input AudioQueueStart returns -66680 / InvalidDevice, mapped to error 19 |
| Audio inventory on development host | 0 inputs, 1 output | No microphone is exposed by macOS; built-in speaker is present |
| Real explicitly selected speaker, incoming/outgoing receive-only local calls | Pass | PCMA, PCMU, G722 and Opus decoders and CoreAudio player opened by stable UID; RTP reception and hold/resume worked; zero microphone packets |
| App behavior without a microphone | Pass | Three real calls through Store establish in recvonly mode; accounts stay connected, file conversion and live playback reach the remote peer, EOF preserves the call, diagnostics and reconnect work |
| Missing/unplugged input or denied permission | Pass | Routing chooses listen-only instead of blocking a call; explicit file mode does not depend on microphone permission |
| File input | Pass | Live injection, incoming file input, file selected before dialing, EOF and stop-to-listen-only passed for all four codecs |
| Multiple-call isolation | Pass | File input remains on the selected call; a second simultaneous call sends zero audio payloads, for all four codecs |
| File conversion | Pass | WAV (44.1 kHz), AIFF and M4A convert to canonical mono 16 kHz PCM WAV; converted samples received over local PCMA RTP |
| Native visual control inspection | Blocked | Desktop automation returns “native pipe closed before response”; app main threads sampled in normal event waits |
| Real microphone send/receive audio | Not verified | Requires an available input device and OS permission |
| Telnyx development number-based A → B calls | Pass | Two isolated accounts in the same native app process; TLS registration/calling, rewritten SIP Call-IDs, selected-leg hold/resume and hangup; PCMA only |
| Telnyx development file media and NAT | Pass | Preselected and live-injected six-second generated files: 300 transmit attempts each, zero send errors; B received 289 and 297 additional packets respectively; incoming payload fingerprints match the source file in memory |
| Provider test cleanup | Pass | Original number route restored and temporary SIP connections deleted; no credentials or media recordings retained |
| Completed remote PBX transfers | Not verified | Local REFER/Replaces generation does not prove remote PBX completion |

## Repeatable commands

Standard checks (no microphone capture; app media fixture requires a speaker):

```sh
macos/scripts/test.sh
```

The suite includes a local proxy and media relay that registers two accounts
inside the same native Store/Engine process. It runs each codec with preserved
and rewritten Call-IDs, both live file injection and file input selected before
dialing (16 scenarios), plus a number-addressed call through a simulated NAT
that blocks incoming audio until the receiving leg sends an empty keepalive
(17 scenarios total). It checks actual receiver RTP establishment, source
packet direction (excluding empty keepalives), local leg identity, absence of
mutual auto-hold, EOF, hold, resume and hangup. Media is synthetic digital silence and is discarded.

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

## Opt-in provider validation

The live run used two temporary Telnyx development credential connections and
a temporarily assigned, account-owned number. Both accounts ran through the
actual Store/Engine process with the built-in speaker and no microphone.
It checked file selected before dialing and file injected during a call, EOF
without disconnect, separate local legs, hold/resume and hangup. Each source
file was a quiet generated tone; incoming PCMA payload hashes were compared
with outgoing payload hashes in memory, without saving audio or packet files.
The validated configuration uses the default non-STUN path and empty NAT
keepalives. Other network topologies and production media were not tested.

The native provider harness is opt-in via `BARESIP_LIVE_SELF_CALL=1` and reads
two credentials from standard input, not command arguments, files or Keychain.
Provider provisioning, number assignment and cleanup are deliberately outside
the unattended regression suite and require explicit authorization.
