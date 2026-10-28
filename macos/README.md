# Baresip Mac

A native SwiftUI macOS client backed by Baresip 4.12.0. This first version supports:

- Multiple simultaneous SIP registrations and selection of the outgoing account.
- Per-account enable/disable and priority ordering for Opus, G.722, PCMA and PCMU.
- Incoming/outgoing calls, multiple active calls, hold/resume and microphone mute.
- Blind transfer and attended transfer (consult, complete, cancel).
- Default account headers and additional call headers for outgoing INVITEs.
- Private local password files (no Keychain prompts); account preferences stored separately.

## Version 0.1.11 themes

Open **Appearance** to choose Telnyx, System, Ocean or Sunset. Telnyx is the
initial palette, with mint green, charcoal and ivory surfaces. System follows
the Mac's accent and neutral colors. Light, Dark and System appearance choices
work with every palette. Theme and appearance preferences apply immediately and
are saved on this Mac.

Colors apply to the account sidebar, call controls, account editor, Audio and
Debug, including group surfaces and signaling highlights. Status indicators
retain semantic success, warning and error colors. Custom palettes use separate
accent-text and primary-button colors to retain contrast in light and dark mode.
Changing a theme does not restart the SIP engine or change account settings.

## Version 0.1.10 local keypad feedback

The in-call keypad now plays each key's standard two-frequency tone locally
through the selected speaker. Keypad sounds are enabled by default, can be
muted from the keypad or Audio tab, and have a **Test keypad sound** button in
Audio settings. This is local feedback; it does not confirm that the remote IVR
accepted a digit. Earlier versions sent DTMF without generating a local tone.

Tones are generated in memory and need no microphone permission. They do not
replace the call's audio source or inject extra inband DTMF. A missing local
speaker shows a sound warning while digits continue through the existing SIP
DTMF path. System output volume and mute still apply.

## Version 0.1.9 multiple-account loading fix

Accounts with an explicit authentication username could stop account-file
loading at the first entry. Baresip's account module prompted for a password on
standard input, which is unavailable in the native app. The first account stayed
loaded, so connecting another saved account failed locally with “could not find
User-Agent” instead of sending REGISTER.

The app sets `account_password_prompt no` and supplies passwords through its
existing control connection. The account module keeps its usual terminal prompt
by default for other clients. Startup now verifies that every configured account
was loaded before marking the engine ready. Regression tests reproduce the old
failure and verify independent digest registrations with explicit authentication
usernames on both accounts.

Snapshot captures current engine, registration, call and audio diagnostics; it
does not capture the screen. The button now includes an explanatory tooltip.

## Version 0.1.8 registration controls and DTMF

Each sidebar account has its own Connect, Retry or Disconnect button, available
in Calls, Audio and Debug. Connecting one account leaves the others offline;
retrying or disconnecting an account keeps the engine and other calls running.
An account with an active call cannot be disconnected from the sidebar.

In Debug, enable **REGISTER · selected account** to inspect that account's
requests, authentication retries, responses and registration events, including
the SIP Call-ID. Authentication headers stay redacted. A 401 challenge followed
by an authenticated REGISTER and 200 OK is a successful registration exchange.

During a connected call, open **Keypad** to send 0–9, * and # to the selected
call. Automatic DTMF uses negotiated RTP telephone events while transmitting
media, or SIP INFO when telephone events are unavailable or the call is
listen-only. The receiving provider must support the selected transport.
The keypad is disabled while the call is on hold.

Passwords are saved in local files with user-only permissions, without Keychain
encryption or prompts. Older Keychain entries are left untouched and are no
longer read. Existing installations need to save their passwords in the new
store once; the app never silently reads or migrates Keychain entries.

## Version 0.1.7 calls between accounts in one app

Call legs now have separate local control identities, so two accounts can keep
both ends of a call even when a proxy preserves the same SIP Call-ID. The real
SIP Call-ID remains available in Debug and traces. Hold, resume, answer, file
input and hangup target the selected local leg.

