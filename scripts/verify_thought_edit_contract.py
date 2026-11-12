#!/usr/bin/env python3
"""Prepare three user-text payloads from real snapshots, dispatch none.

Offline by default. Saved-session permits existing GETs only, with optional
captured Lua comparison. No intent, draft, private snapshot or credential file.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess
from urllib.parse import urlencode
from annotation_experiment_model import digest as original_digest
from thought_edit_contract import make
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from verify_annotation_experiment import AnnotationProbe,BASE


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session:parser.error('comparison requires saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),data_posts=0,authentication_posts=0,private_files=False)
    credentials=probe=None
    try:
        if args.saved_session:
            credentials=NativeSessionStore().load(SessionStore().load()['vid']);probe=AnnotationProbe();old=probe.prepare(credentials)
            source=probe.request('contract_marks',BASE+'/book/bookmarklist?'+urlencode(dict(bookId=old.bound['book_id'],synckey=0)),credentials=credentials)
            info=probe.request('contract_metadata',BASE+'/book/info?'+urlencode(dict(bookId=old.bound['book_id'])),credentials=credentials)
            reference=next(row for row in source['updated'] if row['bookmarkId']==old.bound['bookmark_id'])
            snapshot=dict(schema=1,book_id=old.bound['book_id'],fetched_at=1,reviews=list(old.baseline['thoughts'].values()))
            thought=next(row for row in snapshot['reviews'] if row.get('isPrivate') in (0,1))
            text='只读载荷核对，绝不提交 😀。'
            plans=[make(snapshot,'create',reference,text,marks=source,metadata=info,owner=credentials['vid']),make(snapshot,'edit',thought,text),make(snapshot,'delete',thought)]
            if original_digest(probe.observe(credentials,'contract_after'))!=original_digest(old.baseline):raise ValueError('thought_contract/changed')
            if args.lua_command:
                payload=dict(snapshot=snapshot,reference=reference,thought=thought,marks=source,metadata=info,owner=credentials['vid'],content=text)
                child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=60)
                frame=b'\nWEREAD_THOUGHT_CONTRACT_RESULT='
                if child.returncode or len(child.stdout)>1024*1024 or child.stdout.count(frame)!=1:raise ValueError('thought_contract/lua')
                if json.loads(child.stdout.split(frame)[1])!=plans:raise ValueError('thought_contract/different')
                report['lua_matches']=True
            report.update(result='THOUGHT_EDIT_READ_ONLY_CONTRACT_VERIFIED',plans=3,existing_records=len(snapshot['reviews']),original_state_unchanged=True)
    except Exception:report.update(result='UNVERIFIED',reason='thought_contract_unverified')
    finally:
        if probe:report['stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in probe.report['stages']]
        if credentials:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
