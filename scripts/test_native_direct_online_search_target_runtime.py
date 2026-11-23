#!/usr/bin/env python3
"""Verify online-to-native search target proof using KOReader and a mock service."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from run_persistent_ui_probe import extract_candidate
import test_native_direct_position_runtime as fixture

REPO=Path(__file__).resolve().parent.parent
CASES=('same','cached','download','denied','mismatch')


def frame(child,marker):
    if child.returncode:raise AssertionError(child.stdout[-5000:]+child.stderr[-5000:])
    lines=[line for line in child.stdout.splitlines() if line.startswith(marker)]
    assert len(lines)==1
    return json.loads(lines[0][len(marker):])


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--case',choices=CASES,action='append');args=parser.parse_args();runtime=args.koreader.resolve()
    server=ThreadingHTTPServer(('127.0.0.1',0),fixture.Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-online-native-package-',dir='/dev/shm') as package:
            candidate=Path(package)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                for case in args.case or CASES:
                    with tempfile.TemporaryDirectory(prefix='weread-online-native-',dir='/dev/shm') as root:
                        xdg=Path(root)/'xdg';xdg.mkdir(mode=0o700);(Path(root)/'settings').mkdir();(Path(root)/'plugins').mkdir()
                        extract_candidate(candidate,Path(root)/'plugins')
                        env=dict(os.environ,KO_HOME=root,XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                            SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                            EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                        credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',
                            deviceId='eink334691225'+'0'*19)
                        payload=dict(credentials=credentials,mock_endpoint='http://127.0.0.1:'+str(server.server_port),
                            mode='cross_cached' if case=='cached' else 'cross_denied' if case=='denied' else 'cross_download',case=case)
                        server.mode='cross_denied' if case=='denied' else 'match';server.calls=[];server.valid=True;server.leaked=False
                        prepare=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_prepare.lua'),str(REPO)],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=120)
                        ready=frame(prepare,'WEREAD_POSITION_PREPARED=');payload.update(path=ready['path'],second=ready.get('second'))
                        raw=fixture.BODY if case in ('same','mismatch') else fixture.BODY2
                        phrase='Unique paragraph 0100' if case in ('same','mismatch') else 'Target paragraph 0100'
                        begin=raw.index(phrase)
                        payload['hit']=dict(chapter_uid='37' if case in ('same','mismatch') else '38',start=begin,
                            finish=begin+len(phrase),text=phrase,source_verified=False)
                        server.mode='cross_denied' if case=='denied' else 'mismatch' if case=='mismatch' else 'match'
                        server.calls=[]
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_online_search_target_probe.lua')],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                        result=frame(child,'WEREAD_NATIVE_ONLINE_TARGET=')
                        assert result==dict(ok=True,case=case,verified=case not in ('denied','mismatch'),
                            downloaded=case=='download',no_cloud_write=True)
                        assert server.valid and not server.leaked
                        assert not any(path in ('/web/book/read','/book/read','/book/addBookmark','/review/add') for _,_,path in server.calls)
        print('PASS: online search targets bound to native chapters at both screen sizes')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
