#!/usr/bin/env python3
"""Exercise installed native-reader online search against loopback services."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs,urlsplit

from run_persistent_ui_probe import extract_candidate
import test_native_direct_position_runtime as fixture

REPO=Path(__file__).resolve().parent.parent
CASES=('same','cached','download','cancel','denied','mismatch','offline','fallback')


class Handler(fixture.Handler):
    def dispatch(self):
        target=urlsplit(parse_qs(urlsplit(self.path).query).get('url',[''])[0])
        if target.hostname=='weread.qq.com' and target.path=='/web/book/search_v2':
            query=parse_qs(target.query);self.server.calls.append((self.command,target.hostname,target.path))
            self.server.valid &= self.command=='GET' and query.get('bookId')==['42'] and query.get('keyword')==[self.server.keyword]
            uid=self.server.uid;raw=fixture.BODY if uid=='37' else fixture.BODY2
            first=raw.index(self.server.keyword);last=first+len(self.server.keyword)
            data=json.dumps(dict(scrollDownHasMore=0,results=[dict(chapterUid=int(uid),posBegin=first,posEnd=last,
                text=self.server.keyword,matchWords=[dict(word=self.server.keyword,posBegin=first,posEnd=last)])])).encode()
            self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
        if target.hostname=='weread.qq.com' and target.path=='/web/book/chapterInfos':
            request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            self.server.calls.append((self.command,target.hostname,target.path));self.server.valid &= request==dict(bookIds=['42'])
            rows=[dict(chapterUid=37,chapterIdx=1,title='First chapter',wordCount=500),
                  dict(chapterUid=38,chapterIdx=2,title='Second chapter',wordCount=500)]
            data=json.dumps(dict(data=[dict(bookId='42',updated=rows)])).encode()
            self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
        return super().dispatch()


def frame(child,marker):
    if child.returncode:raise AssertionError(child.stdout[-6000:]+child.stderr[-6000:])
    lines=[line for line in child.stdout.splitlines() if line.startswith(marker)];assert len(lines)==1
    return json.loads(lines[0][len(marker):])


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--case',choices=CASES,action='append');args=parser.parse_args();runtime=args.koreader.resolve()
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-online-native-ui-package-',dir='/dev/shm') as package:
            candidate=Path(package)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                for case in args.case or CASES:
                    with tempfile.TemporaryDirectory(prefix='weread-online-native-ui-',dir='/dev/shm') as root:
                        xdg=Path(root)/'xdg';xdg.mkdir(mode=0o700);(Path(root)/'settings').mkdir();(Path(root)/'plugins').mkdir()
                        extract_candidate(candidate,Path(root)/'plugins')
                        env=dict(os.environ,KO_HOME=root,XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                            SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                            EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                        credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',
                            deviceId='eink334691225'+'0'*19)
                        payload=dict(credentials=credentials,mock_endpoint='http://127.0.0.1:'+str(server.server_port),case=case,
                            mode='cross_cached' if case=='cached' else 'cross_denied' if case=='denied' else 'cross_download')
                        server.mode='cross_denied' if case=='denied' else 'match';server.calls=[];server.valid=True;server.leaked=False
                        prepare=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_prepare.lua'),str(REPO)],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=120)
                        ready=frame(prepare,'WEREAD_POSITION_PREPARED=');payload.update(path=ready['path'],second=ready.get('second'))
                        uid='37' if case in ('same','mismatch','offline') else '38'
                        keyword='Unique paragraph 0100' if uid=='37' else 'Target paragraph 0100'
                        payload.update(uid=uid,keyword=keyword);server.uid,server.keyword=uid,keyword
                        server.mode='cross_denied' if case=='denied' else 'mismatch' if case=='mismatch' else 'match';server.calls=[]
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_online_search_ui_probe.lua')],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=240)
                        result=frame(child,'WEREAD_NATIVE_ONLINE_UI=');assert result['ok'] and result['case']==case
                        if case in ('offline','fallback'):
                            assert result['offline_fallback']
                            if case=='offline':assert not server.calls
                        elif case=='cancel':assert result['cancelled']
                        elif case=='denied':assert result['denied']
                        elif case=='mismatch':assert result['blocked']
                        else:assert result['visible'] and result['cross']==(case!='same')
                        assert server.valid and not server.leaked
                        assert not any(path in ('/web/book/read','/book/read','/book/addBookmark','/review/add') for _,_,path in server.calls)
                        if case in ('cancel','denied'):
                            assert not any(path=='/book/chapterdownload' for _,_,path in server.calls)
        print('PASS: installed native-reader online search at both screen sizes')
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
