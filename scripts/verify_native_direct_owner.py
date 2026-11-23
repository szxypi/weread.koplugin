#!/usr/bin/env python3
"""Read-only owner verification of native-only chapter build and offline reopen."""
import argparse
import hashlib
import json
import resource
import subprocess
from urllib.parse import urlencode
from native_chapter_package import password, read
from native_chapter_remote_reference import search_token
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_owner_reading import reading_position
from verify_web_source_progress import BASE as WEB_BASE, WebSourceProbe

FRAME=b'\nWEREAD_DIRECT_OWNER_RUN='


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-offset',type=int,default=0,choices=range(0,51))
    parser.add_argument('--neighbor',action='store_true',help='Also verify the next explicitly readable chapter')
    parser.add_argument('--home',action='store_true',help='Verify native home resume in a fresh offline process')
    parser.add_argument('--home-full-ui',action='store_true',help='Require entry through the installed book details')
    parser.add_argument('--compare-web-progress',action='store_true',help='Independently compare the selected book before and after')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('saved session and private command are required together')
    if args.home and args.neighbor:parser.error('home and neighbor use separate checks')
    if args.home_full_ui and not args.home:parser.error('full UI requires --home')
    if args.compare_web_progress and not args.home:parser.error('Web comparison requires --home')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,credentials_written_to_files=False)
    saved=credentials=web=None
    phase='start'
    try:
        if args.saved_session:
            phase='credentials'
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid']);probe=ChapterProbe()
            phase='shelf'
            baseline=state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=credentials))
            phase='sample'
            sample,chapter,native=probe.inspect(credentials,args.book_offset)
            if sample['expected']['format']!='epub' or sample['expected']['version'] is None or not native['html']:
                raise ValueError('unsupported_sample')
            if args.compare_web_progress:
                phase='web_baseline';web=WebSourceProbe();web.vid=saved['vid'];web.book_id=sample['book_id']
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account()
                before_web=reading_position(web.request('progress_before',WEB_BASE+'/web/book/getProgress?bookId='+sample['book_id']),
                                            sample['book_id'],allow_unstarted=True)
            payload=dict(credentials=credentials,book_id=sample['book_id'],uid=str(chapter['uid']),
                book_version=sample['expected']['version'],source_sha256=hashlib.sha256(native['source']).hexdigest(),
                search_token=search_token(native['source']))
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
            raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
            if len(raw)>65536:raise ValueError('input_limit')
            phase='native_worker'
            child=subprocess.run(args.lua_command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=480 if args.home else 240)
            marker=b'\nWEREAD_DIRECT_HOME_OWNER_RUN=' if args.home else FRAME
            if len(child.stdout)>65536 or child.stdout.count(marker)!=1:raise ValueError('child')
            result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
            if child.returncode or result.get('result')!='PASS':
                if type(result.get('native_requests_before_stop')) is int and 0<=result['native_requests_before_stop']<=69:
                    report['native_requests_before_stop']=result['native_requests_before_stop']
                allowed={'not_entitled','auth_expired','rate_limited','service_rejected','session_changed',
                         'catalog_changed','unavailable','invalid_source','invalid_image','remote_unsupported','storage'}
                if result.get('reason') in allowed:report['reason']=result['reason']
                raise ValueError('child')
            if args.home:
                required={'result','profile_removed','native_requests','source_matches','home_record','offline_home_resume',
                          'page_restored','network_blocked','credential_file_audit','installed_bytes_match'}
                if args.home_full_ui:required.add('full_ui')
                if (set(result)!=required or type(result['native_requests']) is not int or not 5<=result['native_requests']<=69
                        or any(result[key] is not True for key in required-{'result','native_requests'})):
                    raise ValueError('result')
                phase='final_shelf'
                if state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=credentials))!=baseline:raise ValueError('shelf_changed')
                if args.compare_web_progress:
                    phase='web_final';web.verify_account()
                    if reading_position(web.request('progress_after',WEB_BASE+'/web/book/getProgress?bookId='+sample['book_id']),
                                        sample['book_id'],allow_unstarted=True)!=before_web:raise ValueError('web_changed')
                report.update(result='NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED',chapters=1,
                    native_requests=result['native_requests'],source_matches=True,home_record=True,offline_home_resume=True,
                    page_restored=True,offline_network_guard=True,credential_file_audit=True,installed_bytes_match=True,
                    temporary_profile_removed=True,shelf_unchanged=True)
                if args.home_full_ui:report['full_ui']=True
                if args.compare_web_progress:report['web_position_unchanged']=True
            else:
                required={'result','profile_removed','native_requests','source_matches','offline_reopen','offline_network_guard',
                          'web_coordinates','manual_time_blocked','credential_file_audit','installed_bytes_match','missing_images','warning_verified'}
                if args.neighbor:required|={'neighbor_matches','neighbor_offline_roundtrip','neighbor_missing_images'}
                if (set(result)!=required or type(result['native_requests']) is not int or not 5<=result['native_requests']<=69
                        or type(result['missing_images']) is not int or not 0<=result['missing_images']<=64
                        or args.neighbor and (type(result['neighbor_missing_images']) is not int or not 0<=result['neighbor_missing_images']<=64)
                        or result['web_coordinates'] is not False or any(result[key] is not True for key in required-
                            {'result','native_requests','web_coordinates','missing_images','neighbor_missing_images'})):
                    raise ValueError('result')
                phase='final_shelf'
                if state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=credentials))!=baseline:raise ValueError('shelf_changed')
                report.update(result='NATIVE_DIRECT_OWNER_READONLY_VERIFIED',chapters=1,native_requests=result['native_requests'],
                    source_matches=True,offline_reopen=True,offline_network_guard=True,web_coordinates=False,
                    manual_time_blocked=True,credential_file_audit=True,installed_bytes_match=True,
                    temporary_profile_removed=True,shelf_unchanged=True,missing_images=result['missing_images'],warning_verified=True)
                if args.neighbor:report.update(chapters=2,neighbor_matches=True,neighbor_offline_roundtrip=True,
                    neighbor_missing_images=result['neighbor_missing_images'])
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
