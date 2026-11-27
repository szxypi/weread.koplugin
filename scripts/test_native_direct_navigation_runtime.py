#!/usr/bin/env python3
"""Verify native quick-menu chapter navigation in actual KOReader widgets."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import test_native_full_book_runtime as fixture
from run_persistent_ui_probe import extract_candidate

Handler=fixture.Handler
fixture.body=lambda uid: '<html><body>' + ''.join(
    f'<p>Chapter {uid} native marker, paragraph {index}. Synthetic reader text for pagination.</p>'
    for index in range(1,101)) + '</body></html>'

REPO=Path(__file__).resolve().parent.parent

def frame(child,marker):
    if child.returncode:raise AssertionError(child.stdout[-6000:]+child.stderr[-6000:])
    lines=[line for line in child.stdout.splitlines() if line.startswith(marker)]
    assert len(lines)==1
    return json.loads(lines[0][len(marker):])

def run(runtime, full_only=False):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-nav-package-',dir='/dev/shm') as package_dir:
            candidate=Path(package_dir)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            run_cases(runtime,server,candidate,full_only)
        print('PASS: native adjacent chapter navigation, gap protection and online download at both sizes')
    finally:
        server.shutdown();server.server_close();thread.join()

def run_cases(runtime,server,candidate,full_only=False):
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            for mode in ('two','gap','online','full','copies'):
                if full_only and mode!='full':
                    continue
                with tempfile.TemporaryDirectory(prefix='weread-native-nav-',dir='/dev/shm') as root:
                    xdg=Path(root)/'xdg';xdg.mkdir(mode=0o700)
                    env=dict(os.environ,KO_HOME=root,XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                        SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                        EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                    credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',
                                     deviceId='eink334691225'+'0'*19)
                    endpoint='http://127.0.0.1:'+str(server.server_port)
                    server.resume=server.expired=False;server.resume_marker=Path(root)/'resume';server.chapters=[]
                    server.valid=True;server.leaked=False;server.image_requests=server.tar_requests=0
                    payload=dict(credentials=credentials,mock_endpoint=endpoint,mode=mode,plugin_profile=mode=='full')
                    if mode=='full':
                        (Path(root)/'settings').mkdir();(Path(root)/'plugins').mkdir()
                        extract_candidate(candidate,Path(root)/'plugins')
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_nav_prepare.lua'),str(REPO)],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                    saved=frame(child,'WEREAD_DIRECT_NAV_PREPARED=')
                    assert '37' in saved and (('38' in saved)==(mode in ('two','full','copies'))) and (('39' in saved)==(mode=='gap'))
                    payload.update(first=saved['37'],second=saved.get('38'),missing_copy=saved.get('missing_copy'),last=saved.get('39'))
                    if mode!='online':payload.pop('credentials')
                    probe='native_direct_full_reader_probe.lua' if mode=='full' else 'native_direct_nav_probe.lua'
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader'/probe),str(REPO)],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                    if mode=='full':
                        assert frame(child,'WEREAD_DIRECT_FULL_READER=')==dict(ok=True,network_blocked=True,plugin_loaded=True,
                            roundtrip=True,native_page_restored=True,end_of_book=True,web_coordinates=False,offline_search=True,
                            search_cancel=True,same_chapter=True)
                        for stage in ('save','conflict_cancel_close','reopen_replace','save','manual_conflict','save','manual_offline','discard_cancel','different','restore','manual_restore',
                                      'manual_discard','save','discard','cleared'):
                            child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_pending_reader_probe.lua'),str(REPO)],
                                input=json.dumps(dict(payload,stage=stage)),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                            assert frame(child,'WEREAD_DIRECT_PENDING_READER=')==dict(ok=True,stage=stage,network_blocked=True)
                    else:
                        result=frame(child,'WEREAD_DIRECT_NAV_RESULT=')
                        assert result['ok'] and result['mode']==mode
                        if mode=='online':assert result['path']==saved['missing_copy'] and Path(result['path']).is_file()
                        if mode=='copies':
                            assert result['path']==saved['missing_copy']
                            payload['choose']='complete'
                            damaged=Path(saved['missing_copy'])
                            original=damaged.read_bytes()
                            child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader'/probe),str(REPO)],
                                input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                            assert frame(child,'WEREAD_DIRECT_NAV_RESULT=')['path']==saved['38']
                            assert damaged.read_bytes()==original+b'corrupt'
                    expected={'copies':['37','38','38'],'online':['37','37','38'],'gap':['37','39']}.get(mode,['37','38'])
                    assert server.chapters==expected and server.valid and not server.leaked

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--full-only',action='store_true')
    args=parser.parse_args()
    run(args.koreader.resolve(),args.full_only)
