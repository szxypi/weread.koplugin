#!/usr/bin/env python3
"""Compare full-summary CB payload models using real read-only state.

Default is offline. Real context and summaries use captured anonymous pipes;
this program does not construct a client capable of dispatching a write.
"""
import argparse
import json
import math
import resource
import subprocess

from cb_cloud_position import observed
from fetch_weread_epub import make_read_params,sorted_query,weread_sign
from secure_weread_session import SessionStore
from verify_cb_cloud_position import Web
from verify_cb_progress import cb_ids
from verify_cb_roundtrip_preflight import assess
from verify_reader_progress import find_node
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe


def vectors(plan,raw):
    node=find_node(raw,plan['book_id']);summary=node.get('summary')
    percent=plan['baseline']['raw_percent']
    if (not isinstance(summary,str) or not 20<len(summary)<=512 or len(summary.encode())>2048
            or any(ord(c)<32 and c not in '\t\n\r' for c in summary)
            or type(percent) not in (int,float) or not math.isfinite(percent) or percent!=math.floor(percent)):
        raise ValueError('cb_full_summary/input')
    point=plan['baseline'];context=plan['context'];token=context.get('token') or '3c5c8717f3daf09iop3423zafeqoi'
    result=[]
    for stage in ('enter','position'):
        expected=make_read_params(book_id=plan['book_id'],chapter_uid=point['chapter_uid'],chapter_idx=point['chapter_idx'],
            chapter_offset=point['chapter_offset'],progress=int(percent),summary=summary,psvts=context['psvts'],
            pclts=plan['pclts'],token=token,elapsed_seconds=0)
        if stage=='enter':
            for key in ('rt','ts','rn','sg'):expected.pop(key)
        expected['sm']=summary;expected['s']=weread_sign(sorted_query({k:v for k,v in expected.items() if k!='s'}))
        opts=dict(book_id=plan['book_id'],chapter_uid=str(point['chapter_uid']),chapter_idx=point['chapter_idx'],
            chapter_offset=point['chapter_offset'],progress=int(percent),summary=summary,psvts=context['psvts'],
            pclts=plan['pclts'],token=token,now=expected['ct'])
        if stage=='position':opts.update(ts=expected['ts'],rn=expected['rn'])
        result.append(dict(stage=stage,options=opts,expected=expected))
    return result


def compare(samples,command):
    if not samples or len(samples)>16:raise ValueError('cb_full_summary/samples')
    payload=json.dumps(dict(samples=samples),ensure_ascii=False).encode()
    if len(payload)>65536:raise ValueError('cb_full_summary/limit')
    child=subprocess.run(command,input=payload,capture_output=True,timeout=90)
    marker=b'\nWEREAD_CB_FULL_SUMMARY_PAYLOAD='
    if child.returncode or len(child.stdout)>65536 or child.stdout.count(marker)!=1:raise ValueError('cb_full_summary/lua')
    result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
    if result!=dict(matches=len(samples),total=len(samples),network_requests=0):raise ValueError('cb_full_summary/mismatch')
    return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.saved_session and not args.lua_command or args.lua_command and not args.saved_session:
        parser.error('explicit session and Lua model command must be supplied together')
    report=dict(result='OFFLINE_ONLY',books=0,candidates=0,payloads_compared=0,account_data_writes=0,
                authentication_writes=0,private_data_in_report=False,write_authority_granted=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=after=None;samples=[];snapshots=[]
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
                    try:sample_vectors=vectors(plan,raw)
                    except ValueError:sample_vectors=[]
                    if sample_vectors:samples.extend(sample_vectors);report['candidates']+=1
            report['books']+=1
        compare(samples,args.lua_command);report['payloads_compared']=len(samples)
        web.verify_account()
        if save_refreshed_web_session(store,saved,web):
            old=saved;saved=store.load()
            if saved['vid']!=old['vid']:raise ValueError('cb_full_summary/owner')
            old.clear()
        after=WebSourceProbe();after.vid=saved['vid']
        for k,v in saved['cookies'].items():after.set_cookie(k,v)
        after.verify_account()
        for book,chapters,baseline in snapshots:
            after.book_id=book
            latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
            if observed(latest,book,chapters,'web')!=baseline:raise ValueError('cb_full_summary/position')
        last=after.request('shelf',BASE+'/web/shelf/sync');after.verify_account()
        if [str(row['bookId']) for row in last['books']]!=web.shelf_ids:raise ValueError('cb_full_summary/shelf')
        report.update(result='FULL_SUMMARY_MODELS_MATCH',positions_unchanged=True,shelf_order_unchanged=True)
    except Exception:report['result']='UNVERIFIED'
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
        samples.clear();snapshots.clear()
    print(json.dumps(report));return int(report['result']!='FULL_SUMMARY_MODELS_MATCH')


if __name__=='__main__':raise SystemExit(main())
