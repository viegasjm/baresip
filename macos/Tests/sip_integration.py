#!/usr/bin/env python3
"""Exercise the bundled engine against a local SIP peer; no provider or audio devices."""
import ctypes, hashlib, json, pathlib, re, socket, struct, subprocess, tempfile, threading, time, uuid
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

class SilentCodec:
    """Generate valid encoded zero PCM using the codecs bundled with the app."""
    def __init__(self, name):
        self.name = name
        self.payload, self.mapping, self.account, self.ticks = {
            'PCMA': (8, 'PCMA/8000', 'PCMA/8000/1', 160),
            'PCMU': (0, 'PCMU/8000', 'PCMU/8000/1', 160),
            'G722': (9, 'G722/8000', 'G722/16000/1', 160),
            'opus': (111, 'opus/48000/2', 'opus/48000/2', 960),
        }[name]
        self.lib = self.state = None
        if name == 'opus':
            self.lib = ctypes.CDLL(str(ENGINE.parent / 'lib/libopus.0.dylib'))
            self.lib.opus_encoder_create.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
            self.lib.opus_encoder_create.restype = ctypes.c_void_p
            self.lib.opus_encode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int16), ctypes.c_int, ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int32]
            self.lib.opus_encoder_destroy.argtypes = [ctypes.c_void_p]
            error = ctypes.c_int()
            self.state = self.lib.opus_encoder_create(48000, 2, 2049, ctypes.byref(error))
            assert self.state and error.value == 0
        elif name == 'G722':
            self.lib = ctypes.CDLL(str(ENGINE.parent / 'lib/libspandsp.2.dylib'))
            self.lib.g722_encode_init.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
            self.lib.g722_encode_init.restype = ctypes.c_void_p
            self.lib.g722_encode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ubyte), ctypes.POINTER(ctypes.c_int16), ctypes.c_int]
            self.lib.g722_encode_free.argtypes = [ctypes.c_void_p]
            self.state = self.lib.g722_encode_init(None, 64000, 0)
            assert self.state
    def frame(self):
        if self.name in ['PCMA', 'PCMU']:
            return bytes([0xD5 if self.name == 'PCMA' else 0xFF]) * 160
        output = (ctypes.c_ubyte * 4000)()
        if self.name == 'opus':
            pcm = (ctypes.c_int16 * 1920)()
            length = self.lib.opus_encode(self.state, pcm, 960, output, len(output))
        else:
            pcm = (ctypes.c_int16 * 320)()
            length = self.lib.g722_encode(self.state, output, pcm, len(pcm))
        assert length > 0
        return bytes(output[:length])
    def close(self):
        if self.state:
            if self.name == 'opus': self.lib.opus_encoder_destroy(self.state)
            else: self.lib.g722_encode_free(self.state)
            self.state = None

