#!/usr/bin/env python3
"""Read-only exact TXT excerpt comparison. Private text stays in pipes/RAM.

This validates source slicing, not an official summary normalization rule or
the reader UI. No progress/authentication writes or automatic renewal.
"""
import argparse
from datetime import datetime,timezone
import json
import resource
import subprocess
from txt_coordinates import PlainSource
from secure_weread_session import SessionStore
from verify_txt_cloud_position import Probe
from verify_translation_preflight import save_refreshed_web_session
from verify_native_position_lua import equivalent


def queries(model, current=None):
    indices={0,len(model.raw)//2,len(model.raw)-1}
    for predicate in (lambda c:ord(c)>0xffff,lambda c:c=='\r',lambda c:c=='\n',lambda c:c in '<&\ufeff'):
        at=next((i for i,c in enumerate(model.raw) if predicate(c)),None)
        if at is not None:indices.update({max(0,at-1),at,min(len(model.raw)-1,at+1)})
    offsets={model.offsets[i] for i in indices}
    if current is not None:
        model.excerpt(current);offsets.add(current)
    return [dict(co=co,limit=limit) for co in sorted(offsets) for limit in (1,30,512)]


def compare(model, selected, command, runner=subprocess.run):
    if not selected or len(selected)>64:raise ValueError('txt_excerpt/queries')
    expected=dict(result='PASS',excerpts=[model.excerpt(q['co'],q['limit']) for q in selected])
    raw=json.dumps(dict(raw=model.raw,queries=selected),ensure_ascii=False).encode()
    if len(raw)>3*1024*1024:raise ValueError('txt_excerpt/input')
    child=runner(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
    if child.returncode or not isinstance(child.stdout,bytes) or len(child.stdout)>256*1024:raise ValueError('txt_excerpt/child')
    try:value=json.loads(child.stdout)
    except Exception:raise ValueError('txt_excerpt/response') from None
    if not equivalent(expected,value):raise ValueError('txt_excerpt/mismatch')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.saved_session!=bool(a.lua_command):p.error('saved session and a private Lua command required together')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,production_upload_enabled=False,private_source_on_regular_disk=False)
    saved=web=None
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            store=SessionStore();saved=store.load();web=Probe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            if not web.find_sample(limit=16):raise ValueError('txt_excerpt/no_sample')
            plan=web.inspect_plan();model=PlainSource(web.sample['plain'])
            selected=queries(model,plan['baseline']['chapter_offset']);compare(model,selected,a.lua_command)
            if web.inspect_plan()!=plan:raise ValueError('txt_excerpt/changed')
            report.update(result='TXT_LITERAL_EXCERPTS_VERIFIED',comparisons=len(selected),source_catalog_and_progress_unchanged=True,
                          full_30_scalar_raw_slice_matches_cloud_summary=model.excerpt(plan['baseline']['chapter_offset'])['text']==plan['baseline']['summary'],
                          official_summary_rule_verified=False,reader_ui_verified=False)
    except (Exception,KeyboardInterrupt):report['result']='UNVERIFIED'
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            report['stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.sample=None;web.close()
        if saved:saved.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
