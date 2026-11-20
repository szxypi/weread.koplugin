#!/usr/bin/env python3
"""Read-only preflight for potential CB progress tests; never dispatch writes.

Private samples and signed-body previews stay in memory and captured pipes.
The default mode neither opens saved credentials nor performs any request.
"""
import argparse
import json
import resource

from cb_cloud_position import observed
from secure_weread_session import SessionStore
from verify_cb_cloud_position import Web
from verify_cb_progress import cb_ids
from verify_position_roundtrip import prepare_plan,verify_lua_payloads
from verify_reader_progress import find_node
from verify_source_coordinates import CoordinateError
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe


def assess(book,raw,context,source):
    """Return a private plan only if the strict existing model can build it."""
    try:
        plan=prepare_plan(book,raw,context,source)
    except (ValueError,TypeError,KeyError,IndexError,CoordinateError):
        return None
    if plan.get('book_id')!=book or plan.get('target') is None:
        return None
    return plan


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session:parser.error('Lua comparison requires saved session')
    report=dict(result='OFFLINE_ONLY',books=0,strict_plans=0,summary_preserved=0,summary_missing=0,
                summary_too_long=0,lua_models_verified=0,
                positions_unchanged=False,shelf_order_unchanged=False,account_data_writes=0,authentication_writes=0,
                private_data_in_report=False,write_authority_granted=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=after=None;plans=[];snapshots=[]
    try:
        store=SessionStore();saved=store.load();web=Web();web.vid=saved['vid']
        for k,v in saved['cookies'].items():web.set_cookie(k,v)
        web.verify_account();shelf=web.request('shelf',BASE+'/web/shelf/sync');ids=cb_ids(shelf);web.allowed=set(ids)
        web.shelf_ids=[str(row['bookId']) for row in shelf['books']];web.shelf_count=len(shelf['books'])
        for book in ids:
            sample=web.inspect(book);raw=web.progress[(book,'progress_before')]
            snapshots.append((book,sample['chapters'],observed(raw,book,sample['chapters'],'web')))
            if sample['source_format']=='web_xhtml':
                plan=assess(book,raw,sample['context'],sample['source'])
                if plan:
                    report['strict_plans']+=1;report['summary_preserved']+=int(plan['same_position_summary_preserved'])
                    node=find_node(raw,book)
                    if 'summary' not in node:report['summary_missing']+=1
                    elif len(node['summary'])>20:report['summary_too_long']+=1
                    plans.append(plan)
                    if args.lua_command:
                        value=verify_lua_payloads(plan,args.lua_command)
                        if value.get('lua_payloads_compared')!=4 or value.get('lua_http_requests')!=0:
                            raise ValueError('cb_preflight/model')
                        report['lua_models_verified']+=1
            report['books']+=1
        web.verify_account()
        if save_refreshed_web_session(store,saved,web):
            old=saved;saved=store.load()
            if saved['vid']!=old['vid']:raise ValueError('cb_preflight/owner')
            old.clear()
        after=WebSourceProbe();after.vid=saved['vid']
        for k,v in saved['cookies'].items():after.set_cookie(k,v)
        after.verify_account()
        for book,chapters,baseline in snapshots:
            after.book_id=book
            latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
            if observed(latest,book,chapters,'web')!=baseline:raise ValueError('cb_preflight/position')
        last=after.request('shelf',BASE+'/web/shelf/sync');after.verify_account()
        if [str(row['bookId']) for row in last['books']]!=web.shelf_ids:raise ValueError('cb_preflight/shelf')
        report.update(result='PREFLIGHT_OBSERVED',positions_unchanged=True,shelf_order_unchanged=True)
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        if web:
            if not after and saved and web.authenticated:
                try:save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            web.samples.clear();web.progress.clear();web.close()
        if after:
            if saved and after.authenticated:
                try:save_refreshed_web_session(store,saved,after)
                except Exception:report['result']='UNVERIFIED'
            after.close()
        if saved:saved.clear()
        plans.clear();snapshots.clear()
    print(json.dumps(report));return int(report['result']!='PREFLIGHT_OBSERVED')


if __name__=='__main__':raise SystemExit(main())
