#!/usr/bin/env python3
"""Read-only real-account direct-chapter personal-mark display and offline reopen."""
import argparse
import hashlib
import json
import resource
import subprocess
import time
from urllib.parse import urlencode

from annotation_experiment_model import digest,thoughts_state
from annotation_source_quotes import SourceQuotes
from fetch_weread_epub import decode_content_shards,make_content_params,read_reader_state,reader_url_for
from my_cloud_marks_model import identifier,project
from native_chapter_package import password,read
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_annotation_experiment import AnnotationProbe,query
from verify_eink_login import BASE as NATIVE,NativeProbe
from verify_native_chapter_package import ChapterProbe
from verify_owner_reading import reading_position
from verify_translation_preflight import catalog,catalog_body,save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe

FRAME=b'\nWEREAD_DIRECT_PERSONAL_OWNER_RUN='


def normalized(value):return ''.join(char for char in value if not char.isspace())


def verify_rows(raw,baseline,uid,rows,thoughts=False):
    if not isinstance(rows,list) or not 1<=len(rows)<=100:return False
    seen=set()
    try:
        model=SourceQuotes(raw.decode('utf-8'),body_only=True)
        for row in rows:
            fields={'id','range','text'}|({'content_sha256'} if thoughts else set())
            if not isinstance(row,dict) or set(row)!=fields or row['id'] in seen:return False
            original=(baseline['thoughts'] if thoughts else baseline['marks']['updated']).get(row['id'])
            quote=original.get('abstract' if thoughts else 'markText') if original else None
            if (not original or original.get('type')!=1 or str(original.get('chapterUid'))!=uid
                    or original.get('range')!=row['range'] or not isinstance(quote,str)
                    or not isinstance(row['text'],str) or not normalized(row['text'])
                    or normalized(model.quote(row['range']))!=normalized(quote)
                    or normalized(row['text'])!=normalized(quote)
                    or thoughts and (not isinstance(original.get('content'),str)
                        or hashlib.sha256(original['content'].encode()).hexdigest()!=row['content_sha256'])):return False
            seen.add(row['id'])
        return True
    except (ValueError,TypeError,KeyError,UnicodeError):return False


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--thoughts',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('saved session and private runner required together')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0)
    if not args.saved_session:print(json.dumps(report));return 0
    saved=credentials=web=notes=None;phase='session'
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0));session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
        phase='sample_shelf';native=NativeProbe();shelf=native.request('shelf',NATIVE+'/shelf/sync',credentials=credentials)
        phase='sample_notebooks'
        notebooks=native.request('notebooks',NATIVE+'/user/notebooks?count=100',credentials=credentials)
        if not isinstance(shelf.get('books'),list) or not isinstance(notebooks.get('books'),list):raise ValueError('sample')
        ids={str(row.get('bookId')) for row in shelf['books'] if isinstance(row,dict) and identifier(str(row.get('bookId')))}
        choices=[]
        for row in notebooks['books']:
            book=row.get('book',row) if isinstance(row,dict) else None
            identity=str(book.get('bookId')) if isinstance(book,dict) else ''
            count=(row.get('reviewCount',0) if args.thoughts else
                sum(value for value in (row.get('noteCount',0),row.get('bookmarkCount',0)) if type(value) is int and value>0))
            if type(count) is not int or count<0 or args.thoughts and count>18:continue
            if identity in ids and count:choices.append((count,identity))
        selected=None
        for _count,book in sorted(choices,reverse=True)[:8]:
            if args.thoughts:
                phase='sample_thoughts'
                response=native.request('thoughts',query(book),credentials=credentials)
                model=thoughts_state(response,book,credentials['vid'])
                marked={str(row.get('chapterUid')) for row in model.values() if row.get('type')==1 and row.get('range')
                    and row.get('abstract') and len(row['abstract'].encode())<=4096}
            else:
                phase='sample_marks'
                response=native.request('marks',NATIVE+'/book/bookmarklist?'+urlencode(dict(bookId=book,synckey=0)),credentials=credentials)
                model=project(response,book,credentials['vid'],int(time.time()))
                marked={str(row.get('chapterUid')) for row in model['updated'] if row.get('type')==1 and row.get('range') and row.get('markText')}
            if not marked:continue
            phase='sample_catalog'
            probe=ChapterProbe();probe.allowed={book}
            info=probe.request('book',NATIVE+'/book/info?'+urlencode(dict(bookId=book)),credentials=credentials)
            catalog_model=catalog(probe.request('catalog',NATIVE+'/book/chapterInfos',catalog_body(book),credentials=credentials),book,info)
            chapters=[row for row in catalog_model['chapters'] if str(row['uid']) in marked and row.get('free_or_owned') is True
                and catalog_model['format']=='epub' and catalog_model['version'] is not None and row.get('wordCount',0)>0]
            if chapters:
                selected=(book,catalog_model,chapters[0]);break
        if selected is None:raise ValueError('no_eligible_marked_chapter')
        book,model,chapter=selected;uid=str(chapter['uid']);notes=AnnotationProbe();notes.identity=book;notes.grant=digest(credentials)
        phase='baseline';before=notes.observe(credentials,'direct_personal_before')
        collection=before['thoughts'] if args.thoughts else before['marks']['updated']
        rows=[row for row in collection.values() if row.get('type')==1 and str(row.get('chapterUid'))==uid]
        if not 1<=len(rows)<=100:raise ValueError('marks')
        phase='native_source';fields=dict(bookId=book,chapters='0,'+uid,bookType='epub',bookVersion=model['version'],
            pf='wechat_wx-2001-android-100-weread',pfkey='pfKey',zoneId=1,quote='',release=1,stopAutoPayWhenBNE=1,preload=2,preview=0,offline=1)
        archive_probe=ChapterProbe();archive_probe.archive_url=NATIVE+'/book/chapterdownload?'+urlencode(fields)
        archive,envelope=archive_probe.download(archive_probe.archive_url,credentials);source=read(archive,password(envelope,credentials['vid']),uid)
        if not source['html']:raise ValueError('source')
        phase='web_source';web=WebSourceProbe();web.vid=saved['vid'];web.book_id=book;web.chapter=uid
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();before_web=reading_position(web.request('progress_before',BASE+'/web/book/getProgress?bookId='+book),book)
        reader=read_reader_state(web.request('reader',reader_url_for(book,uid),as_json=False))
        fields=make_content_params(book,uid,reader.psvts,sc=1)
        parts=[web.request(key,BASE+'/web/book/chapter/'+key,fields,as_json=False) for key in ('e_0','e_1','e_3')]
        if decode_content_shards(*parts).encode()!=source['source']:raise ValueError('source_changed')
        if notes.observe(credentials,'direct_personal_independent')!=before:raise ValueError('baseline_changed')
        web.verify_account();save_refreshed_web_session(session,saved,web);saved=session.load()
        payload=dict(credentials=credentials,book_id=book,uid=uid,book_version=model['version'],
            source_sha256=hashlib.sha256(source['source']).hexdigest(),web_cookies=saved['cookies'],expect_thoughts=args.thoughts)
        phase='reader';child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,timeout=480)
        if len(child.stdout)>131072 or child.stdout.count(FRAME)!=1:raise ValueError('frame')
        result=json.loads(child.stdout.split(FRAME,1)[1].splitlines()[0])
        if child.returncode or result.get('result')!='PASS':
            if result.get('phase') in {'input','prepare','online','offline','audit'}:report['runner_phase']=result['phase']
            if type(result.get('probe_line')) is int:report['runner_line']=result['probe_line']
            if isinstance(result.get('diagnostic'),dict):report['runner_state']=result['diagnostic']
            if isinstance(result.get('span_reasons'),list):report['span_reasons']=result['span_reasons']
            if isinstance(result.get('flow'),list):report['flow']=result['flow']
            if result.get('reason') in {'not_entitled','auth_expired','rate_limited','service_rejected','session_changed',
                    'catalog_changed','unavailable','invalid_source','invalid_image','remote_unsupported','storage'}:
                report['runner_reason']=result['reason']
            if type(result.get('profile_removed')) is bool:report['temporary_profile_removed']=result['profile_removed']
            raise ValueError('reader')
        if (set(result)!={'result','rows','offline_reopen','credential_file_audit','installed_bytes_match','profile_removed'}
                or not all(result[key] is True for key in ('offline_reopen','credential_file_audit','installed_bytes_match','profile_removed'))
                or not verify_rows(source['source'],before,uid,result['rows'],args.thoughts)):raise ValueError('row_mismatch')
        phase='final';web.verify_account()
        if reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+book),book)!=before_web \
                or notes.observe(credentials,'direct_personal_final')!=before:raise ValueError('account_changed')
        save_refreshed_web_session(session,saved,web)
        report.update(result='DIRECT_PERSONAL_OWNER_VERIFIED',variant='thoughts' if args.thoughts else 'marks',native_web_source_matches=True,
            independent_quotes_match=True,offline_reopen=True,original_cloud_state_unchanged=True,web_position_unchanged=True,
            credential_file_audit=True,temporary_profile_removed=True,installed_bytes_match=True)
        if args.thoughts:
            report.update(visible_thoughts=len(result['rows']),chapter_thoughts=len(rows),
                all_chapter_thoughts_displayed={row['id'] for row in result['rows']}=={row['reviewId'] for row in rows},
                popup_contents_independently_matched=True)
        else:
            report.update(visible_marks=len(result['rows']),chapter_highlights=len(rows),
                all_chapter_highlights_displayed={row['id'] for row in result['rows']}=={row['bookmarkId'] for row in rows})
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase)
        if str(error) in {'no_eligible_marked_chapter','source_changed','baseline_changed','row_mismatch','account_changed'}:report['reason']=str(error)
        elif 'HTTP 401' in str(error):report['reason']='auth_expired'
        elif 'HTTP 429' in str(error):report['reason']='rate_limited'
    finally:
        if web:web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
