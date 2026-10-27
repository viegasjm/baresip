#!/usr/bin/env python3
"""Opt-in real CoreAudio test. Only silent RTP is returned; no audio is saved."""
import os, pathlib, socket, struct, subprocess, tempfile, time, wave
RECEIVE_ONLY = os.environ.get("BARESIP_AUDIO_RECEIVE_ONLY") == "1"
FILE_TEST = os.environ.get("BARESIP_AUDIO_FILE_TEST") == "1"
OUTPUT_UID = os.environ.get("BARESIP_AUDIO_OUTPUT_UID", "default")
import sip_integration as sip

CODEC = os.environ.get("BARESIP_AUDIO_CODEC", "PCMA")
peer = sip.Peer(audio=True, codec=CODEC)
process = None
control = None
try:
    with tempfile.TemporaryDirectory(prefix='baresip-audio-test-') as directory:
        folder = pathlib.Path(directory)
        sip.LOG_PATH = pathlib.Path(__file__).resolve().parents[2] / 'build/audio-test.log'
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1', 0))
            port = reserved.getsockname()[1]
        folder.joinpath('config').write_text(f'''net_interface 127.0.0.1
sip_listen 127.0.0.1:0
sip_transports udp
audio_player coreaudio,{OUTPUT_UID}
audio_source coreaudio,default
audio_alert coreaudio,{OUTPUT_UID}
ausrc_channels 1
auplay_channels 1
call_max_calls 4
call_hold_other_calls no
module coreaudio
module aufile
module g711
module g722
module opus
module auconv
module auresamp
module menu
module ctrl_tcp
module_app account
ctrl_tcp_trace yes
ctrl_tcp_listen 127.0.0.1:{port}
''')
        file_path = folder / 'input.wav'
        with wave.open(str(file_path), 'wb') as wav:
            wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            wav.writeframes(b''.join(struct.pack('<h', 512 if i % 40 < 20 else -512) for i in range(9600)))
        aor = f'sip:audio-test@127.0.0.1:{peer.port}'
        folder.joinpath('accounts').write_text(f'<{aor};transport=udp>;regint=0;audio_codecs={peer.codec.account}\n')
        with sip.LOG_PATH.open('w') as output:
            process = subprocess.Popen([str(sip.ENGINE), '-f', directory], stdin=subprocess.DEVNULL, stdout=output, stderr=output)
            def connect():
                global control
                if process.poll() is not None: raise AssertionError('Engine exited before connection')
                try: control = sip.Control(port); return control
                except OSError: return None
            sip.wait_for(connect, 'Audio engine did not start')
            control.command('uafind', aor)
            control.command('uapassword', 'value=' + sip.quote(sip.PASSWORD, safe='') + ' 0')
            control.command('uareg', '300 0')
            sip.wait_for(lambda: peer.registrations, 'Audio test registration missing')
            control.command('dialdir' if RECEIVE_ONLY else 'dial', f'sip:local-audio@127.0.0.1:{peer.port}' + (' audio=recvonly video=inactive' if RECEIVE_ONLY else ''))
            outgoing = control.event('CALL_ESTABLISHED')['id']
            sip.wait_for(lambda: (peer.rtp_sent if RECEIVE_ONLY else peer.rtp_received) >= 20, 'Audio RTP missing', timeout=5)
            control.event('CALL_RTPESTAB', outgoing)
            control.command('callfind', outgoing)
            details = control.command('audio_debug')
            assert 'coreaudio' in details, details
            control.command('hold')
            time.sleep(.2)
            control.command('resume')
            before = peer.rtp_sent if RECEIVE_ONLY else peer.rtp_received
            sip.wait_for(lambda: (peer.rtp_sent if RECEIVE_ONLY else peer.rtp_received) >= before + 15, 'RTP did not resume', timeout=5)
            if FILE_TEST:
                control.command('callsource', 'aufile,' + str(file_path))
                sip.wait_for(lambda: peer.rtp_received >= 10, 'File RTP missing')
                control.event('END_OF_FILE', outgoing)
                assert outgoing in control.command('callstat'), 'EOF ended the call'
                control.command('callsource', 'none')
                time.sleep(.2)
                count = peer.rtp_received
                time.sleep(.2)
                assert peer.rtp_received <= count + 1, 'Listen only must stop file RTP'
                assert 'a=recvonly' in peer.requests('INVITE')[-1]
                print(f'PASS: live {CODEC} file injection; EOF preserves call; Listen only stops transmission')
                control.command('dialdir', f'sip:isolated@127.0.0.1:{peer.port} audio=recvonly video=inactive')
                other = control.event('CALL_ESTABLISHED')['id']
                other_invite = next(x for x in peer.requests('INVITE') if 'Call-ID: ' + other in x)
                other_port = int(sip.re.search(r'm=audio (\d+)', other_invite)[1])
                control.command('callfind', outgoing)
                control.command('callsource', 'aufile,' + str(file_path))
                control.event('END_OF_FILE', outgoing)
                assert peer.rtp_by_port.get(other_port, 0) == 0, 'File leaked into another call'
                control.command('callfind', other)
                assert other in control.command('callstat')
                control.command('hangup', other)
                control.event('CALL_CLOSED', other)
                control.command('callfind', outgoing)
                print(f'PASS: {CODEC} file input stays isolated to the selected call with two active calls')
            control.command('hangup', outgoing)
            control.event('CALL_CLOSED', outgoing)
            if RECEIVE_ONLY and not FILE_TEST:
                assert peer.rtp_received == 0, 'Receive-only test must not use the microphone'
                assert 'audio_recv: player started' in sip.LOG_PATH.read_text()
                print(f'PASS: selected real CoreAudio speaker {OUTPUT_UID}; {CODEC} receive-only call; {peer.rtp_sent} silent RTP packets; hold/resume; zero microphone packets')
            elif not FILE_TEST: print(f'PASS: outgoing real CoreAudio call; bidirectional RTP; hold/resume; {peer.rtp_received} microphone packets discarded')
            contact = next(iter(peer.registrations.values()))
            incoming = peer.incoming(contact, aor)
            control.event('CALL_INCOMING', incoming)
            if FILE_TEST:
                control.command('callfind', incoming)
                control.command('callsource', 'aufile,' + str(file_path))
            control.command('acceptdir' if RECEIVE_ONLY and not FILE_TEST else 'accept', f'audio=recvonly video=inactive callid={incoming}' if RECEIVE_ONLY and not FILE_TEST else incoming)
            control.event('CALL_ESTABLISHED', incoming)
            before = peer.rtp_sent if RECEIVE_ONLY else peer.rtp_received
            sip.wait_for(lambda: (peer.rtp_sent if RECEIVE_ONLY else peer.rtp_received) >= before + 15, 'Incoming call RTP missing', timeout=5)
            control.event('CALL_RTPESTAB', incoming)
            if FILE_TEST:
                control.event('END_OF_FILE', incoming)
                assert incoming in control.command('callstat')
            control.command('hangup', incoming)
            control.event('CALL_CLOSED', incoming)
            if RECEIVE_ONLY and not FILE_TEST: assert peer.rtp_received == 0, 'Incoming receive-only call opened the microphone'
            print(f'PASS: incoming {CODEC} call answered with real CoreAudio' + (' and file input; EOF preserves call' if FILE_TEST else '; RTP received'))
            if FILE_TEST:
                control.command('ausrcdefault', 'aufile,' + str(file_path))
                control.command('dial', f'sip:file-start@127.0.0.1:{peer.port}')
                started = control.event('CALL_ESTABLISHED')['id']
                control.event('END_OF_FILE', started)
                assert started in control.command('callstat')
                control.command('hangup', started)
                control.event('CALL_CLOSED', started)
                if CODEC == 'PCMA': assert peer.rtp_non_silent >= 5
                print(f'PASS: {CODEC} file selected before outgoing call; remote RTP; EOF preserves call')
            log = sip.LOG_PATH.read_text()
            assert 'audio_recv: player started' in log
            assert f'audio_recv: Set audio decoder: {CODEC}' in log, log
            if OUTPUT_UID != 'default': assert f"player: using device '{OUTPUT_UID}'" in log, log
            if RECEIVE_ONLY: assert 'opening microphone' not in log.lower(), log
            assert 'failed' not in log.lower(), log
except Exception:
    if process and sip.LOG_PATH.exists():
        # This fixture uses only synthetic credentials. Preserve diagnostic text, no media.
        log = sip.LOG_PATH.read_text()
        pathlib.Path(__file__).resolve().parents[2].joinpath('build/audio-test.log').write_text(log)
        print('\n'.join(line for line in log.splitlines() if any(word in line.lower() for word in ['coreaudio', 'audio:', 'error', 'failed', 'terminated'])))
    raise
finally:
    if control: control.sock.close()
    if process:
        process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    peer.close()
