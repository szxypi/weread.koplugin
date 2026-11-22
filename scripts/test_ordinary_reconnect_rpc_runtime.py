#!/usr/bin/env python3
"""Exercise the private RPC bridge against KOReader and a loopback fixture only."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
from urllib.parse import quote
from urllib.request import ProxyHandler, Request, build_opener

from fetch_weread_epub import weread_e
from mock_weread import BOOK_ID, CHAPTERS, MockServer, chapter_html
from ordinary_reconnect_body_guard import validate_body
from ordinary_reconnect_broker import execute, preview
from ordinary_reconnect_coordinator import Coordinator
from ordinary_reconnect_restore import RestoreProbe, restore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore, PROTOCOL, HASHES
from test_secure_native_session import Backend
from verify_cb_fixture_reconnect_trial import source_summary
from verify_position_roundtrip import DEFAULT_TOKEN, same_position
from verify_reader_context import project as reader_context
from verify_reader_progress import project as reader_progress
from verify_source_coordinates import FilteredSource
from txt_full_summary import digest


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    p.add_argument('--noack',action='store_true');a=p.parse_args()
    server=MockServer(0);server.content_format='epub';server.dynamic_reader_clock=True
    source=chapter_html(1);model=FilteredSource(source)
    first=model.locate('这是第1章的第16段。我们沿着小路慢慢前行')[0]
    server.progress[BOOK_ID]=dict(chapterUid=1,chapterIdx=1,chapterOffset=first,progress=25,summary='old summary')
    if a.noack:server.control['progress_confirmation']='noack'
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        env=dict(os.environ,WEREAD_FIXTURE_SYNTHETIC='1',WEREAD_FIXTURE_MOCK_PORT=str(server.server_port),LD_LIBRARY_PATH=str(a.koreader/'libs'))
        base=[sys.executable,str(Path(__file__).with_name('run_cb_fixture_manual_ui.py')),'--koreader',str(a.koreader),
              '--candidate',str(a.candidate),'--width',str(a.width),'--height',str(a.height),'--dpi',str(a.dpi)]
        payload=dict(book=BOOK_ID,chapter='1',chapter_idx=1,first_offset=first,next_offset=first,source=source,
                     source_format='web_xhtml',chapters=CHAPTERS,book_version=7,ordinary=True,owner='900000',
                     cookies=dict(wr_vid='900000',wr_skey='synthetic-cookie-session'),armed=False,reconnect=True,reconnect_discover=True)
        child=subprocess.run(base,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,timeout=420)
        found=json.loads(child.stdout)
        if child.returncode or found.get('result')!='DISCOVERED':raise ValueError('mock/discovery')
        target=found['offset'];summary=source_summary(model,target)
        if target==first:raise ValueError('mock/target')
        payload.pop('reconnect_discover');payload.update(next_offset=target,expected_summary=summary,
                                                         ordinary_trial=dict(rpc_token=secrets.token_hex(16)))
        command=[sys.executable,str(Path(__file__).with_name('run_ordinary_reconnect_trial.py')),'--koreader',str(a.koreader),
                 '--candidate',str(a.candidate),'--width',str(a.width),'--height',str(a.height),'--dpi',str(a.dpi),
                 '--mock-port',str(server.server_port)]
        captured={};scope={}
        initial=dict(book_id=BOOK_ID,chapter_uid='1',chapter_idx=1,chapter_offset=first,raw_percent=25,summary='old summary')
        def check_context(html):
            context=reader_context(dict(book_id=BOOK_ID),html)
            if not same_position(reader_progress(dict(book=context['progress']),BOOK_ID),initial):raise ValueError('mock/context')
            fixed=context.get('pclts')
            if fixed is None or type(fixed) is str and fixed in ('','0') or type(fixed) is int and fixed==0:fixed=None
            scope.update(context=context,pclts=fixed)
            return True
        def check_body(value):
            if not isinstance(value,dict) or type(value.get('pr')) is not int or not 0<=value['pr']<=100:return False
            selected={key:'a'*64 for key in HASHES}
            selected['owner_sha256']=digest('900000')
            selected.update(protocol=PROTOCOL,baseline=initial,target=dict(initial,chapter_offset=target,raw_percent=value['pr'],summary=summary),
                            counts=dict(readingTime=0,recordReadingTime=0,ttsTime=0),version=7)
            context=scope['context']
            validate_body(selected,context,scope['pclts'],'enter',value)
            captured.update(plan=selected,context=context,pclts=scope['pclts'])
            return True
        dry={};preview(command+['--dry'],payload,check_body,dry,check_context=check_context)
        if dry.get('result')!='READER_POSITION_DRY_VERIFIED' or server.request_totals.get(('/web/book/read',''),0)!=0:
            raise ValueError('mock/dry')
        store=OrdinaryReconnectStore(Backend());store.reserve(captured['plan'])
        def same(expected):
            item=server.get_progress(BOOK_ID)['book']
            return item['chapterOffset']==expected['chapter_offset'] and item['summary']==expected['summary'] and item['progress']==expected['raw_percent']
        def before(stage,selected):return same(selected['baseline' if stage=='enter' else 'target'])
        def after(stage,selected):return same(selected['baseline' if stage=='restore' else 'target'])
        gate=Coordinator(store,captured['plan'],captured['context'],captured['pclts'],before,after,armed=True)
        payload.update(armed=True,ordinary_trial=dict(rpc_token=secrets.token_hex(16)));report={}
        def bind_context(html):
            check_context(html)
            return dict(context=scope['context'],pclts=scope['pclts'])
        try:execute(command,payload,gate,report,check_context=bind_context)
        except Exception:
            if not a.noack:raise
        if a.noack:
            if (report.get('result')!='UNVERIFIED' or report['claimed_posts']!=2 or report['acknowledged_posts']!=1
                    or store.read()[0]['phase']!='position_pending' or gate.phase!='stopped'):raise ValueError('mock/noack')
        elif report.get('result')!='READER_POSITION_VERIFIED_RESTORE_PENDING' or store.read()[0]['phase']!='position_verified':
            raise ValueError('mock/reader')
        if server.request_totals.get(('/web/book/read',''),0)!=2:raise ValueError('mock/post_count')
        restored=False
        if not a.noack:
            class LocalOpener:
                def __init__(self):self.opener=build_opener(ProxyHandler({}))
                def open(self,request,timeout):
                    url='http://127.0.0.1:'+str(server.server_port)+'/__proxy?url='+quote(request.full_url,safe='')
                    mapped=Request(url,data=request.data,headers=dict(request.header_items()),method=request.get_method())
                    return self.opener.open(mapped,timeout=timeout)
            web=RestoreProbe(opener=LocalOpener());web.vid='900000';web.book_id=BOOK_ID;web.authenticated=True
            for key,value in payload['cookies'].items():web.set_cookie(key,value)
            restored_report={}
            try:restore(web,gate,lambda:True,restored_report)
            finally:web.close()
            if (restored_report.get('result')!='ORDINARY_RESTORATION_VERIFIED' or store.read()[0]['phase']!='retired'
                    or not same(initial) or server.request_totals.get(('/web/book/read',''),0)!=3):
                raise ValueError('mock/restore')
            restored=True
        print(json.dumps(dict(result='PASS',mock_only=True,noack=a.noack,dry_body_bound=True,dry_posts=0,
                              claimed_posts=report['claimed_posts'],acknowledged_posts=report['acknowledged_posts'],
                              verified=report['independently_verified'],coordinator=True,actual_reader=True,
                              restore_verified=restored,real_account_posts=0)))
    finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':main()
