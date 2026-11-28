#!/usr/bin/env python3
"""Exercise the owner-profile runner against the local synthetic service."""
import argparse
import json
from pathlib import Path
import subprocess
import threading

from mock_weread import MockServer


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--with-statistics',action='store_true')
    args=parser.parse_args()
    server=MockServer(0);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        payload=dict(owner='900000',cookies={'wr_vid':'900000','wr_skey':'mock-only'},
                     expected_name='Synthetic Web reader',mock_port=server.server_port)
        if args.with_statistics:
            payload.update(with_statistics=True,native_credentials=dict(vid='900000',accessToken='mock-native-access',
                refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19))
        command=['python3',str(Path(__file__).with_name('run_owner_profile_account.py')),
                 '--koreader',str(args.koreader),'--candidate',str(args.candidate),'--mock-port',str(server.server_port),
                 '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
        if args.with_statistics:command.append('--with-statistics')
        child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=220)
        result=json.loads(child.stdout);assert child.returncode==0 and result['result']=='PASS',result
        assert result['profile_removed'] and result['installed_bytes_match']
        print(json.dumps(dict(result='PASS',synthetic_only=True,ui=result,real_account_requests=0)))
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
