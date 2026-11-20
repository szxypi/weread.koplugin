#!/usr/bin/env python3
"""Read-only official-reader observation of one previously cleaned TXT fixture.

Offline by default. The saved path requires the exact restored upload journal
and receipt from the non-BMP native-bookmark trial. No credentials, text,
identities or browser images are reported or written to disk.
"""
import argparse
import json
import resource

from cb_official_viewport import allowed,allowed_bookmark_read
from cb_txt_official_selection import DRAW_HOOK,FIND_POINTS
from cb_txt_padded_bookmark_trial import TEXT
from fetch_weread_epub import reader_url_for
from personal_upload_trial import hash_value
from secure_weread_session import COOKIE_NAMES,SessionStore
from verify_cb_progress import cb_id
from verify_cb_metadata import valid_errors
from verify_cb_reading import CbReadingProbe
from verify_cb_txt_padded_bookmark_native import stores


def fixture_target(journal,receipt,intent,owner):
    state,_claim=journal.read();raw=receipt.backend.load()
    try:record=json.loads(raw) if raw else None
    except (ValueError,TypeError):raise ValueError('official_bookmark/receipt') from None
    if (not state or state.get('phase')!='restored' or intent.read()!=(None,None)
            or not isinstance(record,dict) or set(record)!={'schema','owner','attempt','target','plan_sha256'}
            or type(record['schema']) is not int or record['schema']!=1 or record['owner']!=owner
            or state['plan']['owner']!=owner or record['attempt']!=state['attempt']
            or not cb_id(record['target']) or record['target']!=state['target'] or record['plan_sha256']!=hash_value(state['plan'])):
        raise ValueError('official_bookmark/ownership')
    return record['target']


def read_source(saved,target,source_factory=CbReadingProbe):
    web=source_factory();web.vid=saved['vid'];web.allowed={target}
    try:
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.inspect(target);web.verify_account()
        if (sample.get('book_id')!=target or sample.get('source_format')!='web_txt'
                or not isinstance(sample.get('source'),str) or sample['source'].count(TEXT)!=1
                or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                or not all(value is True for value in web.last_checks.values())):
            raise ValueError('official_bookmark/source')
        return sample
    finally:web.samples.clear();web.close()


def empty_bookmark_response(raw,book):
    if not isinstance(raw,bytes) or len(raw)>4*1024*1024:return False
    try:
        value=json.loads(raw);valid_errors(value)
        return (isinstance(value.get('updated'),list) and not value['updated']
                and value.get('bookId') in (None,book) and value.get('hasMore') in (None,False,0))
    except (ValueError,TypeError,AttributeError):return False


def observe(book,chapters,cookies,*,timeout=30000):
    if (not cb_id(book) or not isinstance(cookies,dict) or not cookies
            or any(k not in COOKIE_NAMES or not isinstance(v,str) or not v for k,v in cookies.items())
            or not isinstance(chapters,list) or not 1<=len(chapters)<=5000):raise ValueError('official_bookmark/scope')
    ids=frozenset(str(row.get('chapterUid')) for row in chapters if isinstance(row,dict))
    if len(ids)!=len(chapters) or any(not uid.isascii() or not uid.isdigit() or len(uid)>20 for uid in ids):
        raise ValueError('official_bookmark/chapters')
    from playwright.sync_api import sync_playwright
    counts=dict(source_posts=0,blocked_posts=0,bookmark_gets=0);seen=[];total=0
    with sync_playwright() as playwright:
        browser=playwright.chromium.launch(channel='chrome',headless=True);context=None
        try:
            context=browser.new_context(service_workers='block',viewport={'width':1024,'height':768})
            context.add_cookies([dict(name=k,value=v,domain='.weread.qq.com',path='/',secure=True) for k,v in cookies.items()])
            def gate(route):
                nonlocal total
                total+=1;request=route.request
                if total>200:route.abort();return
                if allowed_bookmark_read(request.method,request.url,request.post_data,book) and counts['bookmark_gets']==0:
                    counts['bookmark_gets']+=1;response=route.fetch();raw=response.body()
                    if not response.ok or not empty_bookmark_response(raw,book):route.abort();return
                    seen.append(True);route.fulfill(response=response,body=raw);return
                permitted=allowed(request.method,request.url,request.post_data,book,ids)
                if request.method=='POST':counts['source_posts' if permitted else 'blocked_posts']+=1
                if permitted:route.continue_()
                else:route.abort()
            context.route('**/*',gate);context.route_web_socket('**/*',lambda ws:ws.close())
            page=context.new_page();page.add_init_script(DRAW_HOOK)
            page.goto(reader_url_for(book),wait_until='domcontentloaded',timeout=timeout);page.wait_for_timeout(6000)
            context.route('**/*',lambda route:route.abort());context.set_offline(True)
            drawn=page.evaluate('''text => {
                const actual=(window.__wrSelectionDraws||[]).map(v=>v.text).join('').replace(/\\s/g,'');
                return actual.includes(text.replace(/\\s/g,''));
            }''',TEXT)
            points=page.evaluate(FIND_POINTS,TEXT)
            if drawn is not True or not isinstance(points,dict) or set(points)!={'start','end'} or seen!=[True] or counts['bookmark_gets']!=1:
                raise ValueError('official_bookmark/unavailable')
            return dict(source_visible=True,empty_bookmark_list=True,**counts)
        finally:
            if context:context.close()
            browser.close()


def run(saved,journal,receipt,intent,*,source_reader=read_source,browser=observe):
    report=dict(result='UNVERIFIED',account_data_writes=0,authentication_posts=0,private_values_in_report=False,
                official_saved_bookmark_display_verified=False)
    first=second=None
    try:
        target=fixture_target(journal,receipt,intent,saved['vid']);first=source_reader(saved,target)
        observation=browser(target,first['chapters'],saved['cookies'])
        second=source_reader(saved,target)
        if any(first.get(k)!=second.get(k) for k in ('source_raw_sha256','chapter_uid','chapters','baseline')):
            raise ValueError('official_bookmark/changed')
        if (not isinstance(observation,dict) or set(observation)!={'source_visible','empty_bookmark_list','source_posts','blocked_posts','bookmark_gets'}
                or observation['source_visible'] is not True or observation['empty_bookmark_list'] is not True
                or any(type(observation[k]) is not int or observation[k]<0 for k in ('source_posts','blocked_posts','bookmark_gets'))
                or observation['bookmark_gets']!=1):raise ValueError('official_bookmark/observation')
        report.update(result='OFFICIAL_TXT_BOOKMARK_READ_ONLY',source_and_position_unchanged=True,**observation)
    except Exception:pass
    finally:
        if first:first.clear()
        if second:second.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=None
    try:
        saved=SessionStore().load();report=run(saved,*stores())
    except Exception:report=dict(result='UNVERIFIED',account_data_writes=0,authentication_posts=0)
    finally:
        if saved:saved.clear()
    print(json.dumps(report));return int(report['result']!='OFFICIAL_TXT_BOOKMARK_READ_ONLY')


if __name__=='__main__':raise SystemExit(main())
