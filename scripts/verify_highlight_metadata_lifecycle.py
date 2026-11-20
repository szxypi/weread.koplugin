#!/usr/bin/env python3
"""Capture a new two-write prototype's descriptor lifecycle, never old records.

Use only after pending experiments have been independently reconciled. The
existing two-slot prototype owns every dispatch; Python/Lua analysis after
deletion is read-only and private snapshots stay in captured pipes.
"""
import argparse
from copy import deepcopy
import json
import subprocess
from annotation_experiment_model import digest
from mark_edit_contract import make,check,rows_hash,chapters_hash
from secure_highlight_trial import HighlightTrialStore
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_highlight_trial import HighlightProbe
from verify_native_thought_trial import other_pending
from verify_translation_preflight import save_refreshed_web_session


def snapshot(value,book):
    return dict(book_id=book,marks=dict(schema=1,book_id=book,fetched_at=1,updated=list(value['marks']['updated'].values()),chapters=list(value['marks']['chapters'].values())),
        thoughts=dict(schema=1,book_id=book,fetched_at=1,reviews=list(value['thoughts'].values())))


def analyze(created,deleted,target,command):
    plan=make(created,'delete',target);yes,_key=check(deleted,plan['metadata']);uid=target['chapterUid']
    child=subprocess.run(command,input=json.dumps(dict(created=created,deleted=deleted,target=target),ensure_ascii=False).encode(),capture_output=True,timeout=60)
    frame=b'\nWEREAD_MARK_LIFECYCLE_RESULT='
    if child.returncode or child.stdout.count(frame)!=1 or len(child.stdout)>1024*1024:raise ValueError('highlight_lifecycle/lua')
    output=json.loads(child.stdout.split(frame)[1])
    if output!=dict(metadata=plan['metadata'],confirmed=yes):raise ValueError('highlight_lifecycle/different')
    return dict(python_lua_match=True,delete_contract_confirmed=yes,
        selected_descriptor_before=any(r['chapterUid']==uid for r in created['marks']['chapters']),
        selected_descriptor_after=any(r['chapterUid']==uid for r in deleted['marks']['chapters']),
        selected_chapter_empty_after=not any(r.get('chapterUid')==uid for r in deleted['marks']['updated']),
        all_other_descriptors_unchanged=chapters_hash(created['marks']['chapters'],str(uid))==chapters_hash(deleted['marks']['chapters'],str(uid)),
        exact_mark_deletion=rows_hash(created['marks']['updated'],target['bookmarkId'])==rows_hash(deleted['marks']['updated']),
        original_thoughts_unchanged=created['thoughts']['reviews']==deleted['thoughts']['reviews'])


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session and args.apply and args.lua_command:
            if other_pending():raise ValueError('highlight_lifecycle/pending')
            phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
            probe=HighlightProbe();phase='prepare';probe.prepare(saved,credentials)
            reads=[];read=probe.read
            def observed(*values,**kw):
                target,current=read(*values,**kw);reads.append(deepcopy(current));return target,current
            probe.read=observed;phase='prototype';report=probe.run(credentials,apply=True)
            save_refreshed_web_session(session,saved,probe.source.web)
            if len(reads)!=3:raise ValueError('highlight_lifecycle/reads')
            book=probe.source.plan.bound['book_id'];target=reads[0]['marks']['updated'][probe.target['id']]
            if reads[0]!=reads[1]:raise ValueError('highlight_lifecycle/changed')
            phase='read_only_analysis';report['analysis']=analyze(snapshot(reads[1],book),snapshot(reads[2],book),target,args.lua_command)
        elif args.saved_session or args.apply or args.lua_command:raise ValueError('highlight_lifecycle/offline')
    except Exception:
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=probe.posts if probe else 0,authentication_posts=0,no_automatic_replay=True)
        if args.saved_session:
            try:
                state,_r=HighlightTrialStore().read();report['intent_state']=state['phase'] if state else 'absent'
            except Exception:report['intent_state']='unverified'
    finally:
        if probe:
            for name,transport in (('native',probe.source.notes),('web',probe.source.web),('writer',probe.source.writer)):
                report[name+'_stages']=[{k:r[k] for k in ('stage','status','error_code','api_code') if k in r} for r in transport.report['stages']]
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
