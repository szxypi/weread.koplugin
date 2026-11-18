#!/usr/bin/env python3
"""Synthetic local-service rehearsal of the isolated fixture ReaderUI runner."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading

from mock_weread import CHAPTERS,CB_READING_ID,MockServer,chapter_html,prepare
from verify_source_coordinates import FilteredSource


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--reverse',action='store_true')
    args=parser.parse_args();root=args.run_dir.resolve();runtime=args.koreader.resolve()
    server=MockServer(0);server.cb_reading=True
    source=chapter_html(1);model=FilteredSource(source);first=model.locate('这是第1章的第16段。我们沿着小路慢慢前行')[0]
    following=first+1
    if args.reverse:first,following=following,first
    summary=''.join(c for c in model.anchor_at(following) if not c.isspace())[:20]
    server.progress[CB_READING_ID]=dict(chapterUid=1,chapterIdx=1,chapterOffset=first,progress=25,summary='synthetic old summary')
    try:
        prepare(root,runtime,server.server_port,args.width,args.height,args.dpi)
        xdg=root/'xdg';xdg.mkdir(mode=0o700);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env=dict(os.environ,KO_HOME=str(root/'profile'),XDG_RUNTIME_DIR=str(xdg),WEREAD_FIXTURE_SYNTHETIC='1',
            EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),
            EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
        payload=dict(book=CB_READING_ID,chapter='1',chapter_idx=1,first_offset=first,next_offset=following,expected_summary=summary,
                     source=source,chapters=CHAPTERS,book_version=0,owner='900000',cookies=dict(wr_vid='900000',wr_skey='synthetic-cookie-session'))
        script=Path(__file__).resolve().parent.parent/'spec/koreader/cb_fixture_manual_ui.lua'
        for reopened in (False,True):
            if reopened:server.shutdown();thread.join()
            proc=subprocess.run([str(runtime/'luajit'),str(script)],cwd=runtime,env=env | {'WEREAD_FIXTURE_CB_REOPEN':'1' if reopened else '0'},
                input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=240)
            marker=b'\nWEREAD_CB_FIXTURE_MANUAL_UI='
            (root/'evidence'/('reopen.log' if reopened else 'runtime.log')).write_bytes(proc.stdout+proc.stderr)
            if proc.returncode or proc.stdout.count(marker)!=1:raise ValueError('fixture rehearsal failed')
            result=json.loads(proc.stdout.split(marker,1)[1].splitlines()[0])
            expected=(dict(result='PASS',fresh_process=True,offline=True,pending_cleared=True,journal_cleared=True,requests=0)
                if reopened else dict(result='PASS',native_choice=True,actual_source=True,upload_confirmed=True,pending_cleared=True,
                    journal_cleared=True,automatic_disabled=True,writes=2,denied=0))
            if result!=expected:raise ValueError('fixture rehearsal result')
        if server.request_totals[('/web/book/read','')]!=2:raise ValueError('fixture rehearsal writes')
        print('PASS: synthetic scoped fixture ReaderUI and offline reopen')
    finally:server.server_close()


if __name__=='__main__':main()
