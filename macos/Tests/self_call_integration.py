#!/usr/bin/env python3
"""Two real accounts in one app through a proxy, optionally rewriting Call-ID.
Only synthetic test media is relayed; packet counters are kept, payloads are not.
"""
import json, os, re, socket, subprocess, sys, threading, uuid

class SelfCallProxy:
    def __init__(self, rewrite=False, numbered=False):
        self.rewrite = rewrite
        self.numbered = numbered
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', 0)); self.sock.settimeout(.1)
        self.port = self.sock.getsockname()[1]
        self.media = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.media.bind(('127.0.0.1', 0)); self.media.settimeout(.1)
        self.contacts = {}; self.transactions = {}; self.ids = {}; self.tag_a = None
        self.targets = {}; self.packets = {'a': 0, 'b': 0}; self.silent_packets = 0
        self.keepalives = {'a': 0, 'b': 0}
        self.running = True; self.errors = []; self.messages = []
        self.thread = threading.Thread(target=self.serve, daemon=True); self.thread.start()
        self.media_thread = threading.Thread(target=self.relay_media, daemon=True); self.media_thread.start()
    @staticmethod
    def header(text, name):
        m = re.search(r'^' + re.escape(name) + r':\s*([^\r\n]+)', text, re.M | re.I)
        return m[1] if m else ''
    def rewrite_media(self, text, side):
        if '\r\n\r\n' not in text: return text
        headers, body = text.split('\r\n\r\n', 1)
        port = re.search(r'^m=audio (\d+)', body, re.M)
        if port and int(port[1]):
            self.targets[side] = ('127.0.0.1', int(port[1]))
            body = re.sub(r'(^m=audio )\d+', lambda m: m[1] + str(self.media.getsockname()[1]), body, flags=re.M)
        headers = re.sub(r'^Content-Length:.*$', 'Content-Length: ' + str(len(body.encode())), headers, flags=re.M | re.I)
        return headers.rstrip('\r\n') + '\r\n\r\n' + body
    def serve(self):
        while self.running:
            try: data, address = self.sock.recvfrom(65535)
            except socket.timeout: continue
            except OSError: return
            try: self.handle(data.decode(), address)
            except Exception as error: self.errors.append(type(error).__name__ + ': ' + str(error))
    def handle(self, text, address):
        self.messages.append(text)
        if text.startswith('REGISTER '):
            contact = self.header(text, 'Contact')
            aor = re.search(r'<([^>]+)>', self.header(text, 'To'))[1]
            self.contacts[aor.split(";")[0]] = re.search(r'<([^>]+)>', contact)[1]
            response = 'SIP/2.0 200 OK\r\n' + ''.join(name + ': ' + self.header(text, name) + '\r\n' for name in ['Via','From','To','Call-ID','CSeq'])
            response += 'Contact: ' + contact + '\r\nExpires: 300\r\nContent-Length: 0\r\n\r\n'
            self.sock.sendto(response.encode(), address); return
        call_id = self.header(text, 'Call-ID')
        if text.startswith('SIP/2.0'):
            branch = re.search(r'branch=([^; ]+)', self.header(text, 'Via'))[1]
            target, source_side = self.transactions[branch]
            side = 'b' if source_side == 'a' else 'a'
            text = re.sub(r'^Via:[^\n]+\n', '', text, count=1, flags=re.M | re.I)
        else:
            first, rest = text.split('\r\n', 1)
            method, uri, protocol = first.split(' ')
            tag = re.search(r';tag=([^; ]+)', self.header(text, 'From'))[1]
            if self.tag_a is None:
                self.tag_a = tag
                self.ids[call_id] = str(uuid.uuid4()) if self.rewrite else call_id
                if self.rewrite: self.ids[self.ids[call_id]] = call_id
            side = 'a' if tag == self.tag_a else 'b'
            key = uri.split(";")[0]
            number_call = self.numbered and key.startswith('sip:+12025550123@')
            if number_call: key = key.replace('sip:+12025550123@', 'sip:bob@', 1)
            if key in self.contacts: uri = self.contacts[key]
            if number_call: uri = uri.replace('sip:bob@', 'sip:12025550123@', 1)
            parsed = re.search(r'@([^:;>]+):(\d+)', uri)
            assert parsed, 'Unknown route: ' + uri
            target = (parsed[1], int(parsed[2]))
            branch = 'z9hG4bK-self-' + uuid.uuid4().hex
            self.transactions[branch] = (address, side)
            rest = re.sub(r'^Route:[^\n]+\n', '', rest, flags=re.M | re.I)
            extra = ''
            if method == 'INVITE' and ';tag=' not in self.header(text, 'To'):
                extra = f'Record-Route: <sip:127.0.0.1:{self.port};lr>\r\n'
            text = f'{method} {uri} {protocol}\r\nVia: SIP/2.0/UDP 127.0.0.1:{self.port};branch={branch}\r\n' + extra + rest
        if self.rewrite:
            text = re.sub(r'^Call-ID:[^\r\n]+', 'Call-ID: ' + self.ids[call_id], text, count=1, flags=re.M | re.I)
        text = self.rewrite_media(text, side)
        self.sock.sendto(text.encode(), target)
    def relay_media(self):
        while self.running:
            try: data, address = self.media.recvfrom(65535)
            except socket.timeout: continue
            except OSError: return
            source = next((side for side, target in self.targets.items() if target == address), None)
            if source is None: continue
            other = 'b' if source == 'a' else 'a'
            if len(data) == 12 and data[0] >> 6 == 2:
                self.keepalives[source] += 1
                continue  # A media server consumes keepalives, not audio.
            # Model a NAT that admits incoming media only after B sends out.
            if self.numbered and source == 'a' and not self.keepalives['b']:
                continue
            if len(data) > 12 and data[0] >> 6 == 2:
                self.packets[source] += 1
                if source == 'a' and all(value in [0xD5,0x55] for value in data[12:]): self.silent_packets += 1
            if other in self.targets:
                try: self.media.sendto(data, self.targets[other])
                except OSError: return
    def close(self):
        self.running = False; self.sock.close(); self.media.close()
        self.thread.join(timeout=1); self.media_thread.join(timeout=1)

