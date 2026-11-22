#!/usr/bin/env python3
"""Read-only owner verification of native-only chapter build and offline reopen."""
import argparse
import hashlib
import json
import resource
import subprocess
from native_chapter_remote_reference import search_token
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe

FRAME=b'\nWEREAD_DIRECT_OWNER_RUN='


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-offset',type=int,default=0,choices=range(0,51))
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('saved session and private command are required together')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,credentials_written_to_files=False)
    saved=credentials=None
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
            payload=dict(credentials=credentials,book_id=sample['book_id'],uid=str(chapter['uid']),
                book_version=sample['expected']['version'],source_sha256=hashlib.sha256(native['source']).hexdigest(),
                search_token=search_token(native['source']))
            raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
            if len(raw)>65536:raise ValueError('input_limit')
            phase='native_worker'
            child=subprocess.run(args.lua_command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=240)
            if len(child.stdout)>65536 or child.stdout.count(FRAME)!=1:raise ValueError('child')
            result=json.loads(child.stdout.split(FRAME,1)[1].splitlines()[0])
            if child.returncode or result.get('result')!='PASS':
                if type(result.get('native_requests_before_stop')) is int and 0<=result['native_requests_before_stop']<=69:
                    report['native_requests_before_stop']=result['native_requests_before_stop']
                allowed={'not_entitled','auth_expired','rate_limited','service_rejected','session_changed',
                         'catalog_changed','unavailable','invalid_source','invalid_image','remote_unsupported','storage'}
                if result.get('reason') in allowed:report['reason']=result['reason']
                raise ValueError('child')
            required={'result','profile_removed','native_requests','source_matches','offline_reopen','offline_network_guard',
                      'web_coordinates','manual_time_blocked','credential_file_audit','installed_bytes_match','missing_images','warning_verified'}
            if (set(result)!=required or type(result['native_requests']) is not int or not 5<=result['native_requests']<=69
                    or type(result['missing_images']) is not int or not 0<=result['missing_images']<=64
                    or result['web_coordinates'] is not False or any(result[key] is not True for key in required-
                        {'result','native_requests','web_coordinates','missing_images'})):
                raise ValueError('result')
            phase='final_shelf'
            if state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=credentials))!=baseline:raise ValueError('shelf_changed')
            report.update(result='NATIVE_DIRECT_OWNER_READONLY_VERIFIED',chapters=1,native_requests=result['native_requests'],
                source_matches=True,offline_reopen=True,offline_network_guard=True,web_coordinates=False,
                manual_time_blocked=True,credential_file_audit=True,installed_bytes_match=True,
                temporary_profile_removed=True,shelf_unchanged=True,missing_images=result['missing_images'],warning_verified=True)
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED';report['phase']=phase
        if 'HTTP 401' in str(error):report['reason']='auth_expired'
        elif 'HTTP 429' in str(error):report['reason']='rate_limited'
    finally:
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
