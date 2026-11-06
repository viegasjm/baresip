#!/usr/bin/env python3
"""Normal-interface engine -> local TCP PBX; no provider or microphone."""
import pathlib, re, socket, subprocess, tempfile, threading
import sip_integration as sip


def run():
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(.2)
    port = listener.getsockname()[1]
    requests, errors = [], []
    stop = threading.Event()

    def serve():
        try:
            while not stop.is_set():
                try: conn, _ = listener.accept()
                except socket.timeout: continue
                with conn:
                    conn.settimeout(.2)
                    buffer = b''
                    while not stop.is_set():
                        try: data = conn.recv(65535)
                        except socket.timeout: continue
                        if not data: break
                        buffer += data
                        while b'\r\n\r\n' in buffer:
                            header, body = buffer.split(b'\r\n\r\n', 1)
                            length = int(re.search(rb'Content-Length:\s*(\d+)', header, re.I)[1])
                            if len(body) < length: break
                            message = (header + b'\r\n\r\n' + body[:length]).decode()
                            buffer = body[length:]
                            requests.append(message)
                            method = message.split()[0]
                            if method == 'ACK': continue
                            headers = dict((k.lower(), v.strip()) for k, v in (line.split(':', 1) for line in header.decode().split('\r\n')[1:]))
                            sdp = ''
                            if method == 'INVITE':
                                sdp = 'v=0\r\no=fixture 1 1 IN IP4 127.0.0.1\r\ns=TCP loopback test\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 19000 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=sendonly\r\n'
                            response = 'SIP/2.0 200 OK\r\n' + ''.join(f'{name}: {headers[name.lower()]}\r\n' for name in ['Via', 'From', 'Call-ID', 'CSeq'])
                            to = headers['to']
                            response += f'To: {to}' + ('' if ';tag=' in to else ';tag=tcp-fixture') + '\r\n'
                            response += f'Contact: <sip:fixture@127.0.0.1:{port};transport=tcp>\r\n'
                            if method == 'REGISTER': response += 'Expires: 300\r\n'
                            if sdp: response += 'Content-Type: application/sdp\r\n'
                            response += f'Content-Length: {len(sdp.encode())}\r\n\r\n{sdp}'
                            conn.sendall(response.encode())
        except Exception as error:
            if not stop.is_set(): errors.append(str(error))

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    process = control = None
    try:
        with tempfile.TemporaryDirectory(prefix='baresip-tcp-loopback-') as temp:
            folder = pathlib.Path(temp)
            with socket.socket() as reserved:
                reserved.bind(('127.0.0.1', 0)); ctrl_port = reserved.getsockname()[1]
            sip.LOG_PATH = folder / 'engine.log'
            # Deliberately no net_interface override, matching the native app.
            (folder / 'config').write_text(f'''sip_listen 0.0.0.0:0
sip_transports udp,tcp
module g711
module menu
module ctrl_tcp
module_app account
account_password_prompt no
ctrl_tcp_listen 127.0.0.1:{ctrl_port}
''')
            aor = f'sip:local-client@127.0.0.1:{port}'
            (folder / 'accounts').write_text(f'<{aor};transport=tcp>;regint=300;audio_codecs=PCMA/8000/1\n')
            with sip.LOG_PATH.open('w') as log:
                process = subprocess.Popen([str(sip.ENGINE), '-f', temp], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                def connect():
                    nonlocal control
                    try: control = sip.Control(ctrl_port); return control
                    except OSError: return None
                sip.wait_for(connect, 'TCP loopback engine startup')
                sip.wait_for(lambda: any(m.startswith('REGISTER ') for m in requests), 'TCP REGISTER missing')
                sip.wait_for(lambda: 'OK' in control.command('reginfo'), 'TCP registration failed')
                control.command('uafind', aor)
                control.command('dialdir', f'sip:+12025550123@127.0.0.1:{port} audio=recvonly video=inactive')
                call = control.event('CALL_ESTABLISHED')['id']
                invite = next(m for m in requests if m.startswith('INVITE '))
                assert 'SIP/2.0/TCP' in invite and 'c=IN IP4 127.0.0.1' in invite
                control.command('hangup')
                control.event('CALL_CLOSED', call)
                sip.wait_for(lambda: any(m.startswith('BYE ') for m in requests), 'TCP BYE missing')
                assert not errors, errors
                assert 'no laddr' not in sip.LOG_PATH.read_text()
                print('PASS: normal-interface TCP loopback registration, numeric call, loopback SDP, answer and hangup')
    finally:
        if control: control.sock.close()
        if process:
            process.terminate(); process.wait(timeout=5)
        stop.set(); thread.join(timeout=1); listener.close()


if __name__ == '__main__': run()
