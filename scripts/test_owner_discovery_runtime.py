#!/usr/bin/env python3
"""Synthetic service only: native bookstore batches and offline process."""
import argparse
import json
from pathlib import Path
import subprocess
import threading
from mock_weread import BOOKS,MockServer
from verify_owner_discovery import DiscoveryProbe,private_output,compare_private,prepare


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();authors=[row['author'] for row in BOOKS]
    for row in BOOKS:row['author']+='三体'
    server=MockServer(0);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    class LocalProbe(DiscoveryProbe):
        def request(self,stage,url,body=None,credentials=None,timeout=15):
            self.guard(stage,url,body);code,value=server.route('GET',url,{})[:2];assert code==200
            self.report['stages'].append(dict(stage=stage,status=code));return value
    try:
        grant=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)
        payload,_=prepare(grant,LocalProbe());payload['mock_port']=server.server_port
        command=['python3',str(Path(__file__).with_name('run_owner_discovery.py')),'--koreader',str(args.koreader),
            '--candidate',str(args.candidate),'--mock-port',str(server.server_port),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
        child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=320)
        value,private=private_output(child.stdout);compare_private(private,payload['samples']);assert child.returncode==0 and value['result']=='PASS',value
        print(json.dumps(dict(result='PASS',synthetic_only=True,ui=value,real_account_requests_attempted=0),indent=2))
    finally:
        server.shutdown();server.server_close();thread.join()
        for row,author in zip(BOOKS,authors):row['author']=author


if __name__=='__main__':main()