if __name__ == '__main__':
    import itertools
    cases = [(c, r, p, False) for c, r, p in itertools.product(['PCMA', 'PCMU', 'G722', 'opus'], [False, True], [False, True])]
    cases.append(('PCMA', True, False, True))
    if '--number-only' in sys.argv[2:]: cases = cases[-1:]
    for codec, rewrite, preselected, numbered in cases:
        proxy = SelfCallProxy(rewrite, numbered)
        try:
            env = dict(os.environ, BARESIP_SELF_CALL_PORT=str(proxy.port), BARESIP_SELF_CALL_REWRITE=str(int(rewrite)), BARESIP_SELF_CODEC=codec, BARESIP_SELF_PRESELECT_FILE=str(int(preselected)))
            if numbered: env['BARESIP_SELF_CALL_NUMBER'] = '+12025550123'
            result = subprocess.run([sys.argv[1]], env=env, timeout=60)
            assert result.returncode == 0, 'Native self-call fixture failed'
            assert len(proxy.contacts) == 2, 'Both accounts must register'
            assert not proxy.errors, proxy.errors
            assert proxy.packets['a'] >= 20, proxy.packets
            if codec == 'PCMA': assert proxy.silent_packets >= 20, 'Expected encoded file silence was not received'
            assert proxy.packets['b'] == 0, 'Receiver must remain listen-only'
            if numbered: assert proxy.keepalives['b'] > 0, 'Receiver did not open its NAT path'
            print('PASS: ' + codec + ' two accounts in one app; ' + ('rewritten' if rewrite else 'shared') + ' SIP Call-ID; synthetic file RTP relayed A → B; no reverse audio')
        finally: proxy.close()
