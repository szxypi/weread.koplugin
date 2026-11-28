#!/usr/bin/env python3
"""Exercise host loss across Docker with synthetic credentials and service only."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
from urllib.parse import urlencode
from mock_weread import BOOK_ID
from native_cloud_pin_roundtrip import RoundtripFailure,native_child
from native_cloud_pin_trial import bind
from selection_trial_mock import credentials
from test_native_cloud_pin_runtime import Server
from verify_eink_login import BASE
from verify_native_metadata import normalize_native
from verify_pin_preflight import fingerprint


def serve():
    server=Server('normal');thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    print(json.dumps({'port':server.server_port}),flush=True)
    try:
        sys.stdin.readline()
        print(json.dumps({'posts':len(server.posts),'pin':server.pin}),flush=True)
    finally:server.shutdown();server.server_close();thread.join()


def main():
    if sys.argv[1:]==['--serve']:serve();return
    docker=['docker','exec','-i','-w','/validation/runtime/lib/koreader','weread-validation']
    server=subprocess.Popen(docker+['python3','-u','/source/scripts/test_native_cloud_pin_docker_boundary.py','--serve'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    try:
        port=json.loads(server.stdout.readline())['port'];grant=credentials();fixture=Server('normal')
        try:
            def get(path):return deepcopy(fixture.route('GET',BASE+path,{})[1])
            shelf=get('/shelf/sync');progress=get('/book/getProgress?'+urlencode({'bookId':BOOK_ID}))
            plan=bind(grant['vid'],BOOK_ID,fingerprint(grant),shelf,progress)
            metadata=normalize_native(get('/book/info?'+urlencode({'bookId':BOOK_ID})),BOOK_ID)
            payload=dict(credentials=grant,book_id=BOOK_ID,expected_metadata=metadata,shelf_books=len(shelf['books']),
                         mark=plan['mark'],restore=plan['restore'],mock_port=port)
        finally:fixture.server_close()
        command=docker+['xvfb-run','-a','python3','/source/scripts/run_owner_cloud_pin_trial.py',
                        '--koreader','/validation/runtime/lib/koreader','--candidate','/validation/cloud-pin-preview-candidate.zip',
                        '--width','600','--height','800','--dpi','167','--mock-port',str(port)]
        def lost(_step):raise ValueError('synthetic/host_loss')
        try:native_child(payload,command,armed=True,on_step=lost)
        except RoundtripFailure:pass
        else:raise AssertionError('host loss not detected')
        server.stdin.write('stop\n');server.stdin.flush();observed=json.loads(server.stdout.readline())
        assert observed=={'posts':1,'pin':True},observed
        server.wait(timeout=15)
        # Docker exec's client may exit before the container supervisor finishes cleanup.
        for _ in range(40):
            result=subprocess.run(['docker','exec','weread-validation','python3','-c',
                "from pathlib import Path; print(len(list(Path('/dev/shm').glob('weread-cloud-pin-trial-*'))))"],capture_output=True,text=True,check=True)
            if result.stdout.strip()=='0':break
            time.sleep(.25)
        else:raise AssertionError('container profile not removed')
        print(json.dumps(dict(result='PASS',synthetic_pin_posts=1,synthetic_unpin_posts=0,profile_removed=True,real_account_data_posts=0)))
    finally:
        if server.poll() is None:server.terminate();server.wait(timeout=15)

if __name__=='__main__':main()
