#!/usr/bin/env python3
"""Ordinary XHTML offline page turn and guarded native reconnect on a synthetic service."""
import argparse
from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

from mock_weread import CHAPTERS,BOOK_ID,MockServer,chapter_html
from verify_source_coordinates import FilteredSource


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    wake=parser.add_mutually_exclusive_group();wake.add_argument('--wake',action='store_true');wake.add_argument('--wake-retry',action='store_true');parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();server=MockServer(0);server.content_format='epub'
    source=chapter_html(1);model=FilteredSource(source)
    first=model.locate('这是第1章的第16段。我们沿着小路慢慢前行')[0]
    server.progress[BOOK_ID]=dict(chapterUid=1,chapterIdx=1,chapterOffset=first,progress=25,summary='synthetic old summary')
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        env=dict(os.environ,WEREAD_FIXTURE_SYNTHETIC='1',WEREAD_FIXTURE_MOCK_PORT=str(server.server_port))
        command=[sys.executable,str(Path(__file__).with_name('run_cb_fixture_manual_ui.py')),'--koreader',str(args.koreader),
                 '--candidate',str(args.candidate),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
        payload=dict(book=BOOK_ID,chapter='1',chapter_idx=1,first_offset=first,next_offset=first,
                     source=source,source_format='web_xhtml',chapters=CHAPTERS,book_version=7, ordinary=True,
                     owner='900000',cookies=dict(wr_vid='900000',wr_skey='synthetic-cookie-session'),
                     armed=False,reconnect=True,reconnect_discover=True)
        unsafe_env=dict(os.environ);unsafe_env.pop('WEREAD_FIXTURE_SYNTHETIC',None);unsafe_env.pop('WEREAD_FIXTURE_MOCK_PORT',None)
        unsafe=dict(payload,armed=True);unsafe.pop('reconnect_discover')
        blocked=subprocess.run(command,input=json.dumps(unsafe).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                               env=unsafe_env,timeout=30)
        denied=json.loads(blocked.stdout)
        assert blocked.returncode and denied['result']=='UNVERIFIED' and not denied['profile_removed'], \
            'ordinary real-write request was not rejected before startup'
        injected_env=dict(unsafe_env,WEREAD_ORDINARY_RECONNECT_RPC='1')
        injected=dict(unsafe,ordinary_trial=dict(rpc_token='a'*32))
        blocked=subprocess.run(command,input=json.dumps(injected).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                               env=injected_env,timeout=30)
        denied=json.loads(blocked.stdout)
        assert blocked.returncode and denied['result']=='UNVERIFIED' and not denied['profile_removed'], \
            'ordinary RPC environment bypassed the legacy runner'
        if args.wake:payload['wake_reconnect']=True
        if args.wake_retry:payload['wake_retry']=True
        def runner(value):
            proc=subprocess.run(command,input=json.dumps(value,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                                env=env,timeout=420)
            try:result=json.loads(proc.stdout)
            except ValueError:raise ValueError('runtime/malformed') from None
            if proc.returncode:raise ValueError('runtime/failed '+json.dumps(result))
            return result
        found=runner(payload)
        assert found['result']=='DISCOVERED' and found['writes']==0 and found['offline_intent']
        target=found['offset'];assert target!=first
        expected=''.join(c for c in model.anchor_at(target,size=96) if not c.isspace())[:20];assert expected
        payload.pop('reconnect_discover');payload.update(next_offset=target,expected_summary=expected)
        dry=runner(payload);assert dry['result']=='DRY_RUN' and dry['writes']==0 and dry['offline_intent'] and dry['reconnect_choice']
        assert server.request_totals.get(('/web/book/read',''),0)==0
        payload['armed']=True;completed=runner(payload)
        assert completed['result']=='PASS' and completed['writes']==2 and completed['offline_intent'] and completed['reconnect_choice']
        if args.wake:assert completed['wake_choice'] and dry['wake_choice'] and completed['sleep_disconnect_preserved'] and dry['sleep_disconnect_preserved']
        if args.wake_retry:assert completed['wake_retry'] and dry['wake_retry']
        assert server.request_totals.get(('/web/book/read',''),0)==2
        actual=server.get_progress(BOOK_ID)['book']
        assert actual['chapterOffset']==target and actual['summary']==expected
        print(json.dumps(dict(result='PASS',fixture_only=True,offline_page_move=True,reconnect_choice=True,dry_run_writes=0,
                              synthetic_data_posts=2,independent_offset_readback=True,fresh_offline_process=True,
                              real_account_data_posts=0,real_write_mode_rejected=True,profile_removed=True,
                              wake_reconnect=args.wake,wake_retry=args.wake_retry,sleep_disconnect_preserved=args.wake)))
    finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':main()
