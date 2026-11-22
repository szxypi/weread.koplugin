#!/usr/bin/env python3
"""Bounded owner verification of local native reader position, no account writes.

Saved credentials are read from Keychain only when explicitly requested and
pass to the private KOReader runner over stdin. Source and visible text remain
in memory; the public report contains only fixed outcomes.
"""
import argparse
import hashlib
import json
import resource
import subprocess

from fetch_weread_epub import decode_content_shards,make_content_params,read_reader_state,reader_url_for
from native_chapter_remote_reference import search_token
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE as NATIVE_BASE
from verify_native_chapter_package import ChapterProbe
from verify_source_coordinates import FilteredSource
from verify_web_source_progress import BASE,WebSourceProbe

FRAME=b'\nWEREAD_DIRECT_POSITION_OWNER_RUN='


def independent_offset(raw,position):
    if (not isinstance(position,dict) or set(position)!={'ok','text','point_offset','offset'}
            or position['ok'] is not True or not isinstance(position['text'],str)
            or type(position['point_offset']) is not int or type(position['offset']) is not int):
        return False
    model=FilteredSource(raw.decode('utf-8'));flat=[];indices=[]
    for index,char in enumerate(model.characters):
        if not char.isspace():flat.append(char);indices.append(index)
    haystack=''.join(flat);text=position['text'];point=position['point_offset']
    if not 0<=point<=len(text):return False
    windows=[]
    for width in (24,48,96,192):
        first=max(0,point-width);last=min(len(text),point+width)
        windows.extend(((first,last),(point,last),(first,point)))
    for first,last in windows:
        quote=text[first:last]
        if not quote:continue
        start=haystack.find(quote)
        if start<0 or haystack.find(quote,start+1)>=0:continue
        at=start+point-first
        if 0<=at<len(indices) and model.starts[indices[at]]==position['offset']:return True
    return False


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-offset',type=int,choices=range(51),default=0)
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('saved session and private command are required together')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,credentials_written_to_files=False)
    saved=credentials=web=None;phase='start'
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));phase='credentials'
            saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid']);probe=ChapterProbe()
            phase='shelf';baseline=state_hash(probe.request('shelf',NATIVE_BASE+'/shelf/sync',credentials=credentials))
            phase='native_source';sample,chapter,native=probe.inspect(credentials,args.book_offset)
            if sample['expected']['format']!='epub' or sample['expected']['version'] is None or not native['html']:
                raise ValueError('unsupported_sample')
            phase='web_source';web=WebSourceProbe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();web.book_id=sample['book_id'];web.chapter=str(chapter['uid'])
            reader=read_reader_state(web.request('reader',reader_url_for(web.book_id,web.chapter),as_json=False))
            fields=make_content_params(web.book_id,web.chapter,reader.psvts,sc=1)
            parts=[web.request(key,BASE+'/web/book/chapter/'+key,fields,as_json=False) for key in ('e_0','e_1','e_3')]
            if decode_content_shards(*parts).encode()!=native['source']:raise ValueError('source_changed')
            payload=dict(credentials=credentials,book_id=sample['book_id'],uid=str(chapter['uid']),
                book_version=sample['expected']['version'],source_sha256=hashlib.sha256(native['source']).hexdigest(),
                search_token=search_token(native['source']),web_cookies=saved['cookies'])
            data=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
            if len(data)>65536:raise ValueError('input_limit')
            phase='reader_position';report['credentials_written_to_files']=None
            child=subprocess.run(args.lua_command,input=data,stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,timeout=240)
            if len(child.stdout)>65536 or child.stdout.count(FRAME)!=1:raise ValueError('child')
            result=json.loads(child.stdout.split(FRAME,1)[1].splitlines()[0])
            if child.returncode or result.get('result')!='PASS':
                if result.get('phase') in {'input','native_chapter','reader_position','credential_audit'}:report['runner_phase']=result['phase']
                if result.get('reason') in {'auth_expired','rate_limited','service_rejected','unavailable','not_entitled',
                        'invalid','source_changed','anchor_unavailable','source_unsupported','file_changed','session_changed','web_expired'}:
                    report['reason']=result['reason']
                raise ValueError('child')
            if (set(result)!={'result','position','credential_file_audit','installed_bytes_match','profile_removed'}
                    or not all(result[key] is True for key in ('credential_file_audit','installed_bytes_match','profile_removed'))):
                raise ValueError('result')
            phase='independent_offset'
            if not independent_offset(native['source'],result['position']):raise ValueError('offset')
            phase='final_account';web.verify_account()
            phase='final_shelf'
            if state_hash(probe.request('shelf',NATIVE_BASE+'/shelf/sync',credentials=credentials))!=baseline:raise ValueError('shelf_changed')
            report.update(result='NATIVE_DIRECT_POSITION_READONLY_VERIFIED',native_web_source_matches=True,
                actual_reader_position=True,independent_offset_matches=True,temporary_profile_removed=True,
                credential_file_audit=True,credentials_written_to_files=False,installed_bytes_match=True,
                shelf_unchanged=True,cloud_upload=False)
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase)
        if 'HTTP 401' in str(error):report['reason']='auth_expired'
        elif 'HTTP 429' in str(error):report['reason']='rate_limited'
    finally:
        if web:web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
