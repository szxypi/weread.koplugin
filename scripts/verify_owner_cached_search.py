#!/usr/bin/env python3
"""Read-only private source validation; source and credentials never persist."""
import argparse
import json
import resource
import subprocess

from secure_weread_session import SessionStore
from verify_cb_book_search import query_text
from verify_cb_reading import CbReadingProbe


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-ui',action='store_true')
    parser.add_argument('--full',action='store_true')
    parser.add_argument('--candidate',default='/validation/catalog-free-reopen-600-v1/candidate.zip')
    args=parser.parse_args()
    if args.native_ui and not args.saved_session:parser.error('--native-ui requires --saved-session')
    if args.full and not args.native_ui:parser.error('--full requires --native-ui')
    if not args.candidate.startswith('/validation/') or '\x00' in args.candidate:parser.error('invalid candidate path')
    report={'result':'OFFLINE_ONLY','source_checked':0,'account_data_writes':0,'authentication_writes':0}
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report['result']='UNVERIFIED';web=CbReadingProbe();saved=None
    try:
        saved=SessionStore().load();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();samples=web.prepare(book_index=1)
        sample=samples[0]
        if sample['source_format']!='web_xhtml':raise ValueError('format')
        keyword,expected=query_text(sample['source'])
        if not keyword:raise ValueError('sample')
        payload=dict(book=sample['book_id'],chapter=sample['chapter_uid'],source=sample['source'],
                     format=sample['source_format'],keyword=keyword,offset=expected[0])
        command=['docker','exec','-i','-w','/validation/runtime/lib/koreader','weread-validation',
                 'sh','-c','ulimit -c 0; exec "$@"','sh','./luajit','/source/spec/koreader/owner_cached_search_probe.lua']
        child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL,timeout=120)
        marker=b'\nWEREAD_OWNER_CACHED_SEARCH='
        if child.returncode or child.stdout.count(marker)!=1 or len(child.stdout)>65536:raise ValueError('native')
        value=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
        if value!={'result':'PASS','checked':1}:raise ValueError('native')
        if args.native_ui:
            other=next((str(row.get('chapterUid')) for row in sample['chapters']
                        if str(row.get('chapterUid','')).isdigit() and str(row['chapterUid'])!=sample['chapter_uid']
                        and 0<int(row['chapterUid'])<=2147483647),None)
            if not other:raise ValueError('other_chapter')
            payload['local_chapter']=other
            raw=json.dumps(payload,ensure_ascii=False).encode()
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                command=['docker','exec','-i','-w','/source','weread-validation','xvfb-run','-a','python3',
                    'scripts/run_owner_catalog_free_ui.py','--koreader','/validation/runtime/lib/koreader',
                    '--candidate',args.candidate,'--width',str(width),'--height',str(height),'--dpi',str(dpi)]
                if args.full:command.append('--full')
                child=subprocess.run(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=240)
                if child.returncode or len(child.stdout)>65536:raise ValueError('native_ui')
                value=json.loads(child.stdout)
                if value!=dict(result='PASS',profile_removed=True,installed_bytes_match=True,
                               native_navigation=True,bookshelf_resume=True,prior_position_preserved=True,offline=True):raise ValueError('native_ui')
            report['native_ui_screens']=2
            if args.full:report['combined_full_fixture']=True
        web.verify_account()
        report.update(result='PASS',source_checked=1,position_and_catalog_unchanged=True)
    except Exception:
        pass
    finally:
        web.close()
        if saved:saved.clear()
    print(json.dumps(report));return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
