#!/usr/bin/env python3
"""Read-only account validation of restoring a missing local search catalog."""
import argparse,json,re,resource,subprocess

from secure_weread_session import COOKIE_NAMES,SessionStore
from verify_cb_book_search import query_text
from verify_cb_native_time_guarded_dry import trusted_command
from verify_cb_reading import CbReadingProbe
from verify_owner_full_search_download import safe_chapters,snapshot
from verify_translation_preflight import save_refreshed_web_session


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_writes=0,private_data_on_regular_disk=False)
    if not args.saved_session:print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report['result']='UNVERIFIED';phase='session';saved=web=payload=None
    try:
        command=trusted_command();prefix=command[:command.index('python3')];candidate=command[-1]
        store=SessionStore();saved=store.load();web=CbReadingProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.prepare(book_index=1)[0]
        if sample['source_format']!='web_xhtml':raise ValueError('owner_cached_catalog/format')
        chapters=safe_chapters(sample['chapters']);target=sample['chapter_uid']
        if target not in [row['chapterUid'] for row in chapters]:raise ValueError('owner_cached_catalog/catalog')
        keyword,offset=query_text(sample['source'],(16,12,8))
        if not keyword or not offset:raise ValueError('owner_cached_catalog/query')
        phase='baseline';before=snapshot(web,saved['vid'],sample['book_id'])
        if (before['position']!=sample['baseline'] or before['chapters']!=sample['chapters']
                or before['shelf']!=sample['shelf_ids']):raise ValueError('owner_cached_catalog/changed')
        cookies={cookie.name:cookie.value for cookie in web.cookies
                 if cookie.name in COOKIE_NAMES and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
        payload=dict(owner=saved['vid'],cookies=cookies,book=sample['book_id'],chapter=target,source=sample['source'],
                     chapters=chapters,keyword=keyword,allowed=[dict(chapter=chapters[0]['chapterUid'],start=0,finish=0)],
                     cached_catalog_restore=True)
        raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
        if len(raw)>8*1024*1024:raise ValueError('owner_cached_catalog/input')
        phase='native_ui';print(json.dumps(dict(phase=phase,chapters=len(chapters),screens=2)),flush=True)
        passed=0
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            runner=prefix+['xvfb-run','-a','python3','scripts/run_owner_book_search_ui.py','--koreader',
                           '/validation/runtime/lib/koreader','--candidate',candidate,'--width',str(width),
                           '--height',str(height),'--dpi',str(dpi)]
            child=subprocess.run(runner,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=240)
            try:value=json.loads(child.stdout) if len(child.stdout)<=65536 else {}
            except (ValueError,UnicodeError):value={}
            if (child.returncode!=0 or not isinstance(value,dict) or value.get('result')!='PASS'
                    or value.get('profile_removed') is not True or value.get('installed_bytes_match') is not True
                    or value.get('account_data_posts')!=0 or value.get('authentication_posts')!=0
                    or value.get('ui',{}).get('chapters')!=len(chapters)):
                break
            passed+=1
        phase='readback';after=snapshot(web,saved['vid'],sample['book_id'])
        if before!=after:raise ValueError('owner_cached_catalog/changed')
        report.update(position_unchanged=True,catalog_unchanged=True,shelf_unchanged=True)
        if passed!=2:raise ValueError('owner_cached_catalog/native')
        save_refreshed_web_session(store,saved,web)
        report.update(result='PASS',chapters=len(chapters),native_screens=2,cancel_before_request=True,
                      rescanned_and_missing_count_verified=True,pending_position_preserved=True,
                      credential_audit=True,profiles_removed=True,reader_gets=2,read_only_catalog_posts=2)
    except Exception as error:
        report['phase']=phase
        if isinstance(error,ValueError) and re.fullmatch(r'owner_cached_catalog/[a-z_]+',str(error)):report['reason']=str(error)
    finally:
        if web:web.close()
        if saved:saved.clear()
        if payload:payload.clear()
    print(json.dumps(report),flush=True);return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
