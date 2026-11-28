#!/usr/bin/env python3
"""CB point-bookmark protocol against a loopback-only mock."""
import argparse
import hashlib
import json
import threading

from cb_fixture_bookmark_trial import Intent,execute,prepare
from mock_weread import CB_READING_ID,CHAPTERS
from selection_trial_mock import credentials
from test_cb_fixture_thought_runtime import Opener,Server
from test_secure_native_session import Backend
from verify_cb_fixture_highlight_trial import ScopedNative


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case',choices=('normal','seed_create','seed_delete'),default='normal');args=parser.parse_args()
    server=Server(args.case);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        grant=credentials();intent=Intent(Backend());native=ScopedNative(CB_READING_ID,grant,lambda:True,intent,opener=Opener(server),max_gets=80)
        baseline=native.observe(grant);raw=server.chapter_source(2)
        sample=dict(book_id=CB_READING_ID,chapter_uid='2',chapters=CHAPTERS,source_format='web_xhtml',source=raw,
                    source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
        plan,native.body=prepare('900000',CB_READING_ID,'a'*32,sample,700,baseline)
        def run():return execute(plan,native.body,baseline,intent,lambda:True,lambda:native.observe(grant),
                                 lambda phase,value,receipt:native.send(phase,value,receipt,grant))
        if args.case=='normal':
            result=run();assert result['result']=='PASS' and result['server_preview_returned'] and not server.selection_marks
            assert native.posts==2 and intent.read()==(None,None)
        else:
            try:run()
            except ValueError:pass
            else:raise AssertionError('unconfirmed write accepted')
            expected=1 if args.case=='seed_create' else 2
            assert native.posts==expected and intent.read()[0]['phase']==('create_pending' if expected==1 else 'delete_pending')
            try:run()
            except ValueError:pass
            else:raise AssertionError('pending write replayed')
            assert native.posts==expected
        print(json.dumps(dict(result='PASS',case=args.case,mock_posts=native.posts,no_replay=True)))
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
