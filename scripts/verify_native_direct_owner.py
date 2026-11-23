#!/usr/bin/env python3
"""Read-only owner verification of native-only chapter build and offline reopen."""
import argparse
import hashlib
import json
import re
import resource
import subprocess
from urllib.parse import urlencode
from native_chapter_package import password, read
from native_chapter_remote_reference import search_token
from native_direct_online_search_preflight import prepare as prepare_online_search
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_owner_reading import reading_position
from verify_owner_home_recent import ids as shelf_ids
from verify_translation_preflight import PUBLIC_QUERIES, TranslationError, TranslationProbe
from verify_cloud_book_search import Probe as SearchProbe
from verify_native_txt_position import Native
from verify_reader_progress import find_node,project
from translation_observation import observation
from verify_web_source_progress import BASE as WEB_BASE, WebSourceProbe

FRAME=b'\nWEREAD_DIRECT_OWNER_RUN='


def select_public_sample(credentials,excluded):
    for keyword in PUBLIC_QUERIES[:3]:
        api=TranslationProbe(public_query=keyword)
        try:api.inspect(credentials,3,True)
        except TranslationError as error:
            if str(error)=='translation/no_eligible_sample':continue
            raise
        for sample in api.samples:
            model=sample['expected']
            if sample['book_id'] in excluded or model['format']!='epub' or model['version'] is None:continue
            candidates=[row for row in model['chapters'] if row['uid']>0 and row.get('wordCount',0)>=200
                        and row['free_or_owned'] is True]
            if not candidates:continue
            chapter=min(candidates,key=lambda row:row['uid']);uid=str(chapter['uid'])
            fields=dict(bookId=sample['book_id'],chapters='0,'+uid,bookType='epub',bookVersion=model['version'],
                pf='wechat_wx-2001-android-100-weread',pfkey='pfKey',zoneId=1,quote='',release=1,
                stopAutoPayWhenBNE=1,preload=2,preview=0,offline=1)
            source=ChapterProbe();source.archive_url=BASE+'/book/chapterdownload?'+urlencode(fields)
            data,envelope=source.download(source.archive_url,credentials)
            native=read(data,password(envelope,credentials['vid']),uid)
            if native['html']:return sample,chapter,native,keyword
    raise ValueError('no_public_sample')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-offset',type=int,default=0,choices=range(0,51))
    parser.add_argument('--neighbor',action='store_true',help='Also verify the next explicitly readable chapter')
    parser.add_argument('--copies',action='store_true',help='Check an isolated incomplete comparison copy offline')
    parser.add_argument('--image-refresh',action='store_true',help='Check controlled image recovery in an isolated reader')
    parser.add_argument('--offline-search',action='store_true',help='Verify installed offline search across the two chapters')
    parser.add_argument('--online-search',action='store_true',help='Verify installed online search in both native chapters')
    parser.add_argument('--online-missing',action='store_true',help='Also verify cancel and confirmed missing-chapter download')
    parser.add_argument('--home',action='store_true',help='Verify native home resume in a fresh offline process')
    parser.add_argument('--home-full-ui',action='store_true',help='Require entry through the installed book details')
    parser.add_argument('--compare-web-progress',action='store_true',help='Independently compare the selected book before and after')
    parser.add_argument('--store-search',action='store_true',help='Select an off-shelf book through a public search')
    parser.add_argument('--quick-search',action='store_true',help='Search the bookstore from the native reader')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('saved session and private command are required together')
    if args.home and args.neighbor:parser.error('home and neighbor use separate checks')
    if args.copies and (not args.neighbor or args.online_search or args.offline_search):
        parser.error('copies requires neighbor and excludes search modes')
    if args.image_refresh and (args.neighbor or args.offline_search or args.online_search or args.home):
        parser.error('image refresh excludes home, neighbor and search modes')
    if args.offline_search and not args.neighbor:parser.error('offline search requires neighbor')
    if args.online_search and (not args.neighbor or args.offline_search or not args.compare_web_progress):
        parser.error('online search requires neighbor and Web progress comparison')
    if args.online_missing and not args.online_search:parser.error('online missing requires online search')
    if args.home_full_ui and not args.home:parser.error('full UI requires --home')
    if args.compare_web_progress and not (args.home or args.offline_search or args.online_search or args.copies or args.image_refresh):
        parser.error('Web comparison requires home, chapter search or copy verification')
    if args.store_search and (not args.home_full_ui or not args.compare_web_progress or args.book_offset):
        parser.error('store search requires full home UI and Web comparison')
    if args.quick_search and not args.store_search:parser.error('quick search requires store search')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,credentials_written_to_files=False)
    saved=credentials=web=native_api=None
    phase='start'
    try:
        if args.saved_session:
            phase='credentials'
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid']);probe=ChapterProbe()
            phase='shelf'
            native_shelf=probe.request('shelf',BASE+'/shelf/sync',credentials=credentials)
            baseline=state_hash(native_shelf)
            if args.store_search:
                phase='web_shelf_baseline';web=WebSourceProbe();web.vid=saved['vid']
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account();web_shelf=web.request('shelf',WEB_BASE+'/web/shelf/sync')
                web_shelf_before=state_hash(web_shelf)
                excluded=set(shelf_ids(native_shelf))|set(shelf_ids(web_shelf))
            phase='sample'
            if args.store_search:sample,chapter,native,keyword=select_public_sample(credentials,excluded)
            else:sample,chapter,native=probe.inspect(credentials,args.book_offset)
            if sample['expected']['format']!='epub' or sample['expected']['version'] is None or not native['html']:
                raise ValueError('unsupported_sample')
            if args.compare_web_progress:
                phase='web_baseline'
                if web is None:
                    web=SearchProbe() if args.online_search else WebSourceProbe();web.vid=saved['vid']
                    for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.book_id=sample['book_id']
                web.verify_account()
                raw_progress=web.request('progress_before',WEB_BASE+'/web/book/getProgress?bookId='+sample['book_id'])
                before_web=observation(raw_progress,sample['book_id'],'web') if args.store_search else \
                    reading_position(raw_progress,sample['book_id'],allow_unstarted=True)
            payload=dict(credentials=credentials,book_id=sample['book_id'],uid=str(chapter['uid']),
                book_version=sample['expected']['version'],source_sha256=hashlib.sha256(native['source']).hexdigest(),
                search_token=search_token(native['source']))
            if args.store_search:
                styles=re.findall(r'<style\b[^>]*>(.*?)</style\s*>',native['source'].decode('utf-8'),re.I|re.S)
                if (len(styles)!=1 or not 0<len(styles[0].encode())<=32768 or '\\' in styles[0]
                        or '<' in styles[0] or '@' in styles[0] or re.search(r'url\s*\(',styles[0],re.I)):
                    raise ValueError('inline_style_fixture_unavailable')
                payload.update(store_search_keyword=keyword,inline_style=styles[0])
            if args.neighbor:
                rows=[row for row in sample['expected']['chapters'] if row['uid']>0]
                index=next(i for i,row in enumerate(rows) if row['uid']==chapter['uid'])
                if index+1>=len(rows):raise ValueError('no_neighbor')
                neighbor=rows[index+1]
                if not neighbor['free_or_owned'] or neighbor.get('wordCount',0)<200:raise ValueError('neighbor_unavailable')
                uid=str(neighbor['uid'])
                fields=dict(bookId=sample['book_id'],chapters='0,'+uid,bookType='epub',bookVersion=sample['expected']['version'],
                    pf='wechat_wx-2001-android-100-weread',pfkey='pfKey',zoneId=1,quote='',release=1,
                    stopAutoPayWhenBNE=1,preload=2,preview=0,offline=1)
                second_probe=ChapterProbe()
                second_probe.archive_url=BASE+'/book/chapterdownload?'+urlencode(fields)
                data,envelope=second_probe.download(second_probe.archive_url,credentials)
                second=read(data,password(envelope,credentials['vid']),uid)
                payload['neighbor']=dict(uid=uid,source_sha256=hashlib.sha256(second['source']).hexdigest(),
                    search_token=search_token(second['source']))
            if args.online_search:
                phase='online_search_preflight'
                payload['online_search']=prepare_online_search(web,sample['book_id'],str(chapter['uid']),native['source'])
                payload['web_cookies']={cookie.name:cookie.value for cookie in web.cookies
                    if cookie.name in {'wr_vid','wr_skey','wr_rt','wr_ql','wr_pf'}}
                if payload['web_cookies'].get('wr_vid')!=saved['vid'] or not payload['web_cookies'].get('wr_skey'):
                    raise ValueError('web_cookie')
                native_api=Native(credentials,sample['book_id'])
                native_progress_url=BASE+'/book/getProgress?'+urlencode(dict(bookId=sample['book_id']))
                native_before_raw=native_api.request('progress',native_progress_url,credentials=credentials)
                native_before=project(native_before_raw,sample['book_id'],'native')
                native_before_node=find_node(native_before_raw,sample['book_id'])
                counters=('readingTime','recordReadingTime','ttsTime')
                native_before_counts={key:native_before_node.get(key) for key in counters}
                if any(type(value) is not int or value<0 for value in native_before_counts.values()):raise ValueError('counts')
            raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
            if len(raw)>65536:raise ValueError('input_limit')
            phase='native_worker'
            child=subprocess.run(args.lua_command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                                 timeout=900 if args.online_search else 600 if args.offline_search else 480 if args.home else 240)
            marker=b'\nWEREAD_DIRECT_HOME_OWNER_RUN=' if args.home else FRAME
            if len(child.stdout)>65536 or child.stdout.count(marker)!=1:raise ValueError('child')
            result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
            if child.returncode or result.get('result')!='PASS':
                if result.get('phase') in {'input','native_chapter','record','reopen','audit','prepare','offline_first',
                    'cached_ui','offline_neighbor','neighbor_navigation','offline_search','online_search',
                    'online_missing_prepare','online_missing_search'}:report['runner_phase']=result['phase']
                if result.get('probe_stage') in {'search_dialog','search_results','details','catalog','reader','home_record',
                                                 'quick_menu','quick_input','quick_results','reader','quick','input','results','confirm','switch','locate'}:
                    report['runner_stage']=result['probe_stage']
                if type(result.get('probe_line')) is int and 0<=result['probe_line']<=10000:report['runner_line']=result['probe_line']
                if result.get('archive_status') in {'ok','filename','entry_limit','password','checksum','manifest_chapter',
                    'body_selection','manifest_parse','body_limit','other'}:report['archive_status']=result['archive_status']
                if result.get('download_status') in {'http_200','http_401','http_429','http_other','transport'}:
                    report['download_status']=result['download_status']
                if result.get('payload_status') in {kind+'_'+key for kind in ('empty','zip','json','other')
                                                    for key in ('key','nokey','duplicate')}:
                    report['payload_status']=result['payload_status']
                if type(result.get('native_requests_before_stop')) is int and 0<=result['native_requests_before_stop']<=69:
                    report['native_requests_before_stop']=result['native_requests_before_stop']
                allowed={'not_entitled','auth_expired','rate_limited','service_rejected','session_changed',
                         'catalog_changed','unavailable','invalid_source','invalid_image','remote_unsupported','storage'}
                allowed|={'resource_'+name for name in ('missing','unsupported','ambiguous','inline_style','css','css_import',
                    'css_url','html','body','link_tag','style_tag','unsupported_markup','background_attribute','other_source_attribute',
                    'multiple_styles','source','source_changed','asset','assets','remote_limit','missing_limit','options','unavailable')}
                if result.get('reason') in allowed:report['reason']=result['reason']
                raise ValueError('child')
            if args.home:
                required={'result','profile_removed','native_requests','source_matches','home_record','offline_home_resume',
                          'page_restored','network_blocked','credential_file_audit','installed_bytes_match'}
                if args.home_full_ui:required.add('full_ui')
                if args.store_search:required|={'store_search','inline_style_verified'}
                if args.quick_search:required.add('quick_search')
                if (set(result)!=required or type(result['native_requests']) is not int or not 5<=result['native_requests']<=69
                        or any(result[key] is not True for key in required-{'result','native_requests'})):
                    raise ValueError('result')
                phase='final_shelf'
                if state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=credentials))!=baseline:raise ValueError('shelf_changed')
                if args.compare_web_progress:
                    phase='web_final';web.verify_account()
                    raw_progress=web.request('progress_after',WEB_BASE+'/web/book/getProgress?bookId='+sample['book_id'])
                    after_web=observation(raw_progress,sample['book_id'],'web') if args.store_search else \
                        reading_position(raw_progress,sample['book_id'],allow_unstarted=True)
                    if after_web!=before_web:raise ValueError('web_changed')
                if args.store_search:
                    phase='web_shelf_final';web.book_id=None;web.chapter=None
                    if state_hash(web.request('shelf',WEB_BASE+'/web/shelf/sync'))!=web_shelf_before:raise ValueError('web_shelf_changed')
                report.update(result='NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED',chapters=1,
                    native_requests=result['native_requests'],source_matches=True,home_record=True,offline_home_resume=True,
                    page_restored=True,offline_network_guard=True,credential_file_audit=True,installed_bytes_match=True,
                    temporary_profile_removed=True,shelf_unchanged=True)
                if args.home_full_ui:report['full_ui']=True
                if args.compare_web_progress:report['web_position_unchanged']=True
                if args.store_search:report.update(store_search=True,off_shelf=True,web_shelf_unchanged=True,inline_style_verified=True)
                if args.quick_search:report['quick_search_verified']=True
            else:
                required={'result','profile_removed','native_requests','source_matches','offline_reopen','offline_network_guard',
                          'web_coordinates','manual_time_blocked','credential_file_audit','installed_bytes_match','missing_images','warning_verified'}
                if args.neighbor:required|={'neighbor_matches','neighbor_offline_roundtrip','neighbor_missing_images'}
                if args.copies:required|={'copies_offline_verified','copies_reader_positions'}
                if args.image_refresh:required|={'image_refresh_verified','image_refresh_missing_before','image_refresh_missing_after'}
                if args.offline_search:required.add('offline_search')
                if args.online_search:required.add('online_search')
                if args.online_missing:required.add('online_missing')
                if (set(result)!=required or type(result['native_requests']) is not int or not 5<=result['native_requests']<=69
                        or type(result['missing_images']) is not int or not 0<=result['missing_images']<=64
                        or args.neighbor and (type(result['neighbor_missing_images']) is not int or not 0<=result['neighbor_missing_images']<=64)
                        or args.image_refresh and (type(result['image_refresh_missing_before']) is not int
                            or not 1<=result['image_refresh_missing_before']<=64 or result['image_refresh_missing_before']!=result['missing_images']
                            or type(result['image_refresh_missing_after']) is not int or result['image_refresh_missing_after']!=0)
                        or result['web_coordinates'] is not False or any(result[key] is not True for key in required-
                            {'result','native_requests','web_coordinates','missing_images','neighbor_missing_images',
                             'image_refresh_missing_before','image_refresh_missing_after'})):
                    raise ValueError('result')
                phase='final_shelf'
                if state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=credentials))!=baseline:raise ValueError('shelf_changed')
                if args.compare_web_progress:
                    phase='web_final';web.verify_account()
                    raw_progress=web.request('progress_after',WEB_BASE+'/web/book/getProgress?bookId='+sample['book_id'])
                    if reading_position(raw_progress,sample['book_id'],allow_unstarted=True)!=before_web:raise ValueError('web_changed')
                if args.online_search:
                    phase='native_progress_final'
                    native_after_raw=native_api.request('progress',native_progress_url,credentials=credentials)
                    native_after=project(native_after_raw,sample['book_id'],'native')
                    native_after_node=find_node(native_after_raw,sample['book_id'])
                    fields=('chapter_uid','chapter_idx','chapter_offset','raw_percent','summary','has_chapter_offset')
                    if any(native_before.get(key)!=native_after.get(key) for key in fields) or any(
                            native_before_counts[key]!=native_after_node.get(key) for key in counters):raise ValueError('native_changed')
                report.update(result='NATIVE_DIRECT_OWNER_READONLY_VERIFIED',chapters=1,native_requests=result['native_requests'],
                    source_matches=True,offline_reopen=True,offline_network_guard=True,web_coordinates=False,
                    manual_time_blocked=True,credential_file_audit=True,installed_bytes_match=True,
                    temporary_profile_removed=True,shelf_unchanged=True,missing_images=result['missing_images'],warning_verified=True)
                if args.neighbor:report.update(chapters=2,neighbor_matches=True,neighbor_offline_roundtrip=True,
                    neighbor_missing_images=result['neighbor_missing_images'])
                if args.copies:report.update(copies_offline_verified=True,copies_reader_positions=True)
                if args.image_refresh:report.update(image_refresh_verified=True,image_refresh_missing_before=result['image_refresh_missing_before'],
                    image_refresh_missing_after=result['image_refresh_missing_after'])
                if args.offline_search:report['offline_search_verified']=True
                if args.online_search:report.update(online_search_verified=True,native_progress_unchanged=True)
                if args.online_missing:report.update(missing_cancel_verified=True,missing_download_verified=True)
                if args.compare_web_progress:report['web_position_unchanged']=True
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED';report['phase']=phase
        if 'HTTP 401' in str(error):report['reason']='auth_expired'
        elif 'HTTP 429' in str(error):report['reason']='rate_limited'
    finally:
        if web:web.cookies.clear()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
