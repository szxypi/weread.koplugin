#!/usr/bin/env python3
"""Installed FileManager plugin recovery against a loopback-only account."""
import argparse,json,subprocess,tempfile,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs,urlsplit
from native_shelf_renewal_broker import Broker,execute,shelf_projection
from secure_native_session import NativeSessionStore
from test_secure_native_session import Backend
from test_native_shelf_renewal_broker import grant

REPO=Path(__file__).resolve().parent.parent
SHELF=dict(books=[dict(bookId='42',title='Synthetic',author='Author',finishReading=0,secret=0)],archive=[])


class Handler(BaseHTTPRequestHandler):
    def log_message(self,*_args):pass
    def do_GET(self):self.dispatch()
    def do_POST(self):self.dispatch()
    def dispatch(self):
        target=urlsplit(parse_qs(urlsplit(self.path).query).get('url',[''])[0]);self.server.calls.append((self.command,target.path))
        self.server.leaked |= any(k.lower() in ('vid','accesstoken','cookie') for k in self.headers)
        code=200
        if target.hostname=='i.weread.qq.com' and target.path=='/shelf/sync' and self.command=='GET':
            code=200 if self.server.auth_posts else 401;data=SHELF if code==200 else {'errcode':-1}
        elif target.hostname=='i.weread.qq.com' and target.path=='/login' and self.command=='POST':
            data=json.loads(self.rfile.read(int(self.headers['Content-Length'])));self.server.auth_posts+=1
            from native_source_recovery_broker import check_refresh
            check_refresh(data,grant());data={} if self.server.mode=='noack' else dict(vid=12345678,accessToken='synthetic-renewed')
        else:code=400;data={}
        raw=json.dumps(data).encode();self.send_response(code);self.send_header('Content-Length',str(len(raw)));self.end_headers()
        try:self.wfile.write(raw)
        except (BrokenPipeError,ConnectionResetError):pass


def run(runtime):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='shelf-renewal-package-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                for mode,armed in (('normal',False),('normal',True),('noack',True)):
                    server.auth_posts=0;server.mode=mode;server.calls=[];server.leaked=False
                    credentials=grant();store=NativeSessionStore(Backend());store.save(credentials,credentials['vid'],verified=True)
                    marks=[];broker=Broker(credentials,store,current=lambda:None,verify_expiry=lambda _grant:server.auth_posts==0,
                        verify_grant=lambda _grant:len(SHELF['books']),observe=lambda _grant:shelf_projection(SHELF),claim=lambda:marks.append('claimed'))
                    payload=dict(token='a'*32,armed=armed,credentials=credentials,web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},
                        expected_count=1,mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                    command=['python3',str(REPO/'scripts/run_native_shelf_renewal_ui.py'),'--koreader',str(runtime),'--candidate',str(candidate),
                        '--width',str(width),'--height',str(height),'--dpi',str(dpi)]
                    if armed:command.append('--armed')
                    report={}
                    try:
                        execute(payload,command,broker,report)
                        assert mode!='noack' and report['result']==('NATIVE_SHELF_RENEWAL_VERIFIED' if armed else 'NATIVE_SHELF_RENEWAL_DRY_VERIFIED')
                        assert server.auth_posts==int(armed) and len(marks)==int(armed)
                    except ValueError as error:
                        if mode!='noack' or str(error)!='shelf_renewal/runner':
                            print(report,server.calls,flush=True);raise
                        assert server.auth_posts==1 and marks==['claimed'] and broker.phase=='claimed'
                        try:store.load(credentials['vid'])
                        except Exception:pass
                        else:raise AssertionError('uncertain renewal was released')
                    assert not server.leaked
                    print(width,height,mode,'armed' if armed else 'dry','passed',flush=True)
    finally:server.shutdown();server.server_close()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    run(parser.parse_args().koreader)
