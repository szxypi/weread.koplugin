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
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards,make_content_params,read_reader_state,reader_url_for
from native_chapter_remote_reference import search_token
from native_chapter_package import password,read
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE as NATIVE_BASE
from verify_native_chapter_package import ChapterProbe
from verify_native_txt_position import Native
from verify_reader_progress import find_node,project
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe

FRAME=b'\nWEREAD_DIRECT_POSITION_OWNER_RUN='


def independent_offset(raw,position,*,plain_text=False):
    if (not isinstance(position,dict) or set(position)!={'ok','text','point_offset','offset'}
            or position['ok'] is not True or not isinstance(position['text'],str)
            or type(position['point_offset']) is not int or type(position['offset']) is not int):
        return False
    if plain_text:
        from txt_coordinates import PlainSource
        model=PlainSource(raw.decode('utf-8'))
    else:model=FilteredSource(raw.decode('utf-8'))
    flat=[];indices=[]
    for index,char in enumerate(model.characters):
        if not char.isspace() and not (plain_text and index==0 and char=='\ufeff'):
            flat.append(char);indices.append(index)
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


def independent_selection(raw,selection):
    try:
        from annotation_source_quotes import SourceQuotes
        return (isinstance(selection,dict) and set(selection)=={'ok','selection','range','quote'}
            and selection['ok'] is True and isinstance(selection['selection'],str)
            and 1<=len(selection['selection'].encode())<=4096 and isinstance(selection['quote'],str)
            and SourceQuotes(raw.decode('utf-8'),body_only=True).quote(selection['range'])==selection['quote']==selection['selection'])
    except (ValueError,UnicodeError,TypeError,KeyError):return False


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-offset',type=int,choices=range(51),default=0)
    parser.add_argument('--start-page',type=int,choices=range(1,21),default=1)
    parser.add_argument('--cloud',action='store_true',help='Also check cloud comparison and local navigation')
    parser.add_argument('--upload-preview',action='store_true',help='Read-only native upload preflight; no dispatch')
    parser.add_argument('--upload-dry-run',action='store_true',help='Exercise UI and block the native POST')
    parser.add_argument('--current-cloud-chapter',action='store_true',help='Select the explicit readable cloud chapter')
    parser.add_argument('--cloud-denied',action='store_true',help='Exercise a confirmed unavailable cloud chapter')
    parser.add_argument('--cloud-cross',action='store_true',help='Exercise a confirmed readable cloud chapter across files')
    parser.add_argument('--selection',action='store_true',help='Check a native selection without writing account data')
    parser.add_argument('--annotation-preview',action='store_true',help='Also prepare highlight and private thought without dispatch')
    parser.add_argument('--offline-draft',action='store_true',help='Create and reopen a private local draft without network')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('saved session and private command are required together')
    if args.upload_preview and (not args.cloud or args.cloud_cross or args.cloud_denied):parser.error('upload preview requires --cloud without cross or denied')
    if args.upload_dry_run and (not args.cloud or args.cloud_cross or args.cloud_denied or args.upload_preview):parser.error('upload dry run requires --cloud')
    if args.current_cloud_chapter and not args.cloud:parser.error('current cloud chapter requires --cloud')
    if args.cloud_denied and (not args.cloud or args.current_cloud_chapter):parser.error('cloud denied requires a different chapter')
    if args.cloud_cross and (not args.cloud or args.current_cloud_chapter or args.cloud_denied):parser.error('cloud cross requires a readable different chapter')
    if args.selection and args.cloud:parser.error('selection is a separate read-only probe')
    if args.annotation_preview and not args.selection:parser.error('annotation preview requires selection')
    if args.offline_draft and not args.selection:parser.error('offline draft requires selection')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,credentials_written_to_files=False)
    saved=credentials=web=native_api=target_native=store=None;phase='start'
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));phase='credentials'
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid']);probe=ChapterProbe()
            phase='shelf';baseline=state_hash(probe.request('shelf',NATIVE_BASE+'/shelf/sync',credentials=credentials))
            phase='native_source';sample,chapter,native=probe.inspect(credentials,args.book_offset)
            if sample['expected']['format']!='epub' or sample['expected']['version'] is None or not native['html']:
                raise ValueError('unsupported_sample')
            if args.cloud:
                phase='cloud_baseline';native_api=Native(credentials,sample['book_id'])
                progress_url=NATIVE_BASE+'/book/getProgress?'+urlencode(dict(bookId=sample['book_id']))
                baseline_raw=native_api.request('progress',progress_url,credentials=credentials)
                baseline_point=project(baseline_raw,sample['book_id'],'native');baseline_node=find_node(baseline_raw,sample['book_id'])
                count_keys=('readingTime','recordReadingTime','ttsTime')
                baseline_counts={key:baseline_node.get(key) for key in count_keys}
                if any(type(value) is not int or value<0 for value in baseline_counts.values()):raise ValueError('counts')
                if args.cloud_denied:
                    uid=str(baseline_point.get('chapter_uid',''))
                    matches=[row for row in sample['expected']['chapters'] if str(row['uid'])==uid and row['uid']>0]
                    if len(matches)!=1 or matches[0].get('free_or_owned') is not False or uid==str(chapter['uid']):
                        raise ValueError('cloud_chapter_not_denied')
                if args.current_cloud_chapter or args.cloud_cross:
                    uid=str(baseline_point.get('chapter_uid',''))
                    found=[row for row in sample['expected']['chapters'] if str(row['uid'])==uid and row['uid']>0
                           and row.get('free_or_owned') and row.get('wordCount',0)>=200]
                    if len(found)!=1:raise ValueError('cloud_chapter_unavailable')
                    if args.cloud_cross and uid==str(chapter['uid']):raise ValueError('cloud_chapter_not_different')
                    fields=dict(bookId=sample['book_id'],chapters='0,'+uid,bookType='epub',bookVersion=sample['expected']['version'],
                        pf='wechat_wx-2001-android-100-weread',pfkey='pfKey',zoneId=1,quote='',release=1,
                        stopAutoPayWhenBNE=1,preload=2,preview=0,offline=1)
                    remote=ChapterProbe();remote.archive_url=NATIVE_BASE+'/book/chapterdownload?'+urlencode(fields)
                    package,envelope=remote.download(remote.archive_url,credentials)
                    selected_native=read(package,password(envelope,credentials['vid']),uid)
                    if not selected_native['html']:raise ValueError('unsupported_sample')
                    if args.current_cloud_chapter:chapter=found[0];native=selected_native
                    else:target_native=selected_native
            phase='web_source';web=WebSourceProbe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();web.book_id=sample['book_id'];web.chapter=str(chapter['uid'])
            reader=read_reader_state(web.request('reader',reader_url_for(web.book_id,web.chapter),as_json=False))
            fields=make_content_params(web.book_id,web.chapter,reader.psvts,sc=1)
            parts=[web.request(key,BASE+'/web/book/chapter/'+key,fields,as_json=False) for key in ('e_0','e_1','e_3')]
            if decode_content_shards(*parts).encode()!=native['source']:raise ValueError('source_changed')
            if args.cloud_cross:
                phase='target_web_source';web.chapter=str(baseline_point['chapter_uid'])
                other=read_reader_state(web.request('reader',reader_url_for(web.book_id,web.chapter),as_json=False))
                other_fields=make_content_params(web.book_id,web.chapter,other.psvts,sc=1)
                parts=[web.request(key,BASE+'/web/book/chapter/'+key,other_fields,as_json=False) for key in ('e_0','e_1','e_3')]
                if decode_content_shards(*parts).encode()!=target_native['source']:raise ValueError('target_source_changed')
            if save_refreshed_web_session(store,saved,web):
                owner=saved['vid'];saved.clear();saved=store.load()
                if saved['vid']!=owner:raise ValueError('session_changed')
            payload=dict(credentials=credentials,book_id=sample['book_id'],uid=str(chapter['uid']),
                book_version=sample['expected']['version'],source_sha256=hashlib.sha256(native['source']).hexdigest(),
                search_token=search_token(native['source']),web_cookies=saved['cookies'],cloud=args.cloud,
                upload_preview=args.upload_preview,upload_dry_run=args.upload_dry_run,
                cloud_denied=args.cloud_denied,cloud_cross=args.cloud_cross,
                target_uid=str(baseline_point['chapter_uid']) if args.cloud_cross else None,start_page=args.start_page,
                selection=args.selection,annotation_preview=args.annotation_preview,offline_draft=args.offline_draft)
            data=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
            if len(data)>65536:raise ValueError('input_limit')
            phase='reader_position';report['credentials_written_to_files']=None
            child=subprocess.run(args.lua_command,input=data,stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,timeout=240)
            if len(child.stdout)>65536 or child.stdout.count(FRAME)!=1:raise ValueError('child')
            result=json.loads(child.stdout.split(FRAME,1)[1].splitlines()[0])
            if child.returncode or result.get('result')!='PASS':
                if result.get('phase') in {'input','native_chapter','reader_position','credential_audit'}:report['runner_phase']=result['phase']
                if type(result.get('profile_removed')) is bool:report['temporary_profile_removed']=result['profile_removed']
                for key in ('probe_exit','probe_line','position_exit','position_line'):
                    if type(result.get(key)) is int:report[key]=result[key]
                if result.get('reason') in {'auth_expired','rate_limited','service_rejected','unavailable','not_entitled',
                        'invalid','source_changed','anchor_unavailable','source_unsupported','file_changed','session_changed','web_expired','cloud_changed','baseline_unavailable','summary_unavailable',
                        'selection_reference/selection','selection_reference/start_unmatched','selection_reference/end_unmatched',
                        'selection_reference/quote_boundary','selection_reference/quote_ambiguous','selection_reference/source_changed',
                        'selection_reference/source','selection_reference/catalog','selection_reference/reference','selection_reference/unavailable'}:
                    report['reason']=result['reason']
                raise ValueError('child')
            if (set(result)!={'result','position','credential_file_audit','installed_bytes_match','profile_removed'}
                    or not all(result[key] is True for key in ('credential_file_audit','installed_bytes_match','profile_removed'))):
                raise ValueError('result')
            phase='independent_offset'
            output=result['position']
            if args.selection:
                checked={key:output[key] for key in ('ok','selection','range','quote')}
                if not independent_selection(native['source'],checked):raise ValueError('selection')
                if args.annotation_preview and (output.get('mark_preview') is not True or output.get('thought_preview') is not True):raise ValueError('preview')
                if args.offline_draft and output.get('offline_draft') is not True:raise ValueError('offline_draft')
            else:
                current={key:output[key] for key in ('ok','text','point_offset','offset')}
                if not independent_offset(native['source'],current):raise ValueError('offset')
            if args.cloud and not (args.upload_preview or args.upload_dry_run):
                relation=output.get('relation');opened=output.get('opened')
                target_source=target_native['source'] if args.cloud_cross else native['source']
                if opened and not independent_offset(target_source,output.get('target')):raise ValueError('cloud_offset')
            phase='final_account';web.verify_account()
            if args.cloud:
                phase='final_cloud';last=native_api.request('progress',progress_url,credentials=credentials)
                last_point=project(last,sample['book_id'],'native');last_node=find_node(last,sample['book_id'])
                fields=('chapter_uid','chapter_idx','chapter_offset','raw_percent','summary','has_chapter_offset')
                if any(baseline_point.get(key)!=last_point.get(key) for key in fields) \
                        or any(baseline_counts[key]!=last_node.get(key) for key in count_keys):raise ValueError('cloud_changed')
            phase='final_shelf'
            if state_hash(probe.request('shelf',NATIVE_BASE+'/shelf/sync',credentials=credentials))!=baseline:raise ValueError('shelf_changed')
            report.update(result='NATIVE_DIRECT_SELECTION_READONLY_VERIFIED' if args.selection else 'NATIVE_DIRECT_POSITION_READONLY_VERIFIED',native_web_source_matches=True,
                actual_reader_position=not args.selection,independent_offset_matches=not args.selection,temporary_profile_removed=True,
                credential_file_audit=True,credentials_written_to_files=False,installed_bytes_match=True,
                shelf_unchanged=True,cloud_upload=False)
            if args.selection:report.update(actual_reader_selection=True,independent_quote_matches=True)
            if args.annotation_preview:report.update(highlight_preview=True,private_thought_preview=True)
            if args.offline_draft:report.update(offline_draft=True,offline_network_requests=0)
            if args.cloud and not (args.upload_preview or args.upload_dry_run):report.update(cloud_comparison=relation,cloud_position_opened=opened,cloud_unchanged=True)
            if args.upload_preview:report.update(upload_preview=True,cloud_unchanged=True)
            if args.upload_dry_run:report.update(upload_dry_run=True,cloud_unchanged=True,progress_post_blocked=True)
            if args.cloud_denied:report['cloud_chapter_denied']=True
            if args.cloud_cross:report.update(cross_chapter=True,target_native_web_source_matches=True)
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase)
        if 'HTTP 401' in str(error):report['reason']='auth_expired'
        elif 'HTTP 429' in str(error):report['reason']='rate_limited'
    finally:
        if web and saved and store:
            try:save_refreshed_web_session(store,saved,web)
            except Exception:report['result']='UNVERIFIED'
        if web:web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
