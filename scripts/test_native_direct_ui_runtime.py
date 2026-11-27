#!/usr/bin/env python3
"""Real KOReader catalog menu and worker against a synthetic native service."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import threading
from test_native_chapter_source_runtime import Handler

REPO = Path(__file__).resolve().parent.parent

def run(runtime):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        for width,height,dpi,missing in ((600,800,167,False),(1264,1680,300,True)):
            with tempfile.TemporaryDirectory(prefix='weread-native-direct-ui-',dir='/dev/shm') as root:
                xdg=Path(root)/'xdg';xdg.mkdir(mode=0o700)
                env=dict(os.environ,KO_HOME=root,XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                    SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                    EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                payload=dict(credentials=dict(vid='12345678',accessToken='synthetic-access',
                    refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19),
                    mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                server.mode,server.paths,server.leaked=('remote_invalid' if missing else 'remote'),[],False
                server.catalog_valid=server.download_valid=True
                child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_ui_probe.lua'),str(REPO)],
                    input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                if child.returncode: raise AssertionError(child.stdout+child.stderr)
                marker='WEREAD_DIRECT_UI='
                lines=[line for line in child.stdout.splitlines() if line.startswith(marker)]
                assert len(lines)==1
                result=json.loads(lines[0][len(marker):]);path=Path(result['path'])
                assert result['ok'] and path.is_file() and root in str(path)
                assert len(server.paths)==6 and not server.leaked and server.catalog_valid and server.download_valid
                entry=path.parent/'entry.txt'
                inode=path.stat().st_ino
                entry.unlink()
                retry=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_ui_probe.lua'),str(REPO)],
                    input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                if retry.returncode:raise AssertionError(retry.stdout[-5000:]+retry.stderr[-5000:])
                frames=[line for line in retry.stdout.splitlines() if line.startswith('WEREAD_DIRECT_UI=')]
                assert len(frames)==1 and json.loads(frames[0].split('=',1)[1])['path']==str(path)
                assert path.stat().st_ino==inode and entry.is_file()
                for scenario in ('normal','cached','cancel','other','switch','bad-entry','bad-receipt','damage'):
                    other_account=None
                    if scenario=='other':
                        account_dir=path.parents[2]
                        other_account=account_dir.parent/hashlib.sha256(b'native-direct-account\0' + b'87654321').hexdigest()
                        shutil.copytree(account_dir,other_account)
                    target=entry if scenario=='bad-entry' else path.parent/'receipt.txt' if scenario=='bad-receipt' else None
                    original=target.read_bytes() if target else None
                    if target:target.write_bytes(original+b'corrupt')
                    cached=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_cached_ui_probe.lua'),
                        str(REPO),scenario,str(path),'1' if missing else '0'],text=True,env=env,cwd=runtime,capture_output=True,timeout=120)
                    if cached.returncode:raise AssertionError(cached.stdout[-5000:]+cached.stderr[-5000:])
                    marker='WEREAD_DIRECT_CACHED_UI='
                    frames=[line for line in cached.stdout.splitlines() if line.startswith(marker)]
                    assert len(frames)==1 and json.loads(frames[0][len(marker):])==dict(ok=True,case=scenario,network_blocked=True)
                    if target:
                        assert target.read_bytes()==original+b'corrupt'
                        target.write_bytes(original)
                    if other_account:shutil.rmtree(other_account)
                damaged_size=path.stat().st_size
                retry=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_ui_probe.lua'),str(REPO)],
                    input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                if retry.returncode:raise AssertionError(retry.stdout[-5000:]+retry.stderr[-5000:])
                frames=[line for line in retry.stdout.splitlines() if line.startswith('WEREAD_DIRECT_UI=')]
                assert len(frames)==1
                new_path=Path(json.loads(frames[0].split('=',1)[1])['path'])
                assert new_path!=path and new_path.is_file() and path.stat().st_size==damaged_size
                cached=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_cached_ui_probe.lua'),
                    str(REPO),'copies',str(new_path),'1' if missing else '0'],text=True,env=env,cwd=runtime,capture_output=True,timeout=120)
                if cached.returncode:raise AssertionError(cached.stdout[-5000:]+cached.stderr[-5000:])
                frames=[line for line in cached.stdout.splitlines() if line.startswith('WEREAD_DIRECT_CACHED_UI=')]
                assert len(frames)==1 and json.loads(frames[0].split('=',1)[1])==dict(ok=True,case='copies',network_blocked=True)
                # Restore the deliberately corrupted synthetic file for rendering.
                with path.open('r+b') as file:
                    file.truncate(path.stat().st_size-len(b'corrupt'))
                offline=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_offline_probe.lua'),
                    str(REPO),str(path),'1' if missing else '0'],text=True,env=env,cwd=runtime,capture_output=True,timeout=90)
                if offline.returncode:raise AssertionError(offline.stdout+offline.stderr)
                marker='WEREAD_DIRECT_OFFLINE='
                lines=[line for line in offline.stdout.splitlines() if line.startswith(marker)]
                assert len(lines)==1 and json.loads(lines[0][len(marker):])==dict(
                    ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,missing_images=int(missing))
        print('PASS: native chapter menu, background preparation and offline reader at both sizes')
    finally:
        server.shutdown();server.server_close();thread.join()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    run(parser.parse_args().koreader.resolve())
