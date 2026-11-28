#!/usr/bin/env python3
"""Installed native ReaderUI: offline selection draft and online source recheck."""
import argparse,json,os,sqlite3,subprocess,tempfile,threading
from http.server import ThreadingHTTPServer
from pathlib import Path
from run_persistent_ui_probe import extract_candidate
from test_native_direct_position_runtime import BODY,TXT,CLOUD_OFFSET,Handler,REPO,frame


def run(runtime,plain_text=False):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.plain_text=plain_text
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='direct-offline-thought-package-',dir='/dev/shm') as package:
            candidate=Path(package)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                with tempfile.TemporaryDirectory(prefix='direct-offline-thought-ui-',dir='/dev/shm') as directory:
                    root=Path(directory);(root/'xdg').mkdir(mode=0o700);(root/'settings').mkdir();(root/'plugins').mkdir()
                    extract_candidate(candidate,root/'plugins')
                    env=dict(os.environ,KO_HOME=str(root),XDG_RUNTIME_DIR=str(root/'xdg'),LD_LIBRARY_PATH=str(runtime/'libs'),
                        SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                        EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi),WEREAD_SYNTHETIC='1')
                    creds=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19)
                    payload=dict(credentials=creds,mock_endpoint='http://127.0.0.1:'+str(server.server_port),
                                 mode='match',plain_text=plain_text)
                    server.mode='match';server.calls=[];server.leaked=False;server.valid=True;server.mark=None;server.review=None
                    server.cloud_offset=CLOUD_OFFSET;server.cloud_summary='Synthetic cloud point'
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_prepare.lua'),str(REPO)],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=120)
                    payload['path']=frame(child,'WEREAD_POSITION_PREPARED=')['path']
                    source_name='native-plain-source.txt' if plain_text else 'native-source.txt'
                    native_source=Path(payload['path']).with_name(source_name)
                    native_raw=native_source.read_bytes();assert native_raw.decode()==(TXT if plain_text else BODY)
                    assert native_source.stat().st_mode & 0o077==0
                    def reader(mode,offline,link_up=False):
                        payload.update(mode=mode,offline=offline,link_up=link_up);server.mode=mode;server.calls=[]
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_reader_probe.lua')],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                        result=frame(child,'WEREAD_POSITION_READER=');assert result['ok'] and result['mode']==mode
                        if offline:assert not server.calls,'offline reader requested network'
                        assert server.valid and not server.leaked
                        return list(server.calls)
                    native_source.unlink()
                    reader('selection_direct_offline_missing',True)
                    native_source.write_bytes(native_raw)
                    reader('selection_direct_thought_offline_locked',True)
                    reader('selection_direct_thought_offline_slow_check',True)
                    reader('selection_direct_thought_offline_draft',True,link_up=True)
                    reader('selection_direct_notebook_draft',True)
                    reader('selection_direct_thought_offline_draft',True)
                    calls=reader('selection_direct',False)
                    assert any(path=='/book/chapterdownload' for _,_,path in calls)
                    reader('selection_direct_thought_offline_draft',True)
                    reader('selection_direct_thought_offline_draft',True)
                    dbs=list((root/'weread').glob('library-*.db'));assert len(dbs)==1
                    with sqlite3.connect(dbs[0]) as db:
                        raw=db.execute('SELECT body FROM native_direct_mark_source').fetchone()[0]
                        assert raw==native_raw.decode() and db.execute('SELECT count(*) FROM thought_drafts').fetchone()[0]==1
                        db.execute("UPDATE native_direct_mark_source SET body='tampered'")
                    reader('selection_direct_thought_offline_draft',True)
                    native_source.write_bytes(b'tampered')
                    reader('selection_direct_offline_missing',True)
                    reader('selection_direct_notebook_draft_missing',True)
                    with sqlite3.connect(dbs[0]) as db:
                        assert db.execute('SELECT count(*) FROM thought_drafts').fetchone()[0]==1
                        db.execute('UPDATE native_direct_mark_source SET body=?',(raw,))
                    native_source.write_bytes(native_raw)
                    calls=reader('selection_direct_thought_changed',False)
                    assert not any(path=='/review/add' for _,_,path in calls)
                    with sqlite3.connect(dbs[0]) as db:assert db.execute('SELECT count(*) FROM thought_drafts').fetchone()[0]==1
                    calls=reader('selection_direct_thought_offline_submit',False)
                    assert sum(path=='/review/add' for _,_,path in calls)==1 and server.review is not None
                    with sqlite3.connect(dbs[0]) as db:assert db.execute('SELECT count(*) FROM thought_drafts').fetchone()[0]==0
                    server.review=None
                    reader('selection_direct_thought_offline_draft',True)
                    calls=reader('selection_direct_notebook_draft_submit',False)
                    assert sum(path=='/review/add' for _,_,path in calls)==1 and server.review is not None
                print(json.dumps(dict(result='PASS',width=width,height=height,offline_requests=0,synthetic_only=True)),flush=True)
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--txt',action='store_true');args=parser.parse_args()
    run(args.koreader.resolve(),args.txt)