class Peer:
    def __init__(self, audio=False, codec="PCMA"):
        self.codec = SilentCodec(codec) if audio else None
        self.rtp = None
        self.dtmf_events = set()
        self.rtp_received = 0
        self.rtp_non_silent = 0
        self.rtp_by_port = {}
        self.rtp_sent = 0
        self.media_targets = {}
        if audio:
            self.rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.rtp.bind(("127.0.0.1", 0))
            self.rtp.settimeout(.02)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', 0)); self.sock.settimeout(.2)
        self.port = self.sock.getsockname()[1]
        self.messages = []; self.registrations = {}; self.running = True; self.supports_replaces = True; self.auth_failures = []
        self.thread = threading.Thread(target=self.serve, daemon=True); self.thread.start()
        if self.rtp:
            self.media_thread = threading.Thread(target=self.media, daemon=True)
            self.media_thread.start()
    def media(self):
        while self.running:
            try:
                data, address = self.rtp.recvfrom(65535)
                if len(data) > 12 and data[0] >> 6 == 2:
                    if data[1] & 0x7f == 101: self.dtmf_events.add(data[12]); continue
                    self.rtp_received += 1
                    self.rtp_by_port[address[1]] = self.rtp_by_port.get(address[1], 0) + 1
                    if self.codec.name == "PCMA" and any(value not in [0xD5, 0x55] for value in data[12:]): self.rtp_non_silent += 1
            except socket.timeout: pass
            except OSError: break
            # Microphone payload is discarded; independent silence tests receive-only calls too.
            header = struct.pack('!BBHII', 0x80, self.codec.payload, self.rtp_sent % 65536, (self.rtp_sent * self.codec.ticks) % (2**32), 0x12345678)
            frame = self.codec.frame()
            for target in list(self.media_targets.values()):
                try: self.rtp.sendto(header + frame, target)
                except OSError: return
                self.rtp_sent += 1
    def incoming(self, contact, account):
        uri = re.search(r'<([^>]+)>', contact).group(1)
        target = re.search(r'@([^:;]+):([0-9]+)', uri)
        call_id = str(uuid.uuid4())
        body = f'v=0\r\no=peer 2 2 IN IP4 127.0.0.1\r\ns=Incoming test\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio {self.rtp.getsockname()[1]} RTP/AVP {self.codec.payload}\r\na=rtpmap:{self.codec.payload} {self.codec.mapping}\r\na=sendrecv\r\n'
        request = f'INVITE {uri} SIP/2.0\r\nVia: SIP/2.0/UDP 127.0.0.1:{self.port};branch=z9hG4bK{uuid.uuid4().hex}\r\nFrom: <sip:fixture@127.0.0.1:{self.port}>;tag=incoming-test\r\nTo: <{account}>\r\nCall-ID: {call_id}\r\nCSeq: 1 INVITE\r\nMax-Forwards: 70\r\nContact: <sip:fixture@127.0.0.1:{self.port}>\r\nContent-Type: application/sdp\r\nContent-Length: {len(body.encode())}\r\n\r\n{body}'
        self.sock.sendto(request.encode(), (target.group(1), int(target.group(2))))
        return call_id
    def serve(self):
        while self.running:
            try: packet, addr = self.sock.recvfrom(65535)
            except socket.timeout: continue
            except OSError: break
            text = packet.decode()
            self.messages.append(text)
            lines = text.split('\r\n')
            h = {}
            for line in lines[1:]:
                if not line: break
                name, _, value = line.partition(':'); h[name.lower()] = value.strip()
            if text.startswith('SIP/2.0'):
                if text.startswith('SIP/2.0 200') and h.get('cseq', '').endswith(' INVITE'):
                    uri = re.search(r'<([^>]+)>', h['contact']).group(1)
                    ack = f"ACK {uri} SIP/2.0\r\nVia: SIP/2.0/UDP 127.0.0.1:{self.port};branch=z9hG4bK{uuid.uuid4().hex}\r\nFrom: {h['from']}\r\nTo: {h['to']}\r\nCall-ID: {h['call-id']}\r\nCSeq: 1 ACK\r\nMax-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
                    self.sock.sendto(ack.encode(), addr)
                    if self.rtp:
                        body = text.split('\r\n\r\n', 1)[1]
                        media = re.search(r'm=audio (\d+)', body)
                        if media and 'a=inactive' not in body and 'a=sendonly' not in body:
                            self.media_targets[h['call-id']] = ('127.0.0.1', int(media[1]))
                continue
            method = lines[0].split()[0]
            if method in ['ACK']: continue
            if method == 'BYE': self.media_targets.pop(h['call-id'], None)
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
                if self.rtp:
                    if 'a=inactive' in offer or 'a=sendonly' in offer:
                        self.media_targets.pop(h['call-id'], None)
                    else: self.media_targets[h['call-id']] = ('127.0.0.1', int(m.split()[1]))
                direction = 'sendonly' if 'a=recvonly' in offer else ('recvonly' if 'a=sendonly' in offer else ('inactive' if 'a=inactive' in offer else 'sendrecv'))
                body = f'v=0\r\no=peer 1 1 IN IP4 127.0.0.1\r\ns=Test\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio {self.rtp.getsockname()[1] if self.rtp else 42000} RTP/AVP {payload} 101\r\n{mapping}\r\na=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-15\r\na={direction}\r\n'
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
    def close(self):
        self.running = False
        self.sock.close()
        self.thread.join(timeout=1)
        if self.rtp:
            self.rtp.close()
            self.media_thread.join(timeout=1)
            self.codec.close()

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

def run_signaling():
    global LOG_PATH
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
    ctrl_tcp_trace yes
    ctrl_tcp_listen 127.0.0.1:{port}
    ''')
            aor = f'sip:alice@127.0.0.1:{peer.port}'
            bob = f'sip:bob@127.0.0.1:{peer.port}'
            folder.joinpath('accounts').write_text('\n'.join(f'<{a};transport=udp>;regint=0;audio_codecs=PCMA/8000/1,opus/48000/2,G722/16000/1,PCMU/8000/1' for a in [aor,bob]))
            with folder.joinpath('engine.log').open('w') as log:
                process = subprocess.Popen([str(ENGINE), '-f', temp], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                def connect():
                    nonlocal control
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
                trace = next((event for event in control.events if event.get('type') == 'SIP_TRACE' and event.get('message', '').startswith('INVITE ')), None)
                assert trace is not None, 'Structured first INVITE trace is missing'
                assert 'Call-ID: ' + call in trace['message'], 'Trace Call-ID differs from call events'
                assert trace['direction'] == 'sent' and trace['transport'] == 'UDP'
                assert 'X-Trace: hello world&test' in trace['message']
                assert any(event.get('type') == 'SIP_TRACE' and event.get('direction') == 'received' and event.get('message', '').startswith('SIP/2.0 200') for event in control.events), 'Received SIP response trace missing'
                print('PASS: structured sent/received SIP traces; first INVITE and exact SIP Call-ID')
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

if __name__ == "__main__":
    run_signaling()