When an outgoing call targets another registered account in this app, its
incoming leg is paired before answering. Paired legs are exempt from each
other's automatic hold policy, including when a provider rewrites Call-ID.
Ordinary unrelated calls retain automatic hold behavior. The local receiving
leg defaults to listen-only to avoid shared microphone feedback or sending a
preselected audio file back to its own caller.

To test, select A and call B's full SIP address, then select B's incoming call
and Answer. Select A's call and Play audio file; B receives it through the
selected speaker. A file chosen before dialing also plays from A to B only.
The Calls sidebar shows the account for each leg. Both legs remain available
until hangup.

For number-based calls, add the full destination number (for example,
`+12025550123`) to B's **Assigned numbers** field in Edit account. This lets
the app recognize the two local legs when a provider changes SIP Call-ID,
and route incoming INVITEs addressed to that number to B. Numbers delivered
with or without the leading `+` match; duplicate account mappings are rejected.
This field describes numbers already routed by your provider; it does not
change provider routing. Existing saved accounts continue to work.

For Telnyx account-only SIP URI calling, an account header named
`X-Telnyx-Username` with the SIP username can identify the calling connection
before the digest challenge. Configure this in the account's Headers tab.
The provider's SIP password is still required for authentication.

This also fixes conversion filters for transmit-only and receive-only streams,
which is necessary when two listen-only accounts connect before file input is
started. A transmitter can now resample file audio without requiring a decoder
on the same leg.

Receive-only audio opens the engine's NAT pinhole with empty RTP keepalive
packets, as its video receiver already does. These contain no audio and do
not open the microphone. A short startup burst helps gateways learn the
receiver's address before file playback. Tests exclude empty keepalives from
audio counts.

Debug snapshots also show RTP transmit attempts, receive counts, send/receive
errors and the last send error.

## Version 0.1.6 hold/resume state

The Hold button now changes to Resume after a local hold, and back to Hold
when resumed. Local hold state comes from the engine's `local_hold` field on
call events and successful local commands, including calls automatically held
when another call starts or resumes. Hold/resume commands target the selected
Call-ID explicitly. Remote hold events are tracked separately and displayed as
Held by remote party; they do not toggle your local Hold/Resume action.

The app-state regression checks repeated button-state changes, real SDP
transitions, and holding/resuming between two simultaneous calls. The audio
fixture checks that Hold stops outgoing file RTP and Resume restores it.

## Version 0.1.5 calls without a microphone and file input

A missing microphone, unavailable selected input, or denied microphone permission
now falls back to listen-only calling. SIP calls still connect and receive audio;
they negotiate `recvonly` rather than trying to open an unusable microphone.
Answering incoming calls uses the same behavior. A working selected speaker is
still required by the app.

The Audio tab offers Microphone when available, Listen only, and Audio file.
Choose a file there to send it when the next call connects. During an active
call, use **Play audio file…** to send a file to that call, or **Listen only** to
stop sending. Other calls are unaffected. Files play once; end-of-file leaves
the call connected. A file follows its playback timeline, including while held. Reopening its
source restarts it from the beginning; use Play audio file again to replay it.

Audio macOS can decode is converted locally to a canonical 16 kHz, mono,
16-bit PCM WAV for Baresip. WAV, AIFF and M4A conversion were tested. Files must
be no longer than 10 minutes; decoding errors are shown without ending the
call. Private converted copies are retained for the app session so other calls
can still use their chosen files. Clear (while idle) or quitting removes them.
The original files are unchanged.

The bundled `aufile` module supplies the audio. New local commands configure
future-call sources without touching active calls (`ausrcdefault`) or change
only the selected call and renegotiate media (`callsource`). Source changes
stop/rebuild the call's transmit pipeline so file sample rates are resampled
correctly. Consult calls retain the original media direction.

