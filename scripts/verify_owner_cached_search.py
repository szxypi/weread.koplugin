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
    args=parser.parse_args()
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
        web.verify_account()
        report.update(result='PASS',source_checked=1,position_and_catalog_unchanged=True)
    except Exception:
        pass
    finally:
        web.close()
        if saved:saved.clear()
    print(json.dumps(report));return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
