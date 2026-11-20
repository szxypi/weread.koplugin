#!/usr/bin/env python3
"""Exercise the actual native acceptance executor only against local fixtures."""
import argparse
import json
from pathlib import Path
import subprocess
import threading

from mock_weread import MockServer,BOOK_ID
from owner_shelf_membership_contract import decode_runner
from secure_shelf_experiment import canonical,fingerprint
from verify_native_metadata import normalize_native
from verify_eink_shelf_write import snapshot
from verify_owner_shelf_membership import members_digest
import hashlib


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();server=MockServer(0);server.shelf_removed.add(BOOK_ID)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    base='https://i.weread.qq.com';credentials=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)
    reports=[]
    try:
        for apply in (False,True):
            rows=snapshot(server.route('GET',base+'/shelf/sync',{})[1]);digest=members_digest(rows)
            metadata=normalize_native(server.route('GET',base+'/book/info?bookId='+BOOK_ID,{})[1],BOOK_ID)
            plan=dict(owner=credentials['vid'],book_id=BOOK_ID,members_sha256=digest,grant_sha256=hashlib.sha256(canonical(credentials)).hexdigest())
            payload=dict(credentials=credentials,book_id=BOOK_ID,expected_metadata=metadata,shelf_books=len(rows),members_digest=digest,
                permit_writes=apply,plan_fingerprint=fingerprint(plan),intent_digest='a'*64 if apply else '',mock_port=server.server_port)
            command=['python3',str(Path(__file__).with_name('run_owner_shelf_membership.py')),'--koreader',str(args.koreader),
                '--candidate',str(args.candidate),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port)]
            if apply:command.append('--armed')
            child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=180)
            envelope=decode_runner(child.stdout,apply);reports.append(envelope['report'])
            assert not child.returncode and envelope['report']['result']=='PASS',envelope['report']
            assert envelope['private']['final_members_digest']==digest
            assert members_digest(snapshot(server.route('GET',base+'/shelf/sync',{})[1]))==digest
    finally:server.shutdown();server.server_close();thread.join()
    print(json.dumps(dict(result='PASS',synthetic_only=True,stages=reports,real_account_requests_attempted=0),indent=2))


if __name__=='__main__':main()
