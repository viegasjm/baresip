#!/usr/bin/env python3
"""Real app state against a local SIP/media peer; no microphone or provider."""
import os, subprocess, sys
import sip_integration as sip
peer = sip.Peer(audio=True)
try:
    env = dict(os.environ, BARESIP_TEST_SIP_PORT=str(peer.port))
    result = subprocess.run([sys.argv[1]], env=env, timeout=60)
    assert result.returncode == 0, 'Native app-state fixture failed'
    invites = peer.requests('INVITE')
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
