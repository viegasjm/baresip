#!/usr/bin/env python3
"""Exercise the bundled engine against a local SIP peer; no provider or audio devices."""
import hashlib, json, pathlib, re, socket, subprocess, tempfile, threading, time, uuid
from urllib.parse import quote
PASSWORD = 'test;password with spaces"\\&%=?+'
REALM = "BaresipMacTest"
NONCE = "local-test-nonce"
ROOT = pathlib.Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'macos/dist/Baresip Mac.app/Contents/Resources/Engine/baresip'

def wait_for(check, message, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value: return value
        time.sleep(.04)
    raise AssertionError(message)

class Peer:
    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', 0)); self.sock.settimeout(.2)
        self.port = self.sock.getsockname()[1]
        self.messages = []; self.registrations = {}; self.running = True; self.supports_replaces = True; self.auth_failures = []
        self.thread = threading.Thread(target=self.serve, daemon=True); self.thread.start()
    def serve(self):
        while self.running:
            try: packet, addr = self.sock.recvfrom(65535)
            except socket.timeout: continue
            except OSError: break
            text = packet.decode()
            self.messages.append(text)
            lines = text.split('\r\n')
            if text.startswith('SIP/2.0'): continue
            h = {}
            for line in lines[1:]:
                if not line: break
                name, _, value = line.partition(':'); h[name.lower()] = value.strip()
            method = lines[0].split()[0]
            if method in ['ACK']: continue
            challenge = method == 'REGISTER' and 'authorization' not in h
            if method == 'REGISTER' and not challenge:
                fields = {key: quoted or bare for key, quoted, bare in re.findall(r'(\w+)=(?:"([^"]*)"|([^, ]+))', h['authorization'])}
                md5 = lambda value: hashlib.md5(value.encode()).hexdigest()
                ha1 = md5(fields['username'] + ':' + REALM + ':' + PASSWORD)
                ha2 = md5('REGISTER:' + fields['uri'])
                if fields.get('qop'):
                    expected = md5(':'.join([ha1, NONCE, fields['nc'], fields['cnonce'], fields['qop'], ha2]))
                else:
                    expected = md5(':'.join([ha1, NONCE, ha2]))
                if fields['response'] != expected:
                    self.auth_failures.append(fields['username'])
                    challenge = True
                else:
                    self.registrations[h['to']] = h.get('contact', '')
            code = '401 Unauthorized' if challenge else ('202 Accepted' if method == 'REFER' else '200 OK')
            body = ''
            if method == 'INVITE':
                offer = text.split('\r\n\r\n', 1)[1]
                m = next(x for x in offer.split('\r\n') if x.startswith('m=audio '))
                payload = m.split()[3]
                mapping = next((x for x in offer.split('\r\n') if x.startswith('a=rtpmap:' + payload + ' ')), '')
                direction = 'recvonly' if 'a=sendonly' in offer else ('inactive' if 'a=inactive' in offer else 'sendrecv')
                body = f'v=0\r\no=peer 1 1 IN IP4 127.0.0.1\r\ns=Test\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 42000 RTP/AVP {payload}\r\n{mapping}\r\na={direction}\r\n'
            to = h.get('to', '')
            if ';tag=' not in to: to += ';tag=fixture'
            response = f"SIP/2.0 {code}\r\nVia: {h['via']}\r\nFrom: {h['from']}\r\nTo: {to}\r\nCall-ID: {h['call-id']}\r\nCSeq: {h['cseq']}\r\nContact: <sip:peer@127.0.0.1:{self.port}>\r\n"
            if challenge: response += f'WWW-Authenticate: Digest realm="{REALM}", nonce="{NONCE}", algorithm=MD5, qop="auth"\r\n'
            if self.supports_replaces: response += 'Supported: replaces\r\n'
            response += 'Allow: INVITE, ACK, BYE, CANCEL, REFER, NOTIFY\r\n'
            if method == 'REGISTER': response += f"Contact: {h.get('contact','')}\r\nExpires: 300\r\n"
            if body: response += 'Content-Type: application/sdp\r\n'
            response += f'Content-Length: {len(body.encode())}\r\n\r\n{body}'
            self.sock.sendto(response.encode(), addr)
    def requests(self, method): return [x for x in self.messages if x.startswith(method + ' ')]
    def close(self): self.running = False; self.sock.close(); self.thread.join(timeout=1)

class Control:
    def __init__(self, port):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=3)
        self.buffer = b''; self.events = []
    def read(self):
        while True:
            if b':' in self.buffer:
                prefix, rest = self.buffer.split(b':', 1); length = int(prefix)
                if len(rest) > length:
                    assert rest[length:length+1] == b','
                    self.buffer = rest[length+1:]
                    return json.loads(rest[:length])
            data = self.sock.recv(65535)
            if not data: raise RuntimeError('Engine disconnected')
            self.buffer += data
    def command(self, command, params='', require_ok=True):
        token = str(uuid.uuid4())
        data = json.dumps(dict(command=command, params=params, token=token)).encode()
        self.sock.sendall(str(len(data)).encode() + b':' + data + b',')
        while True:
            item = self.read()
            if item.get('token') == token:
                if not require_ok: return item
                if not item['ok']: print(LOG_PATH.read_text())
                assert item['ok'], f'{command}: {item.get("data")}'
                return item.get('data','')
            self.events.append(item)
    def event(self, event_type, callid=None):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            for event in self.events:
                if event.get('type') == event_type and (callid is None or event.get('id') == callid):
                    self.events.remove(event); return event
            self.events.append(self.read())
        raise AssertionError('Missing event: ' + event_type)

