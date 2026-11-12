#!/usr/bin/env python3
"""Read-only bookmark point and Python/Lua plans from verified actual source.

No reservations, POST transport or native UI submission. Real source/records
are confined to captured pipes; output contains fixed status facets only.
"""
import argparse
from copy import deepcopy
import json
import subprocess
from bookmark_point import project,from_mark
from bookmark_reference import reference
from mark_edit_contract import make
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_bookmark_trial import BookmarkProbe
from verify_owner_reading import reading_position
from verify_web_source_progress import BASE
from verify_translation_preflight import save_refreshed_web_session


def models(probe):
    p=probe.source.plan;old=p.baseline;book=p.bound['book_id'];uid=p.bound['chapter_uid']
    snapshot=dict(book_id=book,marks=dict(schema=1,book_id=book,fetched_at=1,updated=list(old['marks']['updated'].values()),chapters=list(old['marks']['chapters'].values())),
        thoughts=dict(schema=1,book_id=book,fetched_at=1,reviews=list(old['thoughts'].values())))
    point=project(probe.raw,probe.first);ref=reference(book,uid,probe.source.payload['selection_preview']['reference']['chapterIdx'],point)
    metadata=dict(bookId=book,bookVersion=p.context['bookVersion']);creation=make(snapshot,'bookmark_create',ref,metadata)
    if creation['body']!=probe.body:raise ValueError('bookmark_contract/body')
    target={k:v for k,v in probe.body.items() if k not in ('bookId','bookVersion')};target['bookmarkId']='synthetic-contract-new-bookmark'
    added=deepcopy(snapshot);added['marks']['updated'].append(target)
    plans=[creation,make(added,'bookmark_delete',target)]
    position=from_mark(probe.raw,book,uid,target)
    payload=dict(snapshot=snapshot,deletion_snapshot=added,reference=ref,target=target,metadata=metadata,raw=probe.raw,co=probe.first)
    return payload,dict(point=point,target=position,plans=plans)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=None;saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);probe=BookmarkProbe()
            phase='prepare';probe.prepare(saved,credentials)
            phase='models';payload,expected=models(probe)
            if args.lua_command:
                phase='lua';child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=60)
                frame=b'\nWEREAD_BOOKMARK_CONTRACT_RESULT='
                if child.returncode or len(child.stdout)>4*1024*1024 or child.stdout.count(frame)!=1:raise ValueError('bookmark_contract/lua')
                phase='compare'
                if json.loads(child.stdout.split(frame)[1])!=expected:raise ValueError('bookmark_contract/different')
                report['python_lua_match']=True
            phase='final';probe.source.baseline(credentials,'bookmark_contract_final');web=probe.source.web;web.verify_account()
            after=reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+probe.body['bookId']),probe.body['bookId'])
            if after!=probe.source.plan.web_position:raise ValueError('bookmark_contract/position')
            save_refreshed_web_session(session,saved,web)
            report.update(result='PASS',plans=2,range_is_point=True,source_point_roundtrip=True,original_state_unchanged=True,
                web_position_unchanged=True,no_intent_created=True,hypothetical_new_record=True,preview_crlf_count=probe.body['markText'].count('\r\n'))
        elif args.lua_command:raise ValueError('bookmark_contract/offline')
    except Exception as exc:report.update(result='UNVERIFIED',phase=phase,error_type=type(exc).__name__)
    finally:
        if probe:
            for name,transport in (('native',probe.source.notes),('web',probe.source.web)):
                report[name+'_stages']=[{k:r[k] for k in ('stage','status','error_code','api_code') if k in r} for r in transport.report['stages']]
            probe.source.web.shards.clear();probe.source.web.close();probe.raw=None
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
