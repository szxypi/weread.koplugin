#!/usr/bin/env python3
"""Synthetic local-service rehearsal of the isolated fixture ReaderUI runner."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading

from mock_weread import CHAPTERS,CB_READING_ID,MockServer,QUOTE,chapter_html,chapter_txt,prepare
from txt_coordinates import PlainSource
from verify_source_coordinates import FilteredSource


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--reverse',action='store_true')
    parser.add_argument('--timer',action='store_true')
    parser.add_argument('--close',action='store_true')
    parser.add_argument('--time',action='store_true')
    parser.add_argument('--time-noack',action='store_true')
    parser.add_argument('--cloud',action='store_true')
    parser.add_argument('--dry',action='store_true')
    parser.add_argument('--format',choices=('epub','txt'),default='epub')
    args=parser.parse_args();root=args.run_dir.resolve();runtime=args.koreader.resolve()
    if args.time_noack:args.time=True
    if sum((args.timer,args.close,args.time,args.cloud,args.dry))>1:parser.error('select one mode')
    server=MockServer(0);server.cb_reading=True;server.content_format=args.format
    source=chapter_txt(1) if args.format=='txt' else chapter_html(1)
    model=PlainSource(source) if args.format=='txt' else FilteredSource(source)
    first=model.locate('这是第1章的第16段。' + QUOTE if args.format=='txt' else '这是第1章的第16段。我们沿着小路慢慢前行')[0]
    following=first+1
    if args.reverse:first,following=following,first
    summary=model.excerpt(following)['text'] if args.format=='txt' else ''.join(c for c in model.anchor_at(following) if not c.isspace())[:20]
    server.progress[CB_READING_ID]=dict(chapterUid=1,chapterIdx=1,chapterOffset=first,progress=25,summary='synthetic old summary')
    try:
        prepare(root,runtime,server.server_port,args.width,args.height,args.dpi)
        xdg=root/'xdg';xdg.mkdir(mode=0o700);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env=dict(os.environ,KO_HOME=str(root/'profile'),XDG_RUNTIME_DIR=str(xdg),WEREAD_FIXTURE_SYNTHETIC='1',
            EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),
            EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
        payload=dict(book=CB_READING_ID,chapter='1',chapter_idx=1,first_offset=first,next_offset=following,expected_summary=summary,
                     source=source,source_format='web_txt' if args.format=='txt' else 'web_xhtml',chapters=CHAPTERS,book_version=0,owner='900000',cookies=dict(wr_vid='900000',wr_skey='synthetic-cookie-session'))
        if args.cloud:payload['cloud']=True
        if args.dry:payload['armed']=False
        if args.time_noack:payload['time_noack']=True
        if args.timer or args.close or args.time:
            timer_summary=model.excerpt(first)['text'] if args.format=='txt' else ''.join(c for c in model.anchor_at(first) if not c.isspace())[:20]
            payload.update(timer=args.timer,close=args.close,time=args.time,timer_summary=timer_summary)
        script=Path(__file__).resolve().parent.parent/'spec/koreader/cb_fixture_manual_ui.lua'
        for reopened in ((False,) if args.dry else (False,True)):
            if reopened:server.shutdown();thread.join()
            proc=subprocess.run([str(runtime/'luajit'),str(script)],cwd=runtime,env=env | {'WEREAD_FIXTURE_CB_REOPEN':'1' if reopened else '0'},
                input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=240)
            marker=b'\nWEREAD_CB_FIXTURE_MANUAL_UI='
            (root/'evidence'/('reopen.log' if reopened else 'runtime.log')).write_bytes(proc.stdout+proc.stderr)
            if proc.returncode or proc.stdout.count(marker)!=1:raise ValueError('fixture rehearsal failed')
            result=json.loads(proc.stdout.split(marker,1)[1].splitlines()[0])
            if args.dry:
                if result!=dict(result='DRY_RUN',native_choice=True,write_blocked=True,writes=0,denied=1):
                    raise ValueError('dry fixture rehearsal result')
                server.shutdown();thread.join()
                continue
            if args.cloud:
                expected=(dict(result='PASS',fresh_process=True,offline=True,pending_preserved=True,journal_cleared=True,requests=0)
                    if reopened else dict(result='PASS',cloud_choice=True,pending_preserved=True,upload_disabled=True,writes=0,denied=0))
                if result!=expected:raise ValueError('cloud fixture rehearsal result')
                continue
            if args.time_noack:
                expected=(dict(result='PASS',fresh_process=True,offline=True,journal_pending=True,requests=0) if reopened else
                          dict(result='PASS',native_choice=True,actual_source=True,upload_confirmed=True,pending_cleared=False,
                               journal_cleared=False,automatic_disabled=False,timer_verified=False,writes=3,denied=0,time_unconfirmed=True))
                if result!=expected:raise ValueError('unconfirmed time fixture rehearsal result')
                continue
            expected=(dict(result='PASS',fresh_process=True,offline=True,pending_cleared=True,journal_cleared=True,requests=0)
                if reopened else dict(result='PASS',native_choice=True,actual_source=True,upload_confirmed=True,pending_cleared=True,
                    journal_cleared=True,automatic_disabled=not (args.timer or args.close or args.time),timer_verified=args.timer,writes=3 if args.timer or args.close or args.time else 2,denied=0))
            if args.close and not reopened:expected['close_verified']=True
            if args.time and not reopened:expected['time_verified']=True
            if result!=expected:raise ValueError('fixture rehearsal result')
        if server.request_totals.get(('/web/book/read',''),0)!=(0 if args.cloud or args.dry else 3 if args.timer or args.close or args.time else 2):raise ValueError('fixture rehearsal writes')
        print('PASS: synthetic scoped fixture ReaderUI' + ('' if args.dry else ' and offline reopen'))
    finally:server.server_close()


if __name__=='__main__':main()
