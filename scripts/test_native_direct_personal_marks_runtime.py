#!/usr/bin/env python3
"""Installed KOReader direct marks: online source, offline reopen, corrupt cache."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
from urllib.parse import parse_qs,urlsplit
import sqlite3
import subprocess
import tempfile
import threading

from run_persistent_ui_probe import extract_candidate
from test_native_direct_position_runtime import BODY,Handler,REPO


class PersonalHandler(Handler):
    def dispatch(self):
        target=urlsplit(parse_qs(urlsplit(self.path).query).get('url',[''])[0])
        if self.command=='GET' and target.hostname=='i.weread.qq.com' and target.path=='/book/bookmarklist':
            server=self.server;server.calls.append((self.command,target.hostname,target.path))
            server.leaked |= any(key.lower() in ('vid','accesstoken','cookie') for key in self.headers)
            server.valid &= parse_qs(target.query)=={'bookId':['42'],'synckey':['0']}
            body=json.dumps(dict(bookId='42',updated=server.marks,chapters=[dict(chapterUid=37,title='Synthetic chapter')],hasMore=0)).encode()
            self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
        return super().dispatch()


def frame(child,marker):
    lines=[line for line in child.stdout.splitlines() if line.startswith(marker)]
    if child.returncode or len(lines)!=1:raise AssertionError((child.returncode,child.stdout[-1500:],child.stderr[-1500:]))
    return json.loads(lines[0].split('=',1)[1])


def run(runtime):
    server=ThreadingHTTPServer(('127.0.0.1',0),PersonalHandler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-direct-marks-package-',dir='/dev/shm') as package:
            candidate=Path(package)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                with tempfile.TemporaryDirectory(prefix='weread-direct-marks-ui-',dir='/dev/shm') as directory:
                    root=Path(directory);(root/'xdg').mkdir(mode=0o700);(root/'settings').mkdir();(root/'plugins').mkdir()
                    extract_candidate(candidate,root/'plugins')
                    env=dict(os.environ,KO_HOME=str(root),XDG_RUNTIME_DIR=str(root/'xdg'),LD_LIBRARY_PATH=str(runtime/'libs'),
                        SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                        EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                    credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19)
                    payload=dict(credentials=credentials,mock_endpoint='http://127.0.0.1:'+str(server.server_port),mode='selection_direct')
                    server.mode='match';server.calls=[];server.leaked=False;server.valid=True
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_prepare.lua'),str(REPO)],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                    path=frame(child,'WEREAD_POSITION_PREPARED=')['path'];assert Path(path).is_file()
                    quote='Unique paragraph 0001';first=BODY.index(quote);marker=f'{first}-{first+len(quote)}'
                    server.mode='selection_direct_overlay';server.calls=[]
                    server.mark=dict(bookmarkId='synthetic-direct-mark',chapterUid=37,type=1,range=marker,markText=quote,style=1,colorStyle=0,createTime=1700000000)
                    server.marks=[server.mark,dict(bookmarkId='synthetic-direct-point',chapterUid=37,type=0,range=str(first),markText=quote,createTime=1700000000)]
                    server.review=dict(bookId='42',userVid=12345678,reviewId='synthetic-direct-thought',chapterUid=37,
                        type=1,range=marker,abstract=quote,content='Synthetic private thought',isPrivate=1,createTime=1700000000)
                    payload['path']=path;payload['force_fallback']=True
                    def reader(offline,missing=False):
                        server.calls=[];payload.update(offline=offline,expect_missing=missing)
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_personal_marks_probe.lua')],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                        try:result=frame(child,'WEREAD_DIRECT_PERSONAL=')
                        except AssertionError as error:raise AssertionError((error,server.calls)) from error
                        assert result==dict(ok=True,offline=offline,missing=missing)
                        if offline:assert not server.calls
                        assert server.valid and not server.leaked
                    reader(False)
                    assert any(path=='/book/bookmarklist' for _,_,path in server.calls)
                    assert any(path=='/review/list' for _,_,path in server.calls)
                    assert any(path=='/book/chapterdownload' for _,_,path in server.calls)
                    reader(True)
                    dbs=list((root/'weread').glob('library-*.db'));assert len(dbs)==1
                    with sqlite3.connect(dbs[0]) as db:
                        rows=db.execute('SELECT length(body) FROM native_direct_mark_source').fetchall()
                        assert len(rows)==1 and rows[0][0]>0
                        db.execute("UPDATE native_direct_mark_source SET body='corrupted'")
                    reader(True,True)
        print('PASS: two sizes; verified search fallback, offline reopen, corrupt source rejected without network')
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    args=parser.parse_args();run(args.koreader.resolve())
