#!/usr/bin/env python3
"""Native selected-text lifecycle against a loopback-only CB service."""
import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
from unittest.mock import patch

from cb_fixture_selection_native_bridge import NativeSelectionBridge
from cb_fixture_selection_trial import Intent,execute,prepare
from mock_weread import CB_READING_ID,CHAPTERS
from my_mark_span import project as span_project
from selection_trial_mock import credentials
from test_cb_fixture_selection_runtime import Server
from test_cb_fixture_thought_runtime import Opener
from test_secure_native_session import Backend
from verify_cb_fixture_selection_trial import ScopedSelectionNative


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--run-dir',type=Path,required=True);parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=('normal','orchestrated','thought_create','thought_edit','thought_delete','seed_delete','host_mismatch'),default='normal')
    parser.add_argument('--associated',action='store_true');parser.add_argument('--auto-remove',action='store_true');parser.add_argument('--txt',action='store_true');args=parser.parse_args()
    if args.auto_remove and not args.associated or args.case=='seed_delete' and not args.associated:parser.error('requires associated mark')
    if args.txt and args.case=='orchestrated':parser.error('TXT uses the scoped native supervisor')
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);candidate=root/'candidate.zip'
    subprocess.run(['bash','scripts/package_release.sh',str(candidate)],check=True,capture_output=True)
    profiles=set(Path('/dev/shm').glob('weread-cb-selection-*'))
    server=Server(args.case,args.associated,args.auto_remove);txt_patch=None
    if args.txt:
        from cb_txt_highlight_trial import BODY,TEXT,prepare as prepare_txt
        from txt_coordinates import PlainSource
        server.content_format='txt';txt_patch=patch('mock_weread.chapter_txt',return_value=BODY.decode());txt_patch.start()
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        grant=credentials();intent=Intent(Backend());native=ScopedSelectionNative(CB_READING_ID,grant,lambda:True,intent,opener=Opener(server))
        baseline=native.observe(grant);raw=BODY.decode() if args.txt else server.chapter_source(2)
        sample=dict(book_id=CB_READING_ID,chapter_uid='2',chapters=CHAPTERS,source_format='web_txt' if args.txt else 'web_xhtml',source=raw,
                    source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
        options=dict(prepare_fn=lambda *v:prepare_txt(*v,range_unit='utf16')) if args.txt else {}
        plan,context,body=prepare('900000',CB_READING_ID,'a'*32,sample,700,baseline,'b'*32,**options)
        if args.txt:
            first,last=PlainSource(raw).locate(TEXT);span=dict(first=first,last=last)
        else:span=span_project(raw,CB_READING_ID,'2',dict(type=1,chapterUid=2,range=body['range'],markText=body['abstract']))
        from annotation_experiment_model import note_text
        payload=dict(book=CB_READING_ID,chapter='2',chapter_idx=2,source=raw,chapters=CHAPTERS,
            cookies={'wr_vid':'900000','wr_skey':'mock_key'},native=grant,owner='900000',book_version=700,
            body=body,edited_text=note_text('b'*32,True),first=span['first'],last=span['last'],source_format=sample['source_format'])
        os.environ.update(WEREAD_FIXTURE_SYNTHETIC='1',WEREAD_FIXTURE_MOCK_PORT=str(server.server_port))
        command=['python3','scripts/run_cb_fixture_selection_ui.py','--koreader',str(args.koreader),'--candidate',str(candidate),
                 '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
        if args.case=='orchestrated':
            from verify_cb_fixture_selection_native import run as orchestrate
            receipt=object()
            class Upload:
                imported=False
                def read(self):return (dict(phase='imported',target=CB_READING_ID,attempt='a'*32,plan={'owner':'900000'}),receipt) if self.imported else (None,None)
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
            upload=Upload()
            def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
                assert apply;upload.imported=True;assert source(CB_READING_ID)
                cleaned=cleanup_gate(upload,receipt,{},CB_READING_ID)
                if cleaned:upload.imported=False
                return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if cleaned else 'UNVERIFIED','phase':'restored' if cleaned else 'imported'}
            with patch('verify_cb_fixture_selection_native.save_refreshed_web_session',return_value=False):
                result=orchestrate(dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'}),None,NativeStore(),grant,
                    upload,intent,command,apply=True,uploader=uploader,upload_factory=lambda *_:None,source_factory=Source,
                    native_factory=lambda book,creds,authority,store:ScopedSelectionNative(book,creds,authority,store,opener=Opener(server)))
            assert result['result']=='CB_NATIVE_SELECTION_VERIFIED' and not upload.imported
            assert result['dry_run_blocked'] and result['native_ui_completed'] and result['native_thought_steps']==3
            assert server.selection_posts==3 and intent.read()==(None,None)
            print(json.dumps(dict(result='PASS',case=args.case,mock_thought_posts=3,mock_cleanup_posts=server.highlight_posts,no_replay=True)))
            return
        def read():
            value=native.observe(grant)
            if args.case=='host_mismatch' and server.selection_posts==1 and value['thoughts']:
                next(iter(value['thoughts'].values()))['content']='synthetic conflicting content'
            return value
        bridge=NativeSelectionBridge(command,payload,plan,baseline,intent,lambda:True,read)
        def run():return execute(plan,context,body,baseline,intent,lambda:True,read,bridge.send,
            lambda value,receipt:native.send_cleanup(value,receipt,grant),sleep=lambda _n:None,before_finish=bridge.finish)
        try:
            if args.case=='normal':
                result=run();assert result['result']=='PASS' and not server.selection_marks and not server.selection_thoughts
                assert bridge.dry_verified and bridge.completed and bridge.steps==3 and intent.read()==(None,None)
                assert result['associated_highlight_observed']==args.associated
                assert result['cleanup_writes']==int(args.associated and not args.auto_remove)
            else:
                try:run()
                except (ValueError,RuntimeError,TimeoutError):pass
                else:raise AssertionError('unconfirmed write accepted')
                expected={'thought_create':(1,0),'thought_edit':(2,0),'thought_delete':(3,0),
                          'seed_delete':(3,1),'host_mismatch':(1,0)}
                before=(server.selection_posts,server.highlight_posts);assert before==expected[args.case]
                state,_=intent.read();assert state['phase']=='pending'
                try:run()
                except ValueError:pass
                else:raise AssertionError('pending write replayed')
                assert (server.selection_posts,server.highlight_posts)==before
            print(json.dumps(dict(result='PASS',case=args.case,associated=args.associated,auto_removed=args.auto_remove,
                width=args.width,height=args.height,mock_thought_posts=server.selection_posts,mock_cleanup_posts=server.highlight_posts,no_replay=True)))
        finally:bridge.close()
    finally:
        server.shutdown();thread.join();server.server_close()
        if txt_patch:txt_patch.stop()
        assert set(Path('/dev/shm').glob('weread-cb-selection-*'))==profiles,'native fixture profile leaked'


if __name__=='__main__':main()
