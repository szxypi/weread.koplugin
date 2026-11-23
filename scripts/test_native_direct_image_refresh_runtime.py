#!/usr/bin/env python3
"""Exercise image retry in the installed ReaderUI using synthetic HTTP."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from run_persistent_ui_probe import extract_candidate
from test_native_chapter_source_runtime import Handler

REPO=Path(__file__).resolve().parent.parent


def frame(child,marker):
    if child.returncode:raise AssertionError(child.stdout[-5000:]+child.stderr[-5000:])
    lines=[line for line in child.stdout.splitlines() if line.startswith(marker)]
    assert len(lines)==1
    return json.loads(lines[0][len(marker):])


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True);args=parser.parse_args()
    runtime=args.koreader.resolve();server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-image-retry-package-',dir='/dev/shm') as package:
            candidate=Path(package)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                with tempfile.TemporaryDirectory(prefix='weread-image-retry-',dir='/dev/shm') as root:
                    profile=Path(root);(profile/'settings').mkdir();(profile/'plugins').mkdir();(profile/'xdg').mkdir(mode=0o700)
                    extract_candidate(candidate,profile/'plugins');plugin=profile/'plugins/weread.koplugin'
                    env=dict(os.environ,KO_HOME=root,XDG_RUNTIME_DIR=str(profile/'xdg'),LD_LIBRARY_PATH=str(runtime/'libs'),
                        SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                        EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),
                        WEREAD_SYNTHETIC='1',WEREAD_DIRECT_OWNER_TMPFS='1')
                    payload=dict(credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',
                        deviceId='eink334691225'+'0'*19),mock_endpoint='http://127.0.0.1:'+str(server.server_port),plugin_home=True)
                    server.mode='remote_invalid';server.paths=[];server.leaked=False;server.catalog_valid=server.download_valid=True
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_ui_probe.lua'),str(plugin)],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                    old=frame(child,'WEREAD_DIRECT_UI=')['path'];assert Path(old).is_file()
                    payload['path']=old
                    for scenario,server_mode in (('no_improvement','remote_invalid'),('rate','remote_rate')):
                        server.mode=server_mode;server.paths=[];server.leaked=False;server.catalog_valid=server.download_valid=True
                        payload['scenario']=scenario
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_image_refresh_probe.lua')],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=240)
                        checked=frame(child,'WEREAD_DIRECT_IMAGE_REFRESH=')
                        assert checked==dict(ok=True,scenario=scenario,page_unchanged=True,original_kept=True) and not server.leaked
                    payload.pop('scenario')
                    server.mode='remote';server.paths=[];server.leaked=False;server.catalog_valid=server.download_valid=True
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_image_refresh_probe.lua')],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=240)
                    result=frame(child,'WEREAD_DIRECT_IMAGE_REFRESH=');new=result['path']
                    assert result['ok'] and result['page_unchanged'] and result['original_kept'] and result['source_equal']
                    assert old!=new and Path(old).is_file() and Path(new).is_file() and not server.leaked
                    assert server.catalog_valid and server.download_valid and '/book/chapterdownload' in server.paths
                    assert not any(path in ('/book/read','/book/batchUploadProgress','/book/addBookmark','/review/add') for path in server.paths)
                    for path,missing,images in ((old,1,0),(new,0,1)):
                        offline=dict(path=path,token='integrated',uid='37',book_id='42',missing_images=missing,
                            plugin_home=True,required_images=images)
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_offline_probe.lua'),
                            str(plugin),str(REPO)],input=json.dumps(offline),text=True,env=env,cwd=runtime,capture_output=True,timeout=90)
                        expected=dict(ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,
                            missing_images=missing,warning_verified=True)
                        assert frame(child,'WEREAD_DIRECT_OWNER_OFFLINE=')==expected
        print('PASS: installed reader image retry and offline copies at both KOReader sizes')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
