#!/usr/bin/env python3
"""Exercise the native bookmark fixture supervisor against loopback only."""
import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
from urllib.parse import urlsplit
from unittest.mock import patch

from cb_fixture_bookmark_trial import Intent,prepare
from mock_weread import CB_READING_ID,CHAPTERS,MockServer
from bookmark_point import from_mark
from selection_trial_mock import Opener,credentials
from test_secure_native_session import Backend
from verify_cb_fixture_bookmark_native import Observer,run,run_ui


class Server(MockServer):
    def __init__(self,case):
        super().__init__(0);self.cb_reading=True;self.selection_fixture=True;self.combined_upload_read=True
        self.case=case
        self.selection_marks={};self.selection_thoughts={}
        self.progress[CB_READING_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=0,progress=0,summary='')
    def chapter_source(self,uid,revision=None):
        if self.case=='short-source':
            import io,zipfile
            from synthetic_upload_epub import build
            with zipfile.ZipFile(io.BytesIO(build())) as archive:return archive.read('EPUB/chapter.xhtml').decode('utf-8')
        return super().chapter_source(uid,revision)
    def route(self,method,target,data):
        parsed=urlsplit(target)
        if parsed.hostname=='i.weread.qq.com' and method=='GET' and parsed.path=='/book/getProgress':
            from urllib.parse import parse_qs
            if parse_qs(parsed.query)!={'bookId':[CB_READING_ID]}:raise ValueError('synthetic scope')
            return 200,self.get_progress(CB_READING_ID)
        if parsed.hostname=='i.weread.qq.com' and method=='POST' and parsed.path in ('/book/addBookmark','/book/removeBookmark'):
            self.control['selection_thought_mode']='no_change' if (self.case=='no-create' and parsed.path=='/book/addBookmark'
                or self.case=='no-delete' and parsed.path=='/book/removeBookmark') else 'plain'
        return super().route(method,target,data)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',type=Path,required=True)
    p.add_argument('--run-dir',type=Path,required=True);p.add_argument('--width',type=int,default=600)
    p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    p.add_argument('--case',choices=('normal','no-create','no-delete','host-mismatch','orchestrated','short-source'),default='normal');p.add_argument('--txt',action='store_true');p.add_argument('--start',action='store_true');p.add_argument('--padded',action='store_true');p.add_argument('--cross-channel',action='store_true');p.add_argument('--web-mismatch',action='store_true');args=p.parse_args()
    if args.txt and args.case=='short-source':p.error('short-source fixture is XHTML')
    if args.start and not args.txt:p.error('start fixture is TXT')
    if args.padded and (not args.txt or args.start):p.error('padded fixture requires TXT and no start option')
    if args.cross_channel and (not args.padded or args.case!='orchestrated') or args.web_mismatch and not args.cross_channel:
        p.error('cross-channel fixture requires orchestrated padded TXT')
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);candidate=root/'candidate.zip'
    subprocess.run(['bash','scripts/package_release.sh',str(candidate)],check=True,capture_output=True)
    profiles=set(Path('/dev/shm').glob('weread-cb-bookmark-*'))
    server=Server(args.case);txt_patch=None
    if args.txt:
        if args.start:
            from cb_txt_start_bookmark_trial import BODY,TEXT,prepare as prepare_txt
        elif args.padded:
            from cb_txt_padded_bookmark_trial import BODY,TEXT,prepare as prepare_txt
        else:
            from cb_txt_bookmark_trial import BODY,TEXT,prepare as prepare_txt
        from txt_coordinates import PlainSource
        server.content_format='txt';server.selection_book_version=0
        txt_patch=patch('mock_weread.chapter_txt',return_value=BODY.decode());txt_patch.start()
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        grant=credentials();intent=Intent(Backend());observer=Observer(CB_READING_ID,grant,lambda:True,intent,opener=Opener(server))
        baseline=observer.observe(grant);raw=BODY.decode() if args.txt else server.chapter_source(2)
        sample=dict(book_id=CB_READING_ID,chapter_uid='2',chapters=CHAPTERS,source_format='web_txt' if args.txt else 'web_xhtml',source=raw,
                    source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
        version=0 if args.txt else 700
        plan,body=(prepare_txt if args.txt else prepare)('900000',CB_READING_ID,'a'*32,sample,version,baseline)
        point=dict(chapter_offset=PlainSource(raw).locate(body['markText'])[0]) if args.start else dict(chapter_offset=PlainSource(raw).locate(TEXT)[0]) if args.txt else from_mark(raw,CB_READING_ID,'2',body)
        payload=dict(book=CB_READING_ID,chapter='2',chapter_idx=2,source=raw,chapters=CHAPTERS,
            cookies={'wr_vid':'900000','wr_skey':'mock_key'},native=grant,owner='900000',book_version=version,
            body=body,first=point['chapter_offset'],source_format=sample['source_format'])
        os.environ.update(WEREAD_FIXTURE_SYNTHETIC='1',WEREAD_FIXTURE_MOCK_PORT=str(server.server_port))
        command=['python3','scripts/run_cb_fixture_bookmark_ui.py','--koreader',str(args.koreader),
                 '--candidate',str(candidate),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
        if args.case=='orchestrated':
            receipt=object()
            class Journal:
                imported=False
                def read(self):
                    return (dict(phase='imported',target=CB_READING_ID,attempt='a'*32,plan={'owner':'900000'}),receipt) if self.imported else (None,None)
            class NativeStore:
                def load(self,_owner):return grant
            class Source:
                def __init__(self):self.samples=[];self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
                def set_cookie(self,*_args):pass
                def verify_account(self):pass
                def close(self):pass
                def inspect(self,book):
                    assert book==CB_READING_ID
                    return dict(deepcopy(sample),baseline={'chapter':'0','offset':0,'percent':0})
            journal=Journal()
            def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
                assert apply;journal.imported=True;assert source(CB_READING_ID)
                cleaned=cleanup_gate(journal,receipt,{},CB_READING_ID)
                if cleaned:journal.imported=False
                return {'result':('TXT_IMPORT_AND_SOURCE_VERIFIED' if args.txt else 'EPUB_IMPORT_AND_SOURCE_VERIFIED') if cleaned else 'UNVERIFIED','phase':'restored' if cleaned else 'imported'}
            if args.txt:
                if args.start:
                    from verify_cb_txt_start_bookmark_native import point as txt_point
                elif args.padded:
                    from verify_cb_txt_padded_bookmark_native import point as txt_point
                else:
                    from verify_cb_txt_bookmark_native import point as txt_point
                options=dict(source_format='web_txt',source_marker=TEXT,prepare_fn=prepare_txt,point_fn=txt_point,
                             upload_success='TXT_IMPORT_AND_SOURCE_VERIFIED',allow_zero_version=True)
            else:options={}
            observations=[]
            if args.cross_channel:
                from verify_cb_txt_bookmark_cross_channel import observe_web
                class Web:
                    def __init__(self,_book):pass
                    def set_cookie(self,*_args):pass
                    def verify_account(self):pass
                    def close(self):pass
                    def request(self,_stage,_url):
                        rows=deepcopy(list(server.selection_marks.values()))
                        if args.web_mismatch and rows:rows[0]['range']='47'
                        return dict(updated=rows)
                def ui(*a,armed=False,**kw):
                    def created(payload,body,target):observations.append(observe_web(payload,body,target,factory=Web))
                    return run_ui(*a,armed=armed,on_created=created if armed else None,**kw)
                options['ui_runner']=ui
            with patch('verify_cb_fixture_bookmark_native.save_refreshed_web_session',return_value=False):
                result=run(dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'}),None,NativeStore(),grant,journal,intent,
                    command,apply=True,uploader=uploader,upload_factory=lambda *_:None,source_factory=Source,
                    observer_factory=lambda book,creds,authority,store:Observer(book,creds,authority,store,opener=Opener(server)),**options)
            assert result['result']=='CB_NATIVE_BOOKMARK_VERIFIED' and not journal.imported,result
            assert result['native_writes']==2 and server.bookmark_posts==2 and intent.read()==(None,None)
            if args.cross_channel:
                assert len(observations)==1 and observations[0]['stable'] and observations[0]['range_matches']==(not args.web_mismatch)
            print(json.dumps(dict(result='PASS',case=args.case,width=args.width,height=args.height,
                                  dry_blocked=True,mock_writes=2,no_replay=True)))
            return
        def read():
            value=observer.observe(grant)
            if args.case=='host-mismatch' and server.bookmark_posts==1 and value['marks']['updated']:
                next(iter(value['marks']['updated'].values()))['markText']='synthetic mismatch'
            return value
        if args.case=='short-source':
            from verify_cb_fixture_bookmark_native import TrialFailure
            try:run_ui(command,payload,plan,body,baseline,intent,lambda:True,read,armed=False)
            except TrialFailure as failure:
                assert failure.stage and failure.stage['phase']=='prepare' and failure.stage['failure_line']>0
                failure_line=failure.stage['failure_line']
            else:raise AssertionError('short source unexpectedly aligned to the requested viewport')
            assert server.bookmark_posts==0 and intent.read()==(None,None)
            print(json.dumps(dict(result='PASS',case=args.case,dry_blocked_before_write=True,no_replay=True,
                                  failure_line=failure_line)))
            return
        dry=run_ui(command,payload,plan,body,baseline,intent,lambda:True,read,armed=False)
        assert dry['result']=='DRY_RUN' and server.bookmark_posts==0
        if args.case=='normal':
            live=run_ui(command,payload,plan,body,baseline,intent,lambda:True,read,armed=True)
            assert live['result']=='PASS' and server.bookmark_posts==2 and not server.selection_marks
            assert intent.read()==(None,None)
        else:
            try:run_ui(command,payload,plan,body,baseline,intent,lambda:True,read,armed=True)
            except (ValueError,TimeoutError):pass
            else:raise AssertionError('fault was accepted')
            state,_receipt=intent.read();expected='delete_pending' if args.case=='no-delete' else 'create_pending'
            assert state and state['phase']==expected
            before=server.bookmark_posts
            try:run_ui(command,payload,plan,body,baseline,intent,lambda:True,read,armed=True)
            except ValueError:pass
            else:raise AssertionError('pending write replayed')
            assert server.bookmark_posts==before
        print(json.dumps(dict(result='PASS',case=args.case,width=args.width,height=args.height,dry_blocked=True,
                              mock_writes=server.bookmark_posts,no_replay=True)))
    finally:
        server.shutdown();thread.join();server.server_close()
        if txt_patch:txt_patch.stop()
        assert set(Path('/dev/shm').glob('weread-cb-bookmark-*'))==profiles,'native fixture profile leaked'


if __name__=='__main__':main()
