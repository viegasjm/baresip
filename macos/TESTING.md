# Validation — 2026-11-06, version 0.1.16

Call direction indicators are a view-only update. The release build and
compact UI preview verify phone-arrow indicators beside both incoming and
outgoing call statuses, plus accessible direction/status labels. No SIP or
PBX behavior changed; the protocol and audio results below are from 0.1.15.

Earlier account call-end validation (0.1.15):

Account call ends and transfer diagnostics: the Store test receives a real
REFER acceptance followed by a NOTIFY with `404 Not Found`. The transfer
explicitly targets an older call while another call is selected; the remote
peer verifies the REFER dialog, the failure includes its destination, and both
calls remain present. Self-call checks exercise explicit hold/resume and
hangup IDs while the other side is selected, with account-aware activity.

The UI-only 900 × 640 preview was inspected before/after answer: both call
ends and per-account statuses remain visible, linked labels identify their
relationship, and selecting an account or call changes the owning-account
control header and accessible End call label. The transfer panel displays the
account and full URI; the retained failure links to SIP-filtered Debug.
No live PSTN transfer or PBX route changes were performed for this update.

Earlier local-PBX validation (0.1.14):

The local-PBX regression reproduced `ua: no laddr for 127.0.0.1` and
`call failed (Invalid argument [22])` with the previous engine using normal
interface selection. The fixed engine passed the same Store call/media test.
Paired calls also exposed a UDP SDP mismatch: the wildcard SIP transport
could advertise a LAN address while media used loopback. SDP now follows
the loopback destination route for those calls. A separate TCP fixture checks registration, a numeric call, loopback SDP,
answer and BYE without a `net_interface` override. Native registration and
self-call fixtures now also use normal interface selection rather than
forcing loopback. All 17 self-call scenarios passed across PCMA, PCMU, G722
and Opus, with file playback, independent legs, hold/resume and hangup. The
full local regression suite passed. No provider calls or provider settings
changes were needed.
The self-call relay now reads the endpoint's SDP connection address and
advertises its own loopback relay address; its previous hardcoded endpoint
address failed when normal UDP signaling advertised the LAN interface.
Core network and TCP selftests passed in both receive modes. The optional
core hold test could not run because this bundle excludes the `ausine` test
module; the app-level hold/resume integration checks passed.

The account-copy update passed the release build and an isolated UI check:
Copy account name pasted `Work`, and Copy SIP address pasted
`sip:alex@sip.example.test` into the preview's destination field. No call was
placed and no real accounts were accessed. The change only affects account
text selection and menu actions; the SIP regression results below are from
version 0.1.12.

| Check | Result | What it establishes |
| --- | --- | --- |
| Release app build, bundled libraries, local signature | Pass | Native arm64 app compiles and bundle signature verifies |
| Theme build and custom color contrast | Pass | All theme views compile; custom palette accent/canvas and call-button label/fill pairs exceed 4.5:1 in both light and dark mode (minimum measured 5.44:1) |
| Live layout and appearance inspection | Pass for sample states | Shared SwiftUI views inspected in isolated 1100 × 780 and 900 × 640 content previews; Telnyx light/dark layouts, idle dialer, active/incoming calls and registration errors checked |
| Swift protocol/credential/state/debug/device routing checks | 15 passed | Framing, redaction, credential encoding, readiness and routing validation |
| Per-account connection controls | Pass | Both accounts use explicit authentication usernames; connecting A leaves B offline; B connects, unregisters and retries independently without restarting A's registration |
| REGISTER account filtering and export | Pass | Responses and events stay associated with the selected account; other registrations and INVITEs are excluded; authentication is redacted |
| Local password files | Pass | Round-trip and replacement preserve delimiters; directory mode 0700, file mode 0600; missing/deleted accounts return an empty password; tests use temporary files |
| Local keypad tone generation | Pass | All twelve keys have the expected row/column frequency peaks, bounded amplitude and zero endpoints for short fades |
| Local keypad speaker playback | Pass | AVAudioPlayer starts and advances playback on the selected real output UID without changing microphone permission |
| Local feedback independent of remote digits | Pass | The local peer still receives 1, 2 and # when the local speaker is unavailable, available or keypad feedback is muted; call input remains listen-only |
| DTMF keypad through Store | Pass | Local peer receives 1, 2 and # via SIP INFO on a listen-only call, and RTP telephone-event 5 while sending file audio |
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
| Native visual control inspection | Pass for layout | Numeric pad/backspace, headers sheet, account editor and navigation exercised; contextual tools, incoming actions, automatic REGISTER filtering and filter retention inspected with sample state; no real calls placed by the UI fixture |
| Real microphone send/receive audio | Not verified | Requires an available input device and OS permission |
| Telnyx development number-based A → B calls | Pass | Two isolated accounts in the same native app process; TLS registration/calling, rewritten SIP Call-IDs, selected-leg hold/resume and hangup; PCMA only |
| Telnyx development file media and NAT | Pass | Preselected and live-injected six-second generated files: 300 transmit attempts each, zero send errors; B received 289 and 297 additional packets respectively; incoming payload fingerprints match the source file in memory |
| Provider test cleanup | Pass | Original number route restored and temporary SIP connections deleted; no credentials or media recordings retained |
| Completed remote PBX transfers | Not verified | Local REFER/Replaces generation does not prove remote PBX completion |

Production registration diagnosis on 2026-10-28: the reported account completed
TCP REGISTER → 401 challenge → authenticated REGISTER → 200 OK with its current
provider credential. The diagnostic client then received 200 OK Deregistered.
No failed historical exchange was available, so the original failure's cause
was not established. This does not establish provider DTMF interoperability.
Follow-up on 2026-10-28 established the current two-account failure: an explicit
authentication username triggered the terminal password prompt, aborting account
loading after the first entry. The running app's reginfo snapshot showed one UA,
and a local two-account fixture with both authUser fields populated reproduced
the failure on 0.1.8. Version 0.1.9 disables the prompt only for the native app
and validates all configured UAs before readiness. Earlier fixtures omitted
explicit authUser and therefore missed this case.

## Repeatable commands

The 0.1.12 view changes were compiled in the real client and a UI-only sample
application (`macos/Tests/LayoutPreview.swift`). The preview omits the engine,
uses temporary account storage, and does not use provider credentials. Its
scenario menu supplies idle, active-call, incoming-call and failed-registration
states. App settings were opened and canceled without saving. A compact preview
also confirmed the call-control row fits and Debug's registration filter and
reading pane remain visible. A final navigation check confirmed the selected
Engine category survives a Calls → Debug round trip.

The first full local regression run failed when the proxy tried to decode
binary UDP packets as SIP text. The same G722/rewritten-ID/preselected-file case
passed on an isolated rerun with no proxy errors. The full suite rerun passed, including all 17 same-app scenarios and the SIP protocol checks;
`build/layout-first-regression.log` and `build/layout-focused-regression.log`
retain the initial failure and focused result. No engine or packet-routing code
was changed for this view revision.

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
