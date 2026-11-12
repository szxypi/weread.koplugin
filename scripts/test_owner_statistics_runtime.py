#!/usr/bin/env python3
"""Run owner statistics acceptance against local synthetic HTTP only."""
import argparse
import json
from pathlib import Path
import subprocess
import threading

import mock_weread
from mock_weread import MockServer
from owner_statistics_contract import decode_runner
from verify_owner_statistics import prepare


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--long-streak',action='store_true',help='synthetic 24-month backfill with overlapping historical detail')
    parser.add_argument('--account-name',action='store_true',help='render a synthetic nickname in the native account card')
    args=parser.parse_args();original=mock_weread.reading_statistics
    if args.long_streak:
        def statistics(mode,base_time=0):
            value=original(mode,base_time)
            if mode=='monthly':value['readTimes']={key:max(1,seconds) for key,seconds in value['readTimes'].items()}
            return value
        mock_weread.reading_statistics=statistics
    server=MockServer(0);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    class Probe:
        def request(self,_stage,url,credentials=None):
            code,value=server.route('GET',url,{})[:2];assert code==200;return value
    try:
        grant=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)
        payload=prepare(grant,Probe());payload['mock_port']=server.server_port
        if args.account_name:payload['account_name']='合成阅读者 · Native 123'
        if args.long_streak:assert len(payload['profile_months'])==24 and sum(row['count'] for row in payload['rules'])==30
        command=['python3',str(Path(__file__).with_name('run_owner_statistics.py')),'--koreader',str(args.koreader),
                 '--candidate',str(args.candidate),'--mock-port',str(server.server_port),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
        child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=320)
        value=decode_runner(child.stdout);assert child.returncode==0 and value['result']=='PASS',value
        assert value['stages'][0]['request_counts']==[row['count'] for row in payload['rules']]
        assert all(row['account_name_present']==args.account_name for row in value['stages'])
        print(json.dumps(dict(result='PASS',synthetic_only=True,long_streak=args.long_streak,account_name=args.account_name,ui=value,real_account_requests_attempted=0),indent=2))
    finally:server.shutdown();server.server_close();thread.join();mock_weread.reading_statistics=original


if __name__=='__main__':main()
