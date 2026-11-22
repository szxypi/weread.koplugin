#!/usr/bin/env python3
"""Native-only chapter, cache integrity and offline KOReader reopen."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from test_native_chapter_source_runtime import Handler

REPO=Path(__file__).resolve().parent.parent


def run(runtime):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        for width,height,dpi,switch,switch_commit,missing in ((600,800,167,False,False,False),(1264,1680,300,False,False,False),
                (600,800,167,True,False,False),(1264,1680,300,False,True,False),(1264,1680,300,False,False,True)):
            with tempfile.TemporaryDirectory(prefix='weread-native-direct-',dir='/dev/shm') as root:
                xdg=Path(root)/'xdg';xdg.mkdir(mode=0o700)
                env=dict(os.environ,KO_HOME=root,XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                    SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                    EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                payload=dict(credentials=dict(vid='12345678',accessToken='synthetic-access',
                    refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19),
                    mock_endpoint='http://127.0.0.1:'+str(server.server_port),switch=switch,switch_commit=switch_commit,missing=missing)
                server.mode,server.paths,server.leaked=('remote_invalid' if missing else 'remote'),[],False
                server.catalog_valid=server.download_valid=True
                child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_reader_probe.lua'),str(REPO)],
                    input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                if child.returncode:raise AssertionError(child.stdout+child.stderr)
                marker='WEREAD_DIRECT_RESULT='
                lines=[line for line in child.stdout.splitlines() if line.startswith(marker)]
                assert len(lines)==1
                result=json.loads(lines[0][len(marker):])
                if switch:
                    assert result==dict(ok=True,switched=True,requests=1) and server.paths==['/book/info']
                elif switch_commit:
                    assert result==dict(ok=True,switched_before_commit=True,requests=4) and len(server.paths)==4
                else:
                    assert set(result)=={'ok','requests','reused','corrupt_preserved','receipt_preserved','path','missing_images'}
                    assert result['ok'] and result['requests']==19 and result['reused'] and result['corrupt_preserved'] and result['receipt_preserved']
                    assert result['missing_images']==int(missing)
                    assert len(server.paths)==19 and set(server.paths)=={'/book/info','/book/chapterInfos','/book/chapterdownload','/image.png'}
                    path=Path(result['path']);assert path.is_file() and root in str(path)
                    offline=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_offline_probe.lua'),
                        str(REPO),str(path),'1' if missing else '0'],text=True,env=env,cwd=runtime,capture_output=True,timeout=90)
                    if offline.returncode:raise AssertionError(offline.stdout+offline.stderr)
                    offline_marker='WEREAD_DIRECT_OFFLINE='
                    lines=[line for line in offline.stdout.splitlines() if line.startswith(offline_marker)]
                    assert len(lines)==1 and json.loads(lines[0][len(offline_marker):])==dict(
                        ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,missing_images=int(missing))
                assert not server.leaked and server.catalog_valid and server.download_valid
        print('PASS: native-only chapter, isolated cache, account switch and offline reopen')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    run(parser.parse_args().koreader.resolve())
