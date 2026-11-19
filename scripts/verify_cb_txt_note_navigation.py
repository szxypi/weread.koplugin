#!/usr/bin/env python3
"""Verify a new TXT fixture's returned highlight in the native reader.

Offline by default. The real path has its own durable fixture and write
reservation; only the independently confirmed new highlight may be removed.
Source, identity and notes pass to the isolated native process via stdin.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import tempfile

import cb_txt_highlight_trial as trial
import verify_cb_txt_highlight_trial as fixture
from annotation_experiment_model import digest
from personal_upload_trial import Journal
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cb_fixture_highlight_trial import run as run_highlight
from verify_cb_note_target import native_ui
from verify_cb_txt_fixture import Receipt

SCREENS=((600,800,167),(1264,1680,300))


def stores():
    def backend(part):return MacKeychain(service='org.codex.weread.cb-txt-note-navigation-'+part+'-v1',account=ACCOUNT)
    def lock(part):
        path=Path(tempfile.gettempdir())/('codex-cb-txt-note-navigation-'+part+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload'),validator=fixture.validate_plan),
            Receipt(backend=backend('receipt')),trial.Intent(backend=backend('intent'),lock=lock('intent')))


def payload(owner,sample,body,target,current):
    if (not isinstance(sample,dict) or sample.get('source_format')!='web_txt'
            or sample.get('book_id')!=body.get('bookId') or str(body.get('chapterUid'))!=sample.get('chapter_uid')):
        raise ValueError('txt_navigation/scope')
    raw=sample.get('source');mark=current.get('marks',{}).get('updated',{}).get(target.get('id'))
    if (not isinstance(raw,str) or raw.count(trial.TEXT)!=1 or not isinstance(mark,dict)
            or digest(mark)!=target.get('sha256') or mark.get('markText')!=trial.TEXT
            or mark.get('range')!=body.get('range') or mark.get('chapterUid')!=body.get('chapterUid')):
        raise ValueError('txt_navigation/mark')
    raw_bytes=raw.encode('utf-8');sha=hashlib.sha256(raw_bytes).hexdigest()
    first=raw.index(trial.TEXT);bom=1 if raw.startswith('\ufeff') else 0
    if (sha!=sample.get('source_raw_sha256') or body['range']!=f'{first-bom}-{first-bom+len(trial.TEXT)}'
            or len(raw[:first].encode('utf-16-le'))//2==first-bom):
        raise ValueError('txt_navigation/source')
    chapters=current['marks'].get('chapters')
    if not isinstance(chapters,dict):raise ValueError('txt_navigation/chapters')
    model=dict(schema=1,book_id=body['bookId'],fetched_at=1,updated=[mark],chapters=list(chapters.values()))
    expected=dict(chapter_offset=len(raw[:first].encode('utf-16-le'))//2,raw_sha256=sha)
    return dict(book_id=body['bookId'],owner=owner,model=model,
                chapters=[dict(chapter_uid=sample['chapter_uid'],raw=raw,rows=[mark],targets=[expected],format='web_txt')])


def run(saved,session,native,grant,journal,receipt,intent,command,*,apply=False,uploader=None,ui=native_ui,
        highlight_runner=run_highlight):
    if not isinstance(command,list) or not command or any(not isinstance(x,str) or not x for x in command):
        raise ValueError('txt_navigation/command')
    captured={};observations=[]
    def prepare(owner,book,attempt,sample,version,baseline):
        result=trial.prepare(owner,book,attempt,sample,version,baseline)
        captured.update(owner=owner,sample=sample)
        return result
    def execute(plan,body,baseline,intent_arg,owned,read,send):
        def on_created(_body,target,reader):
            if _body!=body or not owned():raise ValueError('txt_navigation/ownership')
            data=payload(captured['owner'],captured['sample'],body,target,reader())
            for width,height,dpi in SCREENS:
                observations.append(ui(command,data,width,height,dpi))
        return trial.execute(plan,body,baseline,intent_arg,owned,read,send,on_created=on_created)
    def runner(*args,**kwargs):
        kwargs.update(prepare_fn=prepare,execute_fn=execute,result_label='CB_TXT_NOTE_NAVIGATION_VERIFIED')
        return highlight_runner(*args,**kwargs)
    options=dict(apply=apply,runner=runner)
    if uploader is not None:options['uploader']=uploader
    try:
        result=fixture.run(saved,session,native,grant,journal,receipt,intent,**options)
        if result.get('result')=='CB_TXT_NOTE_NAVIGATION_VERIFIED':
            if len(observations)!=len(SCREENS):raise ValueError('txt_navigation/incomplete')
            result.update(native_ui=observations,independent_server_highlight=True)
        return result
    finally:
        captured.clear()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--native-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if args.saved_session and not args.native_command:parser.error('native command required')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',annotation_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),args.native_command,apply=args.apply)
    except Exception:
        report=dict(result='UNVERIFIED',phase='setup')
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return 0 if report.get('result') in ('READ_ONLY_PREVIEW','CB_TXT_NOTE_NAVIGATION_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
