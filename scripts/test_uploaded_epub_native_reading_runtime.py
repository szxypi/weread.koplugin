#!/usr/bin/env python3
"""Exercise the private CB reader supervisor against synthetic loopback data."""
import argparse,json,os,subprocess,threading
from pathlib import Path
from mock_weread import CB_READING_ID,MockServer
from verify_cb_reading import CbReadingProbe
from verify_owner_reading import decode_envelope

REPO=Path(__file__).resolve().parent.parent


class Response:
    def __init__(self,status,body):
        self.status=status;self.body=body if isinstance(body,bytes) else body.encode() if isinstance(body,str) else json.dumps(body).encode()
    def __enter__(self):return self
    def __exit__(self,*_args):return False
    def read(self,limit):return self.body[:limit]


class Opener:
    def __init__(self,server):self.server=server
    def open(self,request,timeout):
        data=json.loads(request.data) if request.data else {}
        result=self.server.route(request.get_method(),request.full_url,data)
        return Response(result[0],result[1])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True);args=parser.parse_args()
    server=MockServer(0);server.cb_reading=True;thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        probe=CbReadingProbe();probe.opener=Opener(server);probe.vid='900000';probe.set_cookie('wr_vid','900000');probe.set_cookie('wr_skey','mock_key');probe.authenticated=True
        sample=probe.prepare(1,expected_book_id=CB_READING_ID)[0]
        payload={k:sample[k] for k in ('book_id','chapter_uid','source_format','source_text','source_raw_sha256','source_sample_offset','shelf_ids','shelf_books')}
        payload.update(cb_reading=True,vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'),cb_mock_port=server.server_port)
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            env=os.environ|dict(LD_LIBRARY_PATH=str(args.koreader/'libs'),SDL_VIDEODRIVER='dummy')
            cmd=['python3',str(REPO/'scripts/run_owner_reading_probe.py'),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
                '--width',str(width),'--height',str(height),'--dpi',str(dpi),'--cb-reading','--cb-mock-port',str(server.server_port)]
            child=subprocess.run(cmd,input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=360)
            value=decode_envelope(child.stdout,'900000',cb_reading=True)
            if child.returncode or value['report']['result']!='PASS':raise AssertionError('synthetic reader stage '+repr(value['report']))
            assert value['report']['profile_removed'] and len(value['report']['stages'])==2
            print(f'PASS: scoped native CB book selection, reading and offline reopen {width}x{height}',flush=True)
        assert server.request_totals[('/web/book/read','')]==0 and server.request_totals[('/web/login/renewal','')]==0
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
