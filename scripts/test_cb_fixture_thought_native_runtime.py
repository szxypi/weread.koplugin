#!/usr/bin/env python3
"""Exercise the CB native thought supervisor against loopback only."""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import subprocess
import threading

from cb_fixture_highlight_trial import Intent,prepare
from cb_fixture_thought_native_bridge import NativeThoughtBridge
from cb_fixture_thought_trial import ThoughtIntent,execute
from mock_weread import CB_READING_ID,CHAPTERS
from selection_trial_mock import credentials
from test_cb_fixture_thought_runtime import Opener,Server
from test_secure_native_session import Backend
from verify_cb_fixture_highlight_trial import ScopedNative


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=('normal','orchestrated','seed_create','thought_create','thought_edit','thought_delete','seed_delete','host_mismatch'),default='normal')
    args=parser.parse_args();root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);candidate=root/'candidate.zip'
    subprocess.run(['bash','scripts/package_release.sh',str(candidate)],check=True,capture_output=True)
    profiles=set(Path('/dev/shm').glob('weread-native-thought-*'))
    server=Server(args.case);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        grant=credentials();seed=Intent(Backend());thought=ThoughtIntent(Backend())
        native=ScopedNative(CB_READING_ID,grant,lambda:True,seed,opener=Opener(server),max_gets=80)
        baseline=native.observe(grant);raw=server.chapter_source(2)
        sample=dict(book_id=CB_READING_ID,chapter_uid='2',chapters=CHAPTERS,source_format='web_xhtml',source=raw,
                    source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
        _plan,native.body=prepare('900000',CB_READING_ID,'a'*32,sample,700,baseline)
        command=['python3','scripts/run_native_thought_trial.py','--koreader',str(args.koreader),
                 '--candidate',str(candidate),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),
                 '--mock-port',str(server.server_port)]
        if args.case=='orchestrated':
            from unittest.mock import patch
            from verify_cb_fixture_thought_native import run as orchestrate
            receipt=object()
            class Upload:
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
            upload=Upload()
            def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
                assert apply;upload.imported=True;assert source(CB_READING_ID)
                cleaned=cleanup_gate(upload,receipt,{},CB_READING_ID)
                if cleaned:upload.imported=False
                return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if cleaned else 'UNVERIFIED','phase':'restored' if cleaned else 'imported'}
            with patch('verify_cb_fixture_thought_native.save_refreshed_web_session',return_value=False):
                result=orchestrate(dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'}),None,NativeStore(),grant,
                    upload,seed,thought,command,apply=True,uploader=uploader,upload_factory=lambda *_:None,source_factory=Source,
                    native_factory=lambda book,creds,authority,intent,**kwargs:ScopedNative(book,creds,authority,intent,opener=Opener(server),**kwargs),
                    mock_port=server.server_port)
            assert result['result']=='CB_NATIVE_THOUGHT_VERIFIED' and not upload.imported
            assert result['dry_run_blocked'] and result['native_ui_completed'] and result['native_thought_steps']==3
            assert server.highlight_posts==2 and server.selection_posts==3 and seed.read()==thought.read()==(None,None)
            print(json.dumps(dict(result='PASS',case=args.case,mock_highlight_posts=2,mock_thought_posts=3,no_replay=True)))
            return
        def read():
            value=native.observe(grant)
            if args.case=='host_mismatch' and server.selection_posts==1 and value['thoughts']:
                next(iter(value['thoughts'].values()))['content']='synthetic conflicting content'
            return value
        bridge=NativeThoughtBridge(command,'900000',CB_READING_ID,grant,seed,thought,lambda:True,read,mock_port=server.server_port)
        def seed_send(phase,body,permit):
            if phase=='delete_pending':bridge.finish()
            native.send(phase,body,permit,grant)
        def run():return execute('900000',CB_READING_ID,'a'*32,sample,700,baseline,seed,thought,lambda:True,
                read,seed_send,bridge.send,nonce='b'*32,sleep=lambda _n:None)
        try:
            if args.case=='normal':
                result=run();assert result['result']=='PASS' and not server.selection_marks and not server.selection_thoughts
                assert bridge.dry_verified and bridge.completed and bridge.posts==3 and native.posts==2
                assert seed.read()==thought.read()==(None,None)
            else:
                try:run()
                except (ValueError,RuntimeError,TimeoutError):pass
                else:raise AssertionError('unconfirmed change accepted')
                before=(server.highlight_posts,server.selection_posts)
                expected={'seed_create':(1,0),'thought_create':(1,1),'thought_edit':(1,2),
                          'thought_delete':(1,3),'seed_delete':(2,3),'host_mismatch':(1,1)}
                assert before==expected[args.case], 'failure was not exercised at its intended write'
                if args.case.startswith('thought_') or args.case=='host_mismatch':
                    expected_phase={'thought_create':'create_pending','thought_edit':'edit_pending',
                                    'thought_delete':'delete_pending','host_mismatch':'create_pending'}
                    assert thought.read()[0]['phase']==expected_phase[args.case]
                else:assert seed.read()[0]['phase']==('create_pending' if args.case=='seed_create' else 'delete_pending')
                try:run()
                except ValueError:pass
                else:raise AssertionError('pending write replayed')
                assert (server.highlight_posts,server.selection_posts)==before and (seed.read()[0] or thought.read()[0])
            print(json.dumps(dict(result='PASS',case=args.case,width=args.width,height=args.height,
                mock_highlight_posts=server.highlight_posts,mock_thought_posts=server.selection_posts,no_replay=True)))
        finally:bridge.close()
    finally:
        server.shutdown();thread.join();server.server_close()
        assert set(Path('/dev/shm').glob('weread-native-thought-*'))==profiles,'native fixture profile leaked'


if __name__=='__main__':main()
