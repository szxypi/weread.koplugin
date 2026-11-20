#!/usr/bin/env python3
"""Validate a read-only cloud source target; offline unless --saved-session.

Positions, source and credentials stay in memory. A verified snapshot may be
matched to an EPUB's identical source; it never grants wire upload permission.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import subprocess
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards,make_content_params,read_reader_state,reader_url_for
from secure_weread_session import SessionStore,StoreError
from verify_source_coordinates import CoordinateError,FilteredSource
from verify_web_source_progress import BASE,PreflightError,WebSourceProbe as BaseProbe,identifier,position

MAX_SOURCE=2*1024*1024


class WebSourceProbe(BaseProbe):
    def guard(self,stage,url,body):
        if stage in ('t_0','t_1') and url==BASE+'/web/book/chapter/'+stage:
            return super().guard('e_0',BASE+'/web/book/chapter/e_0',body)
        return super().guard(stage,url,body)


def checked_position(value,book_id):
    node=value
    for _i in range(4):
        if not isinstance(node,dict):break
        if any(type(node.get(key)) is bool or node.get(key,0) not in (0,None,'0') for key in ('errcode','errCode')) or ('succ' in node and node['succ'] not in (True,1,'1')):
            raise PreflightError('cloud_position_invalid')
        node=node.get('book',node.get('data',node.get('result')))
    return position(value,book_id)


def check_reader(book_id,first,reader):
    if (not isinstance(reader,dict) or not isinstance(reader.get('bookInfo'),dict)
            or identifier(reader['bookInfo'].get('bookId'))!=book_id
            or not isinstance(reader.get('currentChapter'),dict)
            or identifier(reader['currentChapter'].get('chapterUid'))!=first['chapter']):
        raise PreflightError('cloud_reader_mismatch')
    if checked_position(reader.get('progress'),book_id)!=first:raise PreflightError('cloud_reader_mismatch')


def project(book_id,before,reader,source,after,source_format='web_xhtml'):
    book_id=identifier(book_id)
    first,last=checked_position(before,book_id),checked_position(after,book_id)
    if first!=last:raise PreflightError('cloud_target_changed')
    check_reader(book_id,first,reader)
    if not isinstance(source,str) or not 0<len(source.encode())<=MAX_SOURCE:raise PreflightError('cloud_source_invalid')
    try:
        if source_format=='web_txt':
            from txt_coordinates import PlainSource
            model=PlainSource(source)
            if not model.visible:raise CoordinateError('target mismatch')
            positions=[model.starts[i] for i in model.visible]+[model.ends[model.visible[-1]]]
            if first['offset'] not in positions:raise CoordinateError('target mismatch')
            at=positions.index(first['offset'])
            if model.locate_point(model.flat,at)!=first['offset']:raise CoordinateError('target mismatch')
        elif source_format=='web_xhtml':
            model=FilteredSource(source)
            anchor=model.anchor_at(first['offset'])
            if model.locate(anchor)[0]!=first['offset']:raise CoordinateError('target mismatch')
        else:raise CoordinateError('source format')
    except CoordinateError:raise PreflightError('cloud_target_unavailable') from None
    return dict(book_id=book_id,chapter_uid=first['chapter'],chapter_offset=first['offset'],percent=first['percent'],
                raw_sha256=hashlib.sha256(source.encode()).hexdigest(),raw_bytes=len(source.encode()),
                basis='raw_txt_utf16' if source_format=='web_txt' else 'filtered_xhtml_utf16',upload_verified=False)


def inspect(probe,book_id):
    probe.book_id=identifier(book_id)
    url=BASE+'/web/book/getProgress?'+urlencode(dict(bookId=probe.book_id))
    before=probe.request('progress_before',url)
    first=checked_position(before,probe.book_id)
    probe.chapter=first['chapter']
    try:state=read_reader_state(probe.request('reader',reader_url_for(probe.book_id,probe.chapter),as_json=False))
    except Exception:raise PreflightError('cloud_reader_invalid') from None
    reader=state.initial_state.get('reader')
    if (state.book_id!=probe.book_id or not isinstance(state.psvts,str) or not 0<len(state.psvts)<=8192
            or any(ord(c)<33 or ord(c)>126 for c in state.psvts)):
        raise PreflightError('cloud_reader_invalid')
    check_reader(probe.book_id,first,reader)
    params=make_content_params(probe.book_id,probe.chapter,state.psvts,sc=1)
    try:
        e0=probe.request('e_0',BASE+'/web/book/chapter/e_0',params,as_json=False)
        source_format='web_xhtml'
        if e0.lstrip().startswith('{'):
            from verify_txt_reading import fallback_marker
            if not fallback_marker(e0,probe.book_id,probe.chapter):raise PreflightError('cloud_source_invalid')
            source_format='web_txt'
            parts=[probe.request(name,BASE+'/web/book/chapter/'+name,params,as_json=False) for name in ('t_0','t_1')]+['']
        else:parts=[e0]+[probe.request(name,BASE+'/web/book/chapter/'+name,params,as_json=False) for name in ('e_1','e_3')]
        source=decode_content_shards(*parts)
    except PreflightError:raise
    except Exception:raise PreflightError('cloud_source_invalid') from None
    after=probe.request('progress_after',url)
    target=project(probe.book_id,before,reader,source,after,source_format)
    # Only the relevant Reader fields cross the private comparison pipe.
    sample=dict(book_id=probe.book_id,before=before,after=after,source=source,
                reader={name:reader[name] for name in ('bookInfo','currentChapter','progress')},expected=target,source_format=source_format)
    return target,sample


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-id')
    parser.add_argument('--official-parser',action='store_true')
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if ((args.book_id or args.official_parser or args.lua_command or args.native_http) and not args.saved_session
            or args.native_http and not args.lua_command):
        parser.error('online options require --saved-session; --native-http requires --lua-command last')
    if args.book_id:
        try:identifier(args.book_id)
        except PreflightError:parser.error('invalid book identity')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_writes_attempted=0,
                private_source_saved=False,credentials_written_to_files=False,precision_upload_enabled=False)
    probe=None;saved=None
    try:
        if not args.saved_session:
            raw='<html><body><p>This is a unique offline source target.</p></body></html>'
            book='900001';point=dict(bookId=book,chapterUid=2,chapterOffset=15,progress=20)
            value=project(book,dict(book=point),dict(bookInfo=dict(bookId=book),currentChapter=dict(chapterUid=2),progress=dict(book=point)),raw,dict(book=point))
            assert value['upload_verified'] is False
            report['network_requests']=0
        else:
            store=SessionStore();saved=store.load();probe=WebSourceProbe()
            probe.vid=identifier(saved['vid'])
            for key,value in saved['cookies'].items():probe.set_cookie(key,value)
            saved.clear();probe.verify_account()
            target,sample=inspect(probe,args.book_id or probe.select_shelf_book())
            report.update(snapshot_consistent=True,embedded_position_matches=True,source_target_roundtrip=True,
                          local_epub_requires_identical_source=True)
            probe.verify_account();store.save(probe)
            report.update(same_owner_rechecked=True,keychain_readback_verified=True)
            if args.official_parser:
                if target['basis']!='filtered_xhtml_utf16':raise PreflightError('cloud_parser_format_unavailable')
                from source_parser_preflight import verify_source
                checked=verify_source(sample['source'],target['chapter_offset'])
                if not checked.get('official_parser_target_present'):raise PreflightError('cloud_parser_target_unverified')
                report.update(official_parser_target_present=True,official_parser_nodes=checked.get('official_parser_source_nodes'))
            if args.lua_command:
                payload=dict(sample=sample)
                if args.native_http:
                    payload['credentials']=dict(vid=probe.vid,cookies={cookie.name:cookie.value for cookie in probe.cookies})
                encoded=json.dumps(payload,ensure_ascii=False).encode()
                if len(encoded)>8*1024*1024:raise PreflightError('cloud_probe_input_limit')
                child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
                frame=b'\nWEREAD_CLOUD_TARGET_RESULT='
                if child.returncode or len(child.stdout)>1024*1024 or child.stdout.count(frame)!=1:raise PreflightError('cloud_lua_probe_failed')
                value=json.loads(child.stdout.split(frame)[1])
                if value.get('model')!=target:raise PreflightError('cloud_lua_projection_mismatch')
                report['lua_projection_matches']=True
                if args.native_http:
                    if value.get('native')!=target or value.get('requests')!=6:raise PreflightError('cloud_native_readback_mismatch')
                    report.update(native_https_projection_matches=True,native_read_requests=6)
            report.update(result='CLOUD_SOURCE_READ_TARGET_VERIFIED',stages=probe.report['stages'])
    except (StoreError,PreflightError) as exc:report.update(result='UNVERIFIED',reason=str(exc))
    except KeyboardInterrupt:report.update(result='UNVERIFIED',reason='cancelled')
    except Exception:report.update(result='UNVERIFIED',reason='cloud_target_verification_failed')
    finally:
        if probe:probe.close()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','CLOUD_SOURCE_READ_TARGET_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
