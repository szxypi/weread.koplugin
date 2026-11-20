#!/usr/bin/env python3
"""Signed-out native public book lists against synthetic HTTP, then offline."""
import argparse
import json
from pathlib import Path
import subprocess
import threading
from urllib.request import Request,urlopen

from mock_weread import MockServer
from public_category_ui_contract import FRAME,compare_runner
from verify_category_books import Probe


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();repo=Path(__file__).resolve().parent.parent;root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False)
    candidate=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],check=True)
    server=MockServer(0,root/'requests.jsonl');thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    class Opener:
        def open(self,request,timeout):
            assert not request.data and request.get_method()=='GET' and set(dict(request.header_items()))=={'User-agent','Accept','Referer'}
            response=urlopen(Request(request.full_url.replace('https://weread.qq.com','http://127.0.0.1:'+str(server.server_port)),headers=dict(request.header_items())),timeout=timeout)
            response.url=request.full_url;return response
    try:
        probe=Probe(opener=Opener(),pause=lambda _duration:None);payload=probe.prepare()
        command=['python3',str(repo/'scripts/run_public_category_ui.py'),'--koreader',str(args.koreader),'--candidate',str(candidate),
                 '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port)]
        result=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=360)
        if result.returncode:
            value=json.loads(result.stdout.split(FRAME)[1])
            diagnostic=dict(result='UNVERIFIED',runner_error=value['runner_error'],stages=[dict(phase=row['phase'],failed_line=row['failed_line']) for row in value['stages']])
            (root/'failure.json').write_text(json.dumps(diagnostic)+'\n')
            raise RuntimeError('native public category UI failed; inspect bounded failure metadata')
        proof=compare_runner(result.stdout,payload);assert result.returncode==0
        public=dict(result='PASS',synthetic_only=True,python_gets=probe.calls,ui=proof)
        (root/'result.json').write_text(json.dumps(public,indent=2)+'\n');print(json.dumps(public))
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
