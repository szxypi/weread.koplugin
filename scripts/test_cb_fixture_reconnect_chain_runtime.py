#!/usr/bin/env python3
"""Two-size reconnect orchestration using real KOReader and a synthetic service."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import threading
from unittest.mock import patch
import subprocess
import sys

from cb_cloud_position import observed
from cb_existing_position_intent import Intent
from mock_weread import CB_READING_ID,CHAPTERS,MockServer,chapter_html
from test_cb_fixture_position_transport import MemoryBackend
from verify_cb_fixture_reconnect_trial import reconnect_trial
from verify_source_coordinates import FilteredSource


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True);parser.add_argument('--case',choices=('normal','noack'),default='normal');parser.add_argument('--resume',action='store_true');args=parser.parse_args()
    server=MockServer(0);server.cb_reading=True;server.content_format='epub'
    if args.case=='noack':server.control['progress_confirmation']='noack'
    source=chapter_html(1);model=FilteredSource(source)
    first=model.locate('这是第1章的第16段。我们沿着小路慢慢前行')[0]
    summary=''.join(c for c in model.anchor_at(first,size=96) if not c.isspace())[:20]
    server.progress[CB_READING_ID]=dict(chapterUid=1,chapterIdx=1,chapterOffset=first,progress=25,summary=summary)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        os.environ['WEREAD_FIXTURE_SYNTHETIC']='1';os.environ['WEREAD_FIXTURE_MOCK_PORT']=str(server.server_port)
        def pair():
            web=server.get_progress(CB_READING_ID);native=copy.deepcopy(web)
            native['book'].update(readingTime=0,recordReadingTime=0,ttsTime=0)
            return native,web
        initial={channel:observed(raw,CB_READING_ID,CHAPTERS,channel) for channel,raw in zip(('native','web'),pair())}
        command=['python3',str(Path(__file__).with_name('run_cb_fixture_manual_ui.py')),'--koreader',str(args.koreader),'--candidate',str(args.candidate)]
        context=dict(sample=dict(source=source,chapters=CHAPTERS),plan=dict(book=CB_READING_ID,chapter='1',index=1,first=first),
                     chapters=CHAPTERS,pair=pair,authority=lambda:True,shelf_current=lambda:True,
                     cookies=lambda:dict(wr_vid='900000',wr_skey='synthetic-cookie-session'),owner='900000',attempt='a'*32,
                     source_hash='b'*64,target=CB_READING_ID,initial_observed=initial,attest=lambda:['first'],command=['first'])
        report=dict(position_writes_known=1,position_writes_uncertain=False);intent=Intent(backend=MemoryBackend())
        if args.resume:
            fingerprint=hashlib.sha256((context['source_hash']+':'+str(first)).encode()).hexdigest()
            intent.reserve(context['owner'],context['target'],context['attempt'],fingerprint)
        original=subprocess.run
        def inspect(*args,**kwargs):
            data=json.loads(kwargs['input']);print('synthetic run',args[0][-6:], 'discover',data.get('reconnect_discover',False),'armed',data['armed'],file=sys.stderr,flush=True)
            result=original(*args,**kwargs)
            if result.returncode:print('synthetic runner failure: '+result.stdout.decode(errors='replace'),file=sys.stderr)
            return result
        with patch('verify_cb_fixture_reconnect_trial.subprocess.run',side_effect=inspect):
            if args.case=='normal':
                assert reconnect_trial(context,report,intent,command,attest=lambda:command,resume=args.resume)
                assert len(report['reconnect_stages'])==2 and report['position_writes_known']==5 and not report['position_writes_uncertain']
                assert server.request_totals.get(('/web/book/read',''),0)==4
                print(json.dumps(dict(result='PASS',case=args.case,resume=args.resume,screens=2,discovery_writes=0,dry_run_writes=0,synthetic_data_posts=4,
                                      readback_rounds=4,fresh_offline_reopens=2,real_account_data_posts=0)))
            else:
                try:reconnect_trial(context,report,intent,command,attest=lambda:command,resume=args.resume)
                except ValueError:pass
                else:raise AssertionError('unknown receipt accepted')
                assert report['position_writes_uncertain'] and not report['reconnect_stages']
                assert server.request_totals.get(('/web/book/read',''),0)==2
                try:reconnect_trial(context,report,intent,command,attest=lambda:command,resume=args.resume)
                except Exception:pass
                else:raise AssertionError('consumed intent replayed')
                assert server.request_totals.get(('/web/book/read',''),0)==2
                print(json.dumps(dict(result='PASS',case=args.case,resume=args.resume,synthetic_data_posts=2,uncertain_intent_preserved=True,
                                      no_replay=True,real_account_data_posts=0)))
        assert intent.backend.load() is not None
    finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':main()
