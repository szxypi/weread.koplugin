#!/usr/bin/env python3
"""Exercise new CB selection protocol against a loopback-only mock."""
import argparse
import hashlib
import json
import threading
from urllib.parse import urlsplit

from cb_fixture_selection_trial import Intent,execute,prepare
from mock_weread import CB_READING_ID,CHAPTERS
from selection_trial_mock import credentials
from test_cb_fixture_thought_runtime import Opener,Server as BaseServer
from test_secure_native_session import Backend
from verify_cb_fixture_selection_trial import ScopedSelectionNative


class Server(BaseServer):
    def __init__(self,case,associated,auto_remove):
        super().__init__(case);self.associated=associated;self.auto_remove=auto_remove
    def route(self,method,target,data):
        path=urlsplit(target).path
        result=super().route(method,target,data)
        if method=='POST' and path=='/review/add' and self.associated and self.selection_thoughts:
            self.selection_marks['synthetic-new-highlight-associated']=dict(bookmarkId='synthetic-new-highlight-associated',
                type=1,chapterUid=int(data['chapterUid']),range=data['range'],markText=data['abstract'],style=1,colorStyle=0)
        if method=='POST' and path=='/review/delete' and self.auto_remove:
            self.selection_marks.pop('synthetic-new-highlight-associated',None)
        return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case',choices=('normal','thought_create','thought_edit','thought_delete','seed_delete'),default='normal')
    parser.add_argument('--associated',action='store_true');parser.add_argument('--auto-remove',action='store_true');args=parser.parse_args()
    if args.auto_remove and not args.associated or args.case=='seed_delete' and not args.associated:parser.error('requires associated mark')
    server=Server(args.case,args.associated,args.auto_remove);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        grant=credentials();intent=Intent(Backend());native=ScopedSelectionNative(CB_READING_ID,grant,lambda:True,intent,opener=Opener(server))
        baseline=native.observe(grant);raw=server.chapter_source(2)
        sample=dict(book_id=CB_READING_ID,chapter_uid='2',chapters=CHAPTERS,source_format='web_xhtml',source=raw,
                    source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
        plan,context,body=prepare('900000',CB_READING_ID,'a'*32,sample,700,baseline,'b'*32)
        def run():return execute(plan,context,body,baseline,intent,lambda:True,lambda:native.observe(grant),
            lambda step,value,receipt:native.send_thought(step,value,receipt,grant),
            lambda value,receipt:native.send_cleanup(value,receipt,grant),sleep=lambda _n:None)
        if args.case=='normal':
            result=run();assert result['result']=='PASS' and not server.selection_marks and not server.selection_thoughts
            assert result['associated_highlight_observed']==args.associated
            assert result['cleanup_writes']==int(args.associated and not args.auto_remove) and intent.read()==(None,None)
        else:
            try:run()
            except ValueError:pass
            else:raise AssertionError('unconfirmed write accepted')
            expected={'thought_create':(1,0),'thought_edit':(2,0),'thought_delete':(3,0),'seed_delete':(3,1)}
            before=(server.selection_posts,server.highlight_posts);assert before==expected[args.case]
            state,_=intent.read();assert state['phase']=='pending'
            try:run()
            except ValueError:pass
            else:raise AssertionError('pending write replayed')
            assert (server.selection_posts,server.highlight_posts)==before
        print(json.dumps(dict(result='PASS',case=args.case,associated=args.associated,auto_removed=args.auto_remove,
                              mock_thought_posts=server.selection_posts,mock_cleanup_posts=server.highlight_posts,no_replay=True)))
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