## Version 0.1.4 missing microphone recovery (superseded by 0.1.5)

A missing microphone is a recoverable call error: accounts stay connected,
call controls become available again, and diagnostics and reconnect still work.
If an audio device fails after call setup starts, the app displays a clear
message pointing to Audio and Debug while preserving the account connection.
The app-state regression repeats the missing-microphone call attempt three times
and verifies diagnostics and reconnect. The test launcher also reports startup
errors normally instead of turning an unhandled error into a crash report, and
verifies the bundled signature before starting the engine.

## Version 0.1.3 audio device selection

The Audio tab provides independent microphone and speaker menus, system-default
choices, device information and Refresh. Choices are saved as stable CoreAudio
UIDs, so duplicate device names and renamed devices remain distinguishable.
Changing a device reconnects idle accounts; controls are locked during calls.
A missing or unplugged microphone is detected before asking for microphone
permission; automatic mode then connects the call in listen-only mode.

Further testing reproduced error `[19]` as `AudioQueueStart -66680`
(`kAudioQueueErr_InvalidDevice`) when the development host had no microphone.
Incoming and outgoing receive-only calls using its explicitly selected built-in
speaker passed for PCMA, PCMU, G722 and Opus, with actual CoreAudio playback,
RTP reception, hold and resume. See [TESTING.md](TESTING.md)
for the tested scope and remaining gaps.

## Version 0.1.2 diagnostics

The detail pane has Calls, Audio and Debug tabs. Debug retains up to 50 calls and
500 diagnostic entries, including completed calls. Select a call to copy its
actual SIP Call-ID or inspect its first INVITE; use the SIP filter to inspect
requests and responses, transport, endpoints and SDP. The Engine filter retains
CoreAudio errors including the failing AudioQueue operation and OSStatus.

Capture is enabled by default. The Capture switch pauses recording; Clear
removes the captured history. Snapshot records microphone permission, macOS
default input/output devices, sample rates/channels, registration state, call
state and, during an active call, negotiated audio and RTP details. Copy and
Export operate on redacted diagnostics. Authentication headers, ICE passwords
and SDES media keys are hidden; SIP addresses and custom headers remain visible.
Nothing is written to disk until Export. Closing the app clears this history.
The opt-in engine setting `ctrl_tcp_trace yes` emits structured SIP_TRACE events,
including decrypted SIP over TLS, only to the local control client.

Error `[19]` is a local device error. The CoreAudio driver returns it when
opening/starting input or output fails. The old app did not retain the detailed
OSStatus, so past calls cannot be diagnosed retroactively. Reproduce the issue,
open Debug, take a Snapshot and export the resulting diagnostics.

Mono device audio is enabled by default and changes apply after reconnecting.
Device I/O channel count is independent of the codec's advertised channels;
Baresip's audio conversion handles that difference. The driver also initializes
the complete CoreAudio stream description before opening a device.

## Version 0.1.1 fixes

Account editing opens a fresh sheet for the selected account, with Keychain
loading off the main UI thread. The header and sidebar show the selected
account's registration state. Failed registration shows the server's reason
with Edit and Retry actions, and calls stay disabled until registration succeeds.
Passwords are now supplied to the engine through the local control channel
before registering, rather than through the configuration parser.

## Run

Open `macos/dist/Baresip Mac.app` after building. Add an account, enter the
username and domain separately, choose transport and codecs, and click Connect.
TLS verifies the server certificate using the CA bundle included in the app.
Allow microphone access to speak through a microphone; otherwise calls continue
in listen-only mode. File input never requests microphone permission.

Headers are appended to outgoing INVITEs. They are not a raw SIP message editor
and do not replace Baresip's management of From, Contact, Via or authentication.
Call headers remain in the panel for subsequent calls until removed. To send
multiple values with the same header name, add multiple rows.

For transfer, select an active call in the sidebar and enter a destination.
Choose Blind transfer, or Consult first and then Complete transfer. Cancel
transfer returns to the original party. Your SIP server must support REFER
and, for attended transfer, Replaces.

