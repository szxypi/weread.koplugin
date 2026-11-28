#!/usr/bin/env python3
"""Synthetic service only: native bookstore batches and offline process."""
import argparse
import json
from pathlib import Path
import subprocess
import threading
from mock_weread import BOOKS,MockServer
from verify_owner_discovery import DiscoveryProbe,private_output,compare_private,page,prepare


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--with-skill-recommendation',action='store_true')
    args=parser.parse_args();authors=[row['author'] for row in BOOKS]
    for row in BOOKS:row['author']+='三体'
    skill_page = dict(books=[dict(book) for book in BOOKS[:20]])
    class BookstoreServer(MockServer):
        def route(self, method, target, data):
            if (args.with_skill_recommendation and method == 'POST'
                    and target == 'https://i.weread.qq.com/api/agent/gateway'
                    and data.get('api_name') == '/book/recommend'):
                assert data['maxIdx'] == 0
                return 200, skill_page
            return super().route(method, target, data)
    server=BookstoreServer(0)
    server.control['empty_native_recommend'] = args.with_skill_recommendation
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    class LocalProbe(DiscoveryProbe):
        def request(self,stage,url,body=None,credentials=None,timeout=15):
            self.guard(stage,url,body);code,value=server.route('GET',url,{})[:2];assert code==200
            self.report['stages'].append(dict(stage=stage,status=code));return value
    try:
        grant=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)
        payload,_=prepare(grant,LocalProbe());payload['mock_port']=server.server_port
        if args.with_skill_recommendation:
            payload['skill_key'] = 'wrk-mock-recommendation'
            model = page('recommend', skill_page)
            for book in model['books']:
                book.pop('searchIdx')
            payload['samples'][-1]['expected'] = model
        command=['python3',str(Path(__file__).with_name('run_owner_discovery.py')),'--koreader',str(args.koreader),
            '--candidate',str(args.candidate),'--mock-port',str(server.server_port),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
        child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=320)
        value,private=private_output(child.stdout);compare_private(private,payload['samples']);assert child.returncode==0 and value['result']=='PASS',value
        assert value['stages'][0]['gateway_read_posts'] == int(args.with_skill_recommendation)
        print(json.dumps(dict(result='PASS',synthetic_only=True,ui=value,real_account_requests_attempted=0),indent=2))
    finally:
        server.shutdown();server.server_close();thread.join()
        for row,author in zip(BOOKS,authors):row['author']=author


if __name__=='__main__':main()
