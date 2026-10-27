# Baresip Mac

A native SwiftUI macOS client backed by Baresip 4.12.0. This first version supports:

- Multiple simultaneous SIP registrations and selection of the outgoing account.
- Per-account enable/disable and priority ordering for Opus, G.722, PCMA and PCMU.
- Incoming/outgoing calls, multiple active calls, hold/resume and microphone mute.
- Blind transfer and attended transfer (consult, complete, cancel).
- Default account headers and additional call headers for outgoing INVITEs.
- Password storage in macOS Keychain; account preferences stored separately.

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
Allow microphone access when first making or answering a call.

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
The current audio devices are the macOS system defaults. This first version
does not expose device selection, STUN/TURN settings, recording, or video.

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
password encoding and registration-based call availability.
The bundled-engine check exercises the native process and TCP bridge with two
accounts. The local SIP fixture checks two simultaneous digest-authenticated registrations using passwords
containing spaces, quotes, backslashes and delimiters,
account selection, headers, SDP codec order, hold/resume re-INVITEs, blind
REFER, and attended REFER with Replaces. These tests use loopback only and
never contact a provider or open a microphone.

A live provider test is still required for provider-specific authentication, NAT traversal,
two-way audio, incoming calls, microphone permissions and end-to-end transfers.
Visual UI inspection also remains to be performed on a Mac with accessibility
permission enabled. Tests of REFER generation do not prove that a PBX completes
a transfer successfully.

## Storage and security

Nonsecret account preferences: `~/Library/Application Support/BaresipMac/accounts.json`.
Passwords: Keychain service `com.viegasjm.baresip-mac`.
The engine receives nonsecret account settings in a private temporary directory
with mode 0600. Passwords are read from Keychain and supplied in memory through
the local control channel before registration. The temporary account file is
deleted after startup and the runtime directory is removed on shutdown. Engine output is drained without writing SIP logs.
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
