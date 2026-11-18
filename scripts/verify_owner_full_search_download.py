#!/usr/bin/env python3
"""Validate a real imported-book download/search with read-only network gates."""
import argparse,json,re,resource,subprocess
from urllib.parse import urlencode

from secure_weread_session import COOKIE_NAMES,SessionStore
from verify_cb_book_search import query_text
from verify_cb_native_time_guarded_dry import trusted_command
from verify_cb_reading import CbReadingProbe,baseline_position,readable_chapters
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,versions


def snapshot(web,owner,book):
    probe=CbReadingProbe();probe.vid=owner;probe.book_id=book;probe.allowed={book}
    try:
        for cookie in web.cookies:
            if cookie.name in COOKIE_NAMES and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/':
                probe.set_cookie(cookie.name,cookie.value)
        probe.verify_account()
        shelf=probe.request('shelf',BASE+'/web/shelf/sync')
        catalog,chapters=readable_chapters(probe.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[book]}),book)
        position=baseline_position(probe.request('progress_before',BASE+'/web/book/getProgress?'+urlencode({'bookId':book})),book)
        probe.verify_account()
        return dict(shelf=[str(row['bookId']) for row in shelf['books']],chapters=chapters,
                    versions=versions(catalog),position=position)
    finally:probe.close()


def safe_chapters(chapters):
    if not isinstance(chapters,list) or not 2<=len(chapters)<=500:raise ValueError('owner_full_search/catalog')
    result=[];seen=set()
    for index,row in enumerate(chapters):
        uid=str(row.get('chapterUid','')) if isinstance(row,dict) else ''
        if not re.fullmatch('[1-9][0-9]{0,9}',uid) or int(uid)>2147483647 or uid in seen:
            raise ValueError('owner_full_search/catalog')
        seen.add(uid);words=row.get('wordCount');words=words if type(words) is int and 0<words<=100000000 else 1
        item=dict(chapterUid=uid,title='章节 '+str(index+1),wordCount=words)
        number=row.get('chapterIdx')
        if type(number) is int and 0<=number<=1000000:item['chapterIdx']=number
        result.append(item)
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--diagnostic-two',action='store_true',help='Limit the isolated test to the target and one other chapter')
    args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_writes=0,private_data_on_regular_disk=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report['result']='UNVERIFIED';phase='session';saved=web=payload=None
    try:
        command=trusted_command();prefix=command[:command.index('python3')];candidate=command[-1]
        store=SessionStore();saved=store.load();web=CbReadingProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.prepare(book_index=1)[0]
        if sample['source_format']!='web_xhtml':raise ValueError('owner_full_search/format')
        chapters=safe_chapters(sample['chapters']);ids=[row['chapterUid'] for row in chapters]
        target=sample['chapter_uid'];other=next((uid for uid in ids if uid!=target),None)
        if target not in ids or other is None:raise ValueError('owner_full_search/catalog')
        if args.diagnostic_two:
            chapters=[row for row in chapters if row['chapterUid'] in (target,other)]
            ids=[row['chapterUid'] for row in chapters]
        keyword,offset=query_text(sample['source'],(16,12,8))
        if not keyword or not offset:raise ValueError('owner_full_search/query')
        phase='baseline';before=snapshot(web,saved['vid'],sample['book_id'])
        if (before['position']!=sample['baseline'] or before['chapters']!=sample['chapters']
                or before['shelf']!=sample['shelf_ids']):raise ValueError('owner_full_search/changed')
        cookies={cookie.name:cookie.value for cookie in web.cookies
                 if cookie.name in COOKIE_NAMES and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
        payload=dict(owner=saved['vid'],cookies=cookies,book=sample['book_id'],chapter=target,local_chapter=other,
                     source=sample['source'],chapters=chapters,keyword=keyword,allowed=[dict(chapter=ids[0],start=0,finish=0)],
                     expected_offset=offset[0],full_download_search=True)
        raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
        if len(raw)>8*1024*1024:raise ValueError('owner_full_search/input')
        phase='native_ui';print(json.dumps(dict(phase=phase,chapters=len(chapters),screens=1)),flush=True)
        runner=prefix+['xvfb-run','-a','python3','scripts/run_owner_book_search_ui.py','--koreader',
                       '/validation/runtime/lib/koreader','--candidate',candidate,'--width','1264','--height','1680','--dpi','300']
        child=subprocess.run(runner,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=1000)
        ui_result=None
        if len(child.stdout)<=65536:
            try:value=json.loads(child.stdout)
            except (ValueError,UnicodeError):value={}
            if not isinstance(value,dict):value={}
            if value.get('full_diagnostic') in ('not_started','start','initial_search','downloaded','target_found',
                                                'source_checked','navigation_started','navigation_ready','audited'):
                report['native_diagnostic']=value['full_diagnostic']
            if (child.returncode==0 and value.get('result')=='PASS' and value.get('profile_removed') is True
                    and value.get('installed_bytes_match') is True and value.get('account_data_posts')==0
                    and value.get('authentication_posts')==0 and value.get('ui',{}).get('checked')==len(chapters)):
                ui_result=value['ui']
        phase='readback';after=snapshot(web,saved['vid'],sample['book_id'])
        if before!=after:raise ValueError('owner_full_search/changed')
        report.update(position_unchanged=True,catalog_unchanged=True,shelf_unchanged=True)
        if ui_result is None:raise ValueError('owner_full_search/native')
        save_refreshed_web_session(store,saved,web)
        report.update(result='PASS',chapters=len(chapters),native_screens=1,downloaded_source_verified=True,
                      cancellation_verified=True,offline_navigation_verified=True,credentials_absent_from_profile=True,profile_removed=True,
                      diagnostic_subset=args.diagnostic_two,
                      read_only_download_gets=ui_result['download_gets'],read_only_catalog_posts=ui_result['catalog_posts'],
                      read_only_content_posts=ui_result['content_posts'])
    except Exception as error:
        report['phase']=phase
        if isinstance(error,ValueError) and re.fullmatch(r'owner_full_search/[a-z_]+',str(error)):report['reason']=str(error)
    finally:
        if web:web.close()
        if saved:saved.clear()
        if payload:payload.clear()
    print(json.dumps(report),flush=True);return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
