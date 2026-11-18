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
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True);parser.add_argument('--single-page',action='store_true');parser.add_argument('--txt',action='store_true');parser.add_argument('--txt-short',action='store_true');parser.add_argument('--txt-single',action='store_true');parser.add_argument('--txt-empty-second',action='store_true');args=parser.parse_args()
    if args.txt_empty_second:args.txt_single=True
    if args.txt_single:args.txt=True;args.single_page=True
    if args.txt_short:args.txt=True
    if args.single_page and args.txt and not args.txt_single:parser.error('choose one source format')
    server=MockServer(0);server.cb_reading=True;thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        if args.txt:
            import mock_weread
            from verify_cb_txt_native_fixture import BODY,SHORT_BODY,SINGLE_BODY
            server.content_format='txt';mock_weread.chapter_txt=lambda _uid:(SINGLE_BODY if args.txt_single else SHORT_BODY if args.txt_short else BODY).decode('utf-8')
            if args.txt_empty_second:
                from urllib.parse import urlsplit
                original=server.route
                def route(method,url,data):
                    path=urlsplit(url).path
                    if method=='POST' and path in ('/web/book/chapter/t_0','/web/book/chapter/t_1'):
                        status,result=original(method,url,data)
                        if status!=200:return status,result
                        return (200,mock_weread.shards(SINGLE_BODY.decode('utf-8'),1)[0]) if path.endswith('t_0') else (200,'{}')
                    return original(method,url,data)
                server.route=route
        if args.single_page and not args.txt_single:
            from synthetic_upload_pdf import TEXT
            server.chapter_source=lambda _uid,_revision=None: '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title></head><body><p>'+TEXT+'</p></body></html>'
        probe=CbReadingProbe();probe.opener=Opener(server);probe.vid='900000';probe.set_cookie('wr_vid','900000');probe.set_cookie('wr_skey','mock_key');probe.authenticated=True
        sample=probe.prepare(1,expected_book_id=CB_READING_ID)[0]
        if args.txt:assert sample['source_format']=='web_txt'
        payload={k:sample[k] for k in ('book_id','chapter_uid','source_format','source_text','source_raw_sha256','source_sample_offset','shelf_ids','shelf_books')}
        payload.update(cb_reading=True,vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'),cb_mock_port=server.server_port)
        if args.single_page:payload['cb_single_page']=True
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            env=os.environ|dict(LD_LIBRARY_PATH=str(args.koreader/'libs'),SDL_VIDEODRIVER='dummy')
            cmd=['python3',str(REPO/'scripts/run_owner_reading_probe.py'),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
                '--width',str(width),'--height',str(height),'--dpi',str(dpi),'--cb-reading','--cb-mock-port',str(server.server_port)]
            if args.single_page:cmd.append('--cb-single-page')
            child=subprocess.run(cmd,input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=360)
            value=decode_envelope(child.stdout,'900000',cb_reading=True,single_page=args.single_page)
            if child.returncode or value['report']['result']!='PASS':raise AssertionError('synthetic reader stage '+repr(value['report']))
            assert value['report']['profile_removed'] and len(value['report']['stages'])==2
            if args.single_page:assert all(s['pages']==1 and s['page_turn'] is False for s in value['report']['stages'])
            print(f'PASS: scoped native CB book selection, reading and offline reopen {width}x{height}',flush=True)
        assert server.request_totals[('/web/book/read','')]==0 and server.request_totals[('/web/login/renewal','')]==0
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
