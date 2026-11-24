#!/usr/bin/env python3
"""Verify real shelf data through offline, packaged KOReader search controls."""
import argparse
import json
import re
import resource
import subprocess
import unicodedata

from native_shelf_renewal_broker import shelf_projection
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_native_time_guarded_dry import trusted_command
from verify_eink_login import NativeProbe, BASE
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import WebSourceProbe, BASE as WEB


def fold(value): return unicodedata.normalize('NFKC', value).casefold()


def matches(book, query):
    needle = fold(query);fields = [fold(str(book.get(key, ''))) for key in ('title','author','authors','bookId','book_id')]
    return any(needle in value for value in fields) or all(any(term in value for value in fields) for term in needle.split())


def prepare(shelf):
    shelf_projection(shelf)
    books=[];ids=set()
    for row in shelf['books']:
        identity=str(row['bookId']);title=row['title'];author=row.get('author')
        item=dict(bookId=identity,title=title)
        if isinstance(author,str):item['author']=author
        if isinstance(row.get('authors'),str):item['authors']=row['authors']
        books.append(item);ids.add(identity)
    eligible={row['bookId']:row for row in books if not row['bookId'].startswith('MP_WXS_')
              and all(isinstance(row.get(k),str) and re.fullmatch(r'[\u4e00-\u9fffa-zA-Z0-9]{2,20}',row[k]) for k in ('title','author'))}
    labels={};archives=[]
    for row in shelf['archive']:
        ident=str(row['archiveId']);name=row['name'];members=[str(value) for value in row['bookIds']]
        archives.append(dict(archiveId=ident,name=name,bookIds=members))
        label=name.strip() or '未命名分组';labels[label]=labels.get(label,0)+1
    candidates=[]
    for row in archives:
        label=row['name'].strip() or '未命名分组';regular={value for value in row['bookIds'] if not value.startswith('MP_WXS_')}
        if labels[label]==1 and regular and regular<=ids:
            candidates += [(row,eligible[key]) for key in sorted(regular & eligible.keys())]
    if not candidates:raise ValueError('owner_shelf_search/no_candidate')
    group,book=candidates[0];regular=[row for row in books if not row['bookId'].startswith('MP_WXS_')]
    group_ids={value for value in group['bookIds'] if not value.startswith('MP_WXS_')}
    all_ids=[row['bookId'] for row in regular];group_ids_sorted=sorted(group_ids)
    title_author=book['title']+' '+book['author'];id_author=book['bookId']+' '+book['author']
    queries=[title_author,id_author,'KOReaderNoSuchShelfBook0123456789']
    expected_all=sorted(row['bookId'] for row in regular if matches(row,title_author))
    expected_group=[sorted(row['bookId'] for row in regular if row['bookId'] in group_ids and matches(row,query)) for query in queries]
    local_cases=[]
    for value in eligible.values():
        query=value['bookId']+' '+value['author']
        found=[row['bookId'] for row in regular if matches(row,query)]
        if found==[value['bookId']]:
            local_cases.append(dict(query=query,id=value['bookId'],title=value['title']))
        if len(local_cases)==2:break
    if (book['bookId'] not in expected_all or any(book['bookId'] not in result for result in expected_group[:2])
            or expected_group[2] or len(local_cases)!=2 or not 1<=len(books)<=5000 or not 1<=len(archives)<=1000):
        raise ValueError('owner_shelf_search/expected')
    return dict(books=books,archives=archives,group_label=group['name'].strip() or '未命名分组',
                queries=queries,expected_all=expected_all,expected_group=expected_group,
                group_ids=group_ids_sorted,all_ids=sorted(all_ids),local_cases=local_cases)


def command(width,height,dpi):
    known=trusted_command();index=known.index('--candidate')
    if index+2!=len(known):raise ValueError('owner_shelf_search/command')
    return known[:6]+['python3','scripts/run_owner_shelf_search_ui.py','--koreader','/validation/runtime/lib/koreader',
        '--candidate',known[index+1],'--width',str(width),'--height',str(height),'--dpi',str(dpi)]


def run():
    report=dict(result='UNVERIFIED',account_data_posts=0,authorization_posts=0,private_data_in_report=False)
    session=store=web=saved=grant=None
    try:
        session=SessionStore();saved=session.load();store=NativeSessionStore();grant=store.load(saved['vid'])
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account()
        if save_refreshed_web_session(session,saved,web):saved.clear();saved=session.load()
        baseline=web.request('shelf',WEB+'/web/shelf/sync');native=NativeProbe().request('shelf',BASE+'/shelf/sync',credentials=grant)
        if shelf_projection(baseline)!=shelf_projection(native):raise ValueError('owner_shelf_search/channels')
        payload=prepare(native);before_web=state_hash(baseline);before_native=state_hash(native)
        raw=json.dumps(payload,ensure_ascii=False).encode()
        if len(raw)>4*1024*1024:raise ValueError('owner_shelf_search/size')
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            child=subprocess.run(command(width,height,dpi),input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=420,check=True)
            result=json.loads(child.stdout)
            if result!=dict(result='PASS',profile_removed=True,private_data_in_report=False,network_requests=0,
                    books=len(payload['all_ids']),group_books=len(payload['group_ids']),queries=4,offline_reopen=True,
                    installed_bytes_match=True,local_picker_verified=True):raise ValueError('owner_shelf_search/ui')
        after_web=web.request('shelf',WEB+'/web/shelf/sync');after_native=NativeProbe().request('shelf',BASE+'/shelf/sync',credentials=grant)
        if (state_hash(after_web)!=before_web or state_hash(after_native)!=before_native
                or shelf_projection(after_web)!=shelf_projection(after_native) or store.load(saved['vid'])!=grant):
            raise ValueError('owner_shelf_search/changed')
        report.update(result='OWNER_SHELF_SEARCH_UI_VERIFIED',books=len(payload['all_ids']),group_books=len(payload['group_ids']),
            sizes=2,offline_reopen=True,shelf_unchanged=True,temporary_profiles_removed=True,local_picker_verified=True)
    except Exception:
        pass
    finally:
        if web and saved and session:
            try:save_refreshed_web_session(session,saved,web)
            except Exception:report['result']='UNVERIFIED'
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authorization_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report=run();print(json.dumps(report));return int(report['result']!='OWNER_SHELF_SEARCH_UI_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
