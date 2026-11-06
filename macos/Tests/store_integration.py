#!/usr/bin/env python3
"""Real app state against a local SIP/media peer; no microphone or provider."""
import os, subprocess, sys
import sip_integration as sip
peer = sip.Peer(audio=True)
peer.refer_failure = '404 Not Found'
try:
    env = dict(os.environ, BARESIP_TEST_SIP_PORT=str(peer.port), BARESIP_TEST_PASSWORD=sip.PASSWORD)
    result = subprocess.run([sys.argv[1]], env=env, timeout=60)
    assert result.returncode == 0, 'Native app-state fixture failed'
    infos = peer.requests('INFO')
    assert [sip.re.search(r'Signal=([^\r]+)', m)[1] for m in infos] == ['1', '2', '#'], 'Listen-only keypad must deliver selected-call SIP INFO digits'
    assert 5 in peer.dtmf_events, 'File-input keypad did not send RTP telephone-event 5'
    assert not peer.auth_failures, 'Independent registration digest failed'
    print('PASS: remote peer received keypad digits via SIP INFO and RTP telephone-event')
    invites = peer.requests('INVITE')
    refers = peer.requests('REFER')
    assert len(refers) == 1 and 'Refer-To: sip:missing-transfer@' in refers[0]
    assert sip.re.search(r'Call-ID: ([^\r]+)', refers[0])[1] == list(dict.fromkeys(sip.re.search(r'Call-ID: ([^\r]+)', m)[1] for m in invites))[2], 'Transfer targeted the selected call instead of the explicitly requested call'
    print('PASS: REFER/NOTIFY 404 preserves calls and attributes destination/failure to the explicitly requested call')
    assert len({sip.re.search(r'Call-ID: ([^\r]+)', msg)[1] for msg in invites}) == 4
    assert 'a=recvonly' in invites[0], 'Missing microphone must negotiate listen-only'
    assert any('a=sendrecv' in msg for msg in invites), 'Playing a file must enable transmission'
    assert peer.rtp_non_silent >= 5, 'The remote peer did not receive the synthetic file content'
    grouped = {}
    for message in invites:
        call_id = sip.re.search(r'Call-ID: ([^\r]+)', message)[1]
        grouped.setdefault(call_id, []).append(message)
    assert sum(sum('a=inactive' in m for m in messages) >= 2 and sum('a=recvonly' in m for m in messages) >= 3 for messages in grouped.values()) >= 3, 'Repeated hold/resume SDP transitions missing'
    print('PASS: repeated hold/resume SDP directions and selected-call auto-hold isolation')
    print('PASS: remote peer received converted file samples over RTP; microphone-free calls negotiated recvonly')
finally:
    peer.close()
