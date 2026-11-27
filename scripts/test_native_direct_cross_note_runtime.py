#!/usr/bin/env python3
"""Exercise cross-chapter personal notes in an installed synthetic KOReader."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading

from run_persistent_ui_probe import extract_candidate
from annotation_source_quotes import SourceQuotes
from test_native_direct_personal_marks_runtime import PersonalHandler
from test_native_direct_position_runtime import BODY2, TXT2, REPO, txt_offset
import test_native_direct_position_runtime as fixture


def frame(child, marker):
    lines = [line for line in child.stdout.splitlines() if line.startswith(marker)]
    if child.returncode or len(lines) != 1:
        raise AssertionError((child.returncode, child.stdout[-3000:], child.stderr[-3000:]))
    return json.loads(lines[0][len(marker):])


def run(runtime, only_cancel=False, plain_text=False):
    server = ThreadingHTTPServer(('127.0.0.1', 0), PersonalHandler)
    server.plain_text = plain_text
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-cross-note-package-', dir='/dev/shm') as package:
            candidate = Path(package) / 'candidate.zip'
            subprocess.run(['bash', str(REPO/'scripts/package_release.sh'), str(candidate)], cwd=REPO, check=True, capture_output=True)
            for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
                with tempfile.TemporaryDirectory(prefix='weread-cross-note-', dir='/dev/shm') as directory:
                    root = Path(directory); (root/'xdg').mkdir(mode=0o700); (root/'settings').mkdir(); (root/'plugins').mkdir()
                    extract_candidate(candidate, root/'plugins')
                    env = dict(os.environ, KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'), LD_LIBRARY_PATH=str(runtime/'libs'),
                        SDL_VIDEODRIVER='dummy', EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                        EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi), WEREAD_SYNTHETIC='1')
                    credentials = dict(vid='12345678', accessToken='synthetic-access', refreshToken='synthetic-refresh',
                        deviceId='eink334691225'+'0'*19)
                    payload = dict(credentials=credentials, mock_endpoint='http://127.0.0.1:'+str(server.server_port), mode='cross_download')
                    server.mode='match'; server.calls=[]; server.valid=True; server.leaked=False
                    child = subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_position_prepare.lua'),str(REPO)],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                    payload['path'] = frame(child,'WEREAD_POSITION_PREPARED=')['path']
                    quote='Target paragraph 0100'
                    first=txt_offset(TXT2.removeprefix('\ufeff'),quote) if plain_text else BODY2.index(quote)
                    last=first+len(quote)
                    if not plain_text:assert SourceQuotes(BODY2,body_only=True).quote(f'{first}-{last}')==quote
                    server.marks=[dict(bookmarkId='cross-mark',chapterUid=38,type=1,range=f'{first}-{last}',markText=quote,
                                       style=1,colorStyle=0,createTime=1700000000),
                                  dict(bookmarkId='cross-bookmark',chapterUid=38,type=0,range=str(first),markText=quote,createTime=1700000000)]
                    server.review=dict(bookId='42',userVid=12345678,reviewId='cross-thought',chapterUid=38,type=1,
                        range=f'{first}-{last}',abstract=quote,content='Synthetic private thought',isPrivate=1,createTime=1700000000)
                    server.mode='selection_direct_overlay'
                    for offline in ((False,) if only_cancel else (False, True)):
                        for kind in (('mark',) if only_cancel else ('mark','thought','bookmark')):
                            payload.update(offline=offline,kind=kind);server.calls=[]
                            child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_cross_note_probe.lua')],
                                input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                            try: result=frame(child,'WEREAD_CROSS_NOTE=')
                            except AssertionError as error: raise AssertionError((error,server.calls)) from error
                            assert result==dict(ok=True,offline=offline,kind=kind)
                            assert server.valid and not server.leaked
                            if not offline and kind=='mark':
                                assert any(path=='/book/chapterdownload' for _,_,path in server.calls)
                            if offline: assert not server.calls
                    for mode in ('callback','gesture'):
                        payload.update(offline=False,kind='mark',expect_cancel=True,cancel_mode=mode);server.calls=[]
                        child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_cross_note_probe.lua')],
                            input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                        assert frame(child,'WEREAD_CROSS_NOTE=')==dict(ok=True,offline=False,kind='mark',cancelled=True)
                    payload.pop('expect_cancel');payload.pop('cancel_mode')
                    if only_cancel: continue
                    databases=list((root/'weread').glob('library-*.db'));assert len(databases)==1
                    if plain_text:
                        sources=list((root/'weread').rglob('native-plain-source.txt'));assert len(sources)>=2
                        for source in sources:source.write_bytes(b'corrupted')
                    else:
                        with sqlite3.connect(databases[0]) as db:
                            assert db.execute('SELECT count(*) FROM native_direct_mark_source').fetchone()[0]>=1
                            db.execute("UPDATE native_direct_mark_source SET body='corrupted'")
                    payload.update(offline=True,kind='mark',expect_failure=True);server.calls=[]
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_cross_note_probe.lua')],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                    assert frame(child,'WEREAD_CROSS_NOTE=')==dict(ok=True,offline=True,kind='mark',failed_safely=True)
                    assert not server.calls
                    # Retain two different copies under the same catalog, then
                    # exercise the actual offline refusal and online recovery.
                    if plain_text:fixture.TXT2=TXT2+'\r\nEarlier cached edition.'
                    else:fixture.BODY2=BODY2.replace('</body>','<p>Earlier cached edition.</p></body>')
                    server.mode='match';server.calls=[]
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_conflict_prepare.lua'),str(REPO)],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=150)
                    conflict=Path(frame(child,'WEREAD_CONFLICT_PREPARED=')['path']);assert conflict.is_file()
                    fixture.BODY2=BODY2;fixture.TXT2=TXT2;server.mode='selection_direct_overlay'
                    payload.update(offline=True,kind='mark',expect_failure=True);server.calls=[]
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_cross_note_probe.lua')],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                    assert frame(child,'WEREAD_CROSS_NOTE=')==dict(ok=True,offline=True,kind='mark',failed_safely=True)
                    assert not server.calls and conflict.is_file()
                    payload.update(offline=False,expect_failure=False);server.calls=[]
                    child=subprocess.run([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_cross_note_probe.lua')],
                        input=json.dumps(payload),text=True,env=env,cwd=runtime,capture_output=True,timeout=180)
                    assert frame(child,'WEREAD_CROSS_NOTE=')==dict(ok=True,offline=False,kind='mark')
                    assert any(path=='/book/chapterdownload' for _,_,path in server.calls) and conflict.is_file()
        print('PASS: cross-chapter cancellation at two sizes' if only_cancel else
              'PASS: cross-chapter marks, thoughts and bookmarks, online and offline at two sizes')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--only-cancel',action='store_true');parser.add_argument('--txt',action='store_true')
    args=parser.parse_args();run(args.koreader.resolve(),args.only_cancel,args.txt)