Account details can be opened at any time. Saving edits restarts registration
and is disabled during active calls or another operation.
Audio devices can be selected in the Audio tab. This version does not expose
STUN/TURN settings, recording, or video.

## Build

Requirements: Apple compiler tools with Swift 5.9+, Python 3, Git, Homebrew.
The source UI targets macOS 14+. The bundled development build has been built
for Apple Silicon on the current development Mac; Homebrew library minimum
versions can raise the actual minimum OS. Intel and older macOS builds need
separate validation.

```sh
brew install cmake pkgconf openssl@3 opus spandsp
macos/scripts/build.sh
```

The script pins libre to v4.12.0 / commit
`65555dad439de9d6a81b3ee6092b9c096585249b`, builds it under `build/deps`, and
builds the Baresip engine with its required modules statically included.
It bundles non-system dynamic libraries and their available license notices,
then applies a local ad-hoc signature. No Developer ID or notarization is
configured; public distribution needs a release signing/notarization workflow.

To use another CMake installation, set `CMAKE=/absolute/path/to/cmake`.
The app bundle is self-contained and does not require Homebrew at runtime.

## CI template

`macos/ci/native-macos.yml.example` contains a GitHub Actions build and test
workflow. It is kept as a template because the current GitHub credential
cannot publish workflow files. A repository owner can install it under
`.github/workflows/` with a credential that has workflow permission.

## Validation

```sh
macos/scripts/test.sh
```

The Swift checks cover fragmented/coalesced control messages, Unicode byte
lengths, invalid framing, header injection, account validation, codec order,
password encoding, registration-based call availability, debug redaction,
first-INVITE retention, device-error explanations, bounded log retention and
stable audio routing with missing/unplugged devices.
The bundled-engine check exercises the native process and TCP bridge with two
accounts. The local SIP fixture checks two simultaneous digest-authenticated registrations using passwords
containing spaces, quotes, backslashes and delimiters,
account selection, headers, SDP codec order, hold/resume re-INVITEs, blind
REFER, attended REFER with Replaces, and structured bidirectional SIP trace
events whose Call-ID matches the call events. These tests use loopback only and
never contact a provider or open a microphone. The app-state fixture opens
the selected speaker, returns digital silence, and discards synthetic file RTP
at its local peer; it verifies real listen-only calls and live file injection.

A live provider test is still required for provider-specific authentication, NAT traversal,
two-way audio, incoming calls, microphone permissions and end-to-end transfers.
Visual UI inspection remains blocked by a desktop automation connection failure. Tests of REFER generation do not prove that a PBX completes
a transfer successfully.

## Storage and security

Nonsecret account preferences: `~/Library/Application Support/BaresipMac/accounts.json`.
Passwords: `~/Library/Application Support/BaresipMac/credentials/<account UUID>`,
unencrypted with mode 0600 inside a mode-0700 directory. There are no Keychain
reads or prompts. Other processes running as the same user can read these files.
The engine receives nonsecret account settings in a private temporary directory
with mode 0600. Passwords are read from the private local store and supplied in memory through
the local control channel before registration. The temporary account file is
deleted after startup and the runtime directory is removed on shutdown. Engine
output and SIP traces are redacted and retained in bounded memory, with no log
file unless the user explicitly exports diagnostics.
The JSON control channel binds to a random loopback port and has no remote
listener. Like upstream ctrl_tcp, it does not authenticate local clients.
Password values are URI-encoded for control command parsing and decoded before
SIP authentication; they are never written to the account file.

## License

Baresip and libre retain their BSD license notices. Bundled codec and TLS
libraries retain their own licenses under `Contents/Resources/Licenses`.
The new macOS client source is distributed under the repository's BSD license.

The fork also makes attended-transfer commands return errors for missing targets
or peers without Replaces support, so the UI can report failure accurately.
