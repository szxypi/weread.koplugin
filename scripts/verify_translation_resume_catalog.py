#!/usr/bin/env python3
"""Read-only real catalogue stability and native resume-store comparison.

Credentials and catalogue contents stay in memory or anonymous pipes. The
native subprocess uses synthetic book IDs and text in an isolated tmpfs DB.
"""
import argparse
import json
import re
import resource
import subprocess

from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_web_source_progress import BASE, WebSourceProbe

FRAME=b'\nWEREAD_RESUME_CATALOG='


def shelf_ids(shelf,limit=3):
    if not isinstance(shelf,dict) or not isinstance(shelf.get('books'),list) or len(shelf['books'])>5000:
        raise ValueError('shelf_invalid')
    result=[]
    for row in shelf['books']:
        if not isinstance(row,dict): continue
        value=row.get('bookId')
        if type(value) in (str,int) and re.fullmatch(r'[1-9][0-9]{0,19}',str(value)) and str(value) not in result:
            result.append(str(value))
            if len(result)==limit: break
    return result


def check_result(value,samples):
    if not isinstance(value,dict) or set(value)!={'samples'} or not isinstance(value['samples'],list) or len(value['samples'])!=samples:
        raise ValueError('native_result_invalid')
    for item in value['samples']:
        if (not isinstance(item,dict) or set(item)!={'chapters','resumed','kept'} or type(item['chapters']) is not int
                or not 1<=item['chapters']<=2000 or type(item['resumed']) is not bool or item['kept'] is not item['resumed']):
            raise ValueError('native_result_invalid')
    return value['samples']


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--saved-session',action='store_true')
    p.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=p.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command): p.error('saved session and isolated native command must be supplied together')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authorization_posts=0,private_catalog_saved=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=None;probe=WebSourceProbe();phase='session'
    try:
        saved=SessionStore().load();probe.vid=saved['vid']
        for key,value in saved['cookies'].items(): probe.set_cookie(key,value)
        probe.verify_account();phase='shelf'
        shelf=probe.request('shelf',BASE+'/web/shelf/sync');before=state_hash(shelf)
        ids=shelf_ids(shelf)
        if not ids: raise ValueError('no_books')
        samples=[];phase='catalog'
        for book in ids:
            probe.book_id=book
            first=probe.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[book]})
            second=probe.request('catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[book]})
            samples.append(dict(book_id=book,first=first,second=second))
        payload=json.dumps(dict(samples=samples),ensure_ascii=False,separators=(',',':')).encode()
        if len(payload)>12*1024*1024: raise ValueError('input_limit')
        phase='native';child=subprocess.run(args.lua_command,input=payload,capture_output=True,timeout=90)
        if child.returncode or len(child.stdout)>65536 or child.stdout.count(FRAME)!=1: raise ValueError('native_unavailable')
        observations=check_result(json.loads(child.stdout.split(FRAME)[1]),len(samples))
        phase='readback';probe.book_id=None
        after=state_hash(probe.request('shelf',BASE+'/web/shelf/sync'))
        probe.verify_account()
        report.update(result='READ_ONLY_CHECKED',books_checked=len(samples),chapters_checked=sum(x['chapters'] for x in observations),
            stable_catalogs=sum(x['resumed'] for x in observations),unstable_catalogs=sum(not x['resumed'] for x in observations),
            native_store_verified=True,shelf_unchanged=before==after)
    except Exception:
        report.update(result='UNVERIFIED',phase=phase)
        if probe.report['stages'] and 'status' in probe.report['stages'][-1]: report['http_status']=probe.report['stages'][-1]['status']
    finally:
        probe.close()
        if saved: saved.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result']!='READ_ONLY_CHECKED')


if __name__=='__main__': raise SystemExit(main())
