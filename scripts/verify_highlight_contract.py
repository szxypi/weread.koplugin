#!/usr/bin/env python3
"""Read-only Python/Lua plans using real own sets and real source selection."""
import argparse
import json
import subprocess
from copy import deepcopy
from mark_edit_contract import make
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from selection_trial_probe import SelectionProbe
from verify_translation_preflight import save_refreshed_web_session


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--styles',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);source=None;saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);source=SelectionProbe()
            phase='prepare';p=source.prepare(saved,credentials);old=p.baseline;book=p.bound['book_id']
            snapshot=dict(book_id=book,marks=dict(schema=1,book_id=book,fetched_at=1,updated=list(old['marks']['updated'].values()),chapters=list(old['marks']['chapters'].values())),
                thoughts=dict(schema=1,book_id=book,fetched_at=1,reviews=list(old['thoughts'].values())))
            reference=source.payload['selection_preview']['reference'];metadata=dict(bookId=book,bookVersion=p.context['bookVersion'])
            phase='models';creation=make(snapshot,'create',reference,metadata)
            # Do not select an original linked highlight merely to obtain a
            # deletion plan. Add a hypothetical new row to the real baseline;
            # this has no network side effect and is explicitly reported.
            target={k:v for k,v in creation['body'].items() if k not in ('bookId','bookVersion')}
            target['bookmarkId']='synthetic-contract-new-highlight'
            deletion_snapshot=deepcopy(snapshot);deletion_snapshot['marks']['updated'].append(target)
            plans=[creation,make(deletion_snapshot,'delete',target)]
            if args.styles:
                plans.extend(make(deletion_snapshot,'style',target,style=value) for value in (0,2))
                straight=deepcopy(deletion_snapshot);straight['marks']['updated'][-1]['style']=0
                plans.append(make(straight,'style',straight['marks']['updated'][-1],style=1))
            if args.lua_command:
                phase='lua';payload=dict(snapshot=snapshot,deletion_snapshot=deletion_snapshot,reference=reference,target=target,metadata=metadata,styles=args.styles)
                child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=60)
                frame=b'\nWEREAD_HIGHLIGHT_CONTRACT_RESULT='
                if child.returncode or len(child.stdout)>4*1024*1024 or child.stdout.count(frame)!=1:raise ValueError('mark_edit/lua')
                phase='compare'
                if json.loads(child.stdout.split(frame)[1])!=plans:raise ValueError('mark_edit/different')
                report['python_lua_match']=True
            phase='final';source.baseline(credentials,'highlight_contract_final');save_refreshed_web_session(session,saved,source.web)
            report.update(result='PASS',plans=len(plans),original_state_unchanged=True,no_intent_created=True,deletion_plan_uses_hypothetical_new_record=True,
                style_plans_use_hypothetical_new_record=args.styles)
        elif args.lua_command:raise ValueError('mark_edit/offline')
    except Exception as exc:report.update(result='UNVERIFIED',phase=phase,error_type=type(exc).__name__)
    finally:
        if source:
            for name,transport in (('native',source.notes),('web',source.web)):
                report[name+'_stages']=[{k:r[k] for k in ('stage','status','error_code','api_code') if k in r} for r in transport.report['stages']]
            source.web.shards.clear();source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