peer = Peer(); process = None; control = None
try:
    with tempfile.TemporaryDirectory(prefix='baresip-integration-') as temp:
        folder = pathlib.Path(temp)
        LOG_PATH = folder / 'engine.log'
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1', 0)); port = reserved.getsockname()[1]
        folder.joinpath('config').write_text(f'''net_interface 127.0.0.1
sip_listen 127.0.0.1:0
sip_transports udp
call_max_calls 8
call_hold_other_calls yes
module g711
module g722
module opus
module menu
module ctrl_tcp
module_app account
ctrl_tcp_listen 127.0.0.1:{port}
''')
        aor = f'sip:alice@127.0.0.1:{peer.port}'
        bob = f'sip:bob@127.0.0.1:{peer.port}'
        folder.joinpath('accounts').write_text('\n'.join(f'<{a};transport=udp>;regint=0;audio_codecs=PCMA/8000/1,opus/48000/2,G722/16000/1,PCMU/8000/1' for a in [aor,bob]))
        with folder.joinpath('engine.log').open('w') as log:
            process = subprocess.Popen([str(ENGINE), '-f', temp], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            def connect():
                global control
                if process.poll() is not None: raise RuntimeError(folder.joinpath('engine.log').read_text())
                try: control = Control(port); return control
                except OSError: return None
            wait_for(connect, 'Engine did not start')
            for address in [aor, bob]:
                control.command('uafind', address)
                control.command('uapassword', 'value=' + quote(PASSWORD, safe='') + ' 0')
                control.command('uareg', '300 0')
            try:
                wait_for(lambda: len(peer.registrations) == 2, 'Both accounts must register')
            except AssertionError:
                print('Registrations:', list(peer.registrations))
                print(folder.joinpath('engine.log').read_text())
                raise
            assert not peer.auth_failures, 'Password did not survive the credential bridge'
            info = control.command('reginfo')
            assert aor in info and bob in info and info.count('OK') == 2, info
            control.command('uafind', aor)
            control.command('uarmheader', 'X-Trace 0')
            control.command('uaaddheader', 'X-Trace=hello%20world%26test 0')
            control.command('dial', f'sip:target@127.0.0.1:{peer.port}')
            call = control.event('CALL_ESTABLISHED')['id']
            invite = peer.requests('INVITE')[0]
            assert 'X-Trace: hello world&test' in invite, invite
            media = re.search(r'm=audio [^\r\n]+', invite)[0].split()[3:]
            assert media[0] == '8' and media[-3:-1] == ['9','0'], media
            assert 'opus/48000/2' in invite, invite
            control.command('callfind', call)
            control.command('hold')
            wait_for(lambda: any('a=sendonly' in x or 'a=inactive' in x for x in peer.requests('INVITE')[1:]), 'Hold must send a re-INVITE')
            time.sleep(.15)
            control.command('resume')
            wait_for(lambda: len(peer.requests('INVITE')) >= 3 and 'a=sendrecv' in peer.requests('INVITE')[-1], 'Resume must restore sendrecv')
            time.sleep(.15)
            control.command('transfer', f'sip:other@127.0.0.1:{peer.port}')
            wait_for(lambda: peer.requests('REFER'), 'Blind transfer must send REFER')
            assert f'Refer-To: sip:other@127.0.0.1:{peer.port}' in peer.requests('REFER')[-1] or f'Refer-To: <sip:other@127.0.0.1:{peer.port}>' in peer.requests('REFER')[-1]
            control.command('hangup', call)
            control.event('CALL_CLOSED', call)
            # Check header removal and that raising another UA routes the next call correctly.
            control.command('uafind', bob)
            control.command('uarmheader', 'X-Trace 0')
            control.command('dial', f'sip:target2@127.0.0.1:{peer.port}')
            second = control.event('CALL_ESTABLISHED')['id']
            invite = wait_for(lambda: next((x for x in reversed(peer.requests('INVITE')) if x.startswith('INVITE sip:target2')), None), 'Second-account INVITE missing')
            assert 'X-Trace:' not in invite
            assert f'From: <{bob}>' in invite, invite
            control.command('callfind', second)
            control.command('atransferstart', f'sip:consult@127.0.0.1:{peer.port}')
            consult = control.event('CALL_ESTABLISHED')['id']
            assert consult != second
            control.command('callfind', consult)
            count = len(peer.requests('REFER'))
            control.command('atransferexec')
            wait_for(lambda: len(peer.requests('REFER')) > count, 'Attended transfer REFER missing')
            assert 'Replaces' in peer.requests('REFER')[-1], peer.requests('REFER')[-1]
            control.command('hangupall')
            time.sleep(.2)
            peer.supports_replaces = False
            control.command('dial', f'sip:without-replaces@127.0.0.1:{peer.port}')
            unsupported = control.event('CALL_ESTABLISHED')['id']
            control.command('callfind', unsupported)
            result = control.command('atransferstart', f'sip:unsupported-consult@127.0.0.1:{peer.port}', require_ok=False)
            assert not result['ok'], 'Unsupported attended transfer must report failure'
            assert not any(x.startswith('INVITE sip:unsupported-consult') for x in peer.requests('INVITE'))
            print('PASS: unsupported attended transfer returns an error')
            print('PASS: two simultaneous digest-authenticated registrations with delimiter-rich passwords; account selection; custom header insertion/removal; PCMA → Opus → G722 → PCMU offer order; hold/resume re-INVITEs; blind REFER; attended REFER with Replaces')
finally:
    if control: control.sock.close()
    if process:
        process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    peer.close()
