#!/usr/bin/env python3
"""Bounded, read-only owner footnote samples; private data crosses memory pipes.

Default is offline. No renewal, account-data write, file output or credentials
in the Lua payload. The existing guarded catalog/content protocol is reused.
"""
import argparse
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
import re
import resource
import subprocess
import time
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards, make_content_params, normalize_chapter_infos, read_reader_state, reader_url_for
from secure_weread_session import SessionStore, StoreError
from verify_owner_reading import reading_position
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, identifier, versions

FRAME=b'\nWEREAD_OWNER_FOOTNOTE_LINK_RESULT='
FIELDS=('chapterUid','chapterIdx','index','href','file','filename','fileName','path','chapterPath')
COUNTS={'catalog_chapters','sampled_chapters','anchors','links','same_chapter_ready','cross_chapter_ready',
        'cross_chapter_plans','external_links','unresolved_links','chapters_with_file_metadata',
        'image_notes','converted_notes','conversion_fallbacks','valid_converted_chapters',
        'native_opened_chapters','native_popup_checks','native_jump_checks','native_back_checks','native_error_code','native_failure_stage','native_plugin_checks','native_expected_bytes','native_actual_bytes','native_expected_nbsp','native_expected_zwsp','native_expected_zwnj','native_expected_zwj','converted_text_matches','native_actual_nbsp','native_whitespace_normalizations','native_actual_soft_hyphens','native_expected_soft_hyphens','native_hyphenation_normalizations','chapters_with_resolved_paths','source_path_aliases','shared_source_paths'}
LIMIT=32*1024*1024


class Text(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.parts=[]
    def handle_data(self,value):self.parts.append(value)


class Scan(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links=[];self.ids=[];self.noterefs=0;self.media=0;self.image_notes=0;self.note_markers=0;self.expected_notes=[]
    def handle_starttag(self,tag,attrs):
        values=dict(attrs)
        if values.get('id') is not None:self.ids.append(values['id'])
        if tag=='a' and values.get('href') is not None:
            self.links.append(values['href'])
            if 'noteref' in (values.get('epub:type') or '').split():self.noterefs+=1
        if tag in ('img','svg','math','table'):self.media+=1
        classes=(values.get('class') or '').lower()
        if 'footnote' in classes or 'noteref' in classes or any('footnote' in key for key in values):self.note_markers+=1
        if tag=='img' and (set(classes.split()) & {'qqreader-footnote','footnote-icon','footnote-ref','note-ref'} or classes=='footnote'):
            note=next((values.get(key) for key in ('alt','title','data-content','data-note') if values.get(key)),None)
            if note:
                self.image_notes+=1
                plain=Text();plain.feed(note)
                value=re.sub(r'^\s*(?:\[\s*\d+\s*\]|\(\s*\d+\s*\)|（\s*\d+\s*）|\*+|[†‡※])\s*','', ''.join(plain.parts)).strip()
                self.expected_notes.append(value)
    handle_startendtag=handle_starttag


def projected_catalog(chapters):
    if not isinstance(chapters,list) or not 1<=len(chapters)<=10000:raise PreflightError('catalog_invalid')
    result=[];seen=set()
    for chapter in chapters:
        if not isinstance(chapter,dict):raise PreflightError('catalog_invalid')
        uid=identifier(chapter.get('chapterUid'))
        if uid in seen:raise PreflightError('catalog_ambiguous')
        seen.add(uid);item={}
        for key in FIELDS:
            value=chapter.get(key)
            if value is None:continue
            if type(value) not in (str,int) or isinstance(value,str) and len(value)>8192:raise PreflightError('catalog_invalid')
            item[key]=value
        files=chapter.get('files',[])
        if not isinstance(files,list) or len(files)>2048 or any(not isinstance(v,str) or len(v)>8192 for v in files):raise PreflightError('catalog_invalid')
        item['files']=files.copy();result.append(item)
    return result


def selection_bounds(maximum,offset,cap,limit):
    if type(maximum) is not int or not 1<=maximum<=cap or type(offset) is not int or not 0<=offset<limit:raise PreflightError('selection_invalid')


def offset_argument(limit):
    def parse(value):
        if not isinstance(value,str) or not re.fullmatch(r'[0-9]{1,4}',value) or int(value)>=limit:
            raise argparse.ArgumentTypeError('expected an integer between 0 and '+str(limit-1))
        return int(value)
    return parse


def candidates(shelf,maximum,offset=0):
    selection_bounds(maximum,offset,8,5000)
    rows=shelf.get('books') if isinstance(shelf,dict) else None
    if not isinstance(rows,list) or len(rows)>5000:raise PreflightError('shelf_invalid')
    seen=set();weighted=[]
    for row in rows:
        for _i in range(4):
            if not isinstance(row,dict):break
            nested=row.get('bookInfo',row.get('book'))
            if not isinstance(nested,dict):break
            row=nested
        if not isinstance(row,dict) or row.get('type') in (1,2) or row.get('format') not in (None,'epub'):continue
        try:uid=identifier(row.get('bookId'))
        except PreflightError:continue
        if uid not in seen:
            seen.add(uid)
            title=row.get('title') if isinstance(row.get('title'),str) else ''
            score=bool(re.search(r'古文|史记|文言|诗词|译注|注释|楚辞|论语|庄子|唐诗|宋词|文选|左传|资治',title))
            weighted.append((not score,len(weighted),uid))
    return [value[2] for value in sorted(weighted)[offset:offset+maximum]]


def select_chapters(chapters,progress,maximum,offset=0):
    selection_bounds(maximum,offset,4,10000)
    readable=[row for row in chapters if type(row.get('wordCount')) in (int,float) and row['wordCount']>0 and row.get('title')!='封面']
    selected=[];seen=set()
    def add(row):
        if row and id(row) not in seen:
            seen.add(id(row));selected.append(row)
    current=str(progress.get('chapter','')) if isinstance(progress,dict) else ''
    add(next((row for row in readable if str(row.get('chapterUid'))==current),None))
    for row in readable:
        if re.search(r'注释|注解|译注|尾注|notes?',str(row.get('title','')),re.I):add(row)
    for row in readable:add(row)
    return selected[offset:offset+maximum]


def decode_result(raw,payload):
    if not isinstance(raw,bytes) or len(raw)>65536 or raw.count(FRAME)!=1:raise PreflightError('lua_result_invalid')
    encoded=raw.split(FRAME,1)[1]
    try:value=json.loads(encoded)
    except (ValueError,UnicodeError):raise PreflightError('lua_result_invalid') from None
    if not isinstance(value,dict) or set(value)!=COUNTS|{'result'} or value['result']!='PASS':raise PreflightError('lua_result_invalid')
    if any(type(value[key]) is not int or not 0<=value[key]<=1000000 for key in COUNTS):raise PreflightError('lua_result_invalid')
    if value['catalog_chapters']!=len(payload['chapters']) or value['sampled_chapters']!=len(payload['samples']):raise PreflightError('lua_result_invalid')
    if sum(value[key] for key in ('same_chapter_ready','cross_chapter_ready','cross_chapter_plans','external_links','unresolved_links'))!=value['links']:raise PreflightError('lua_result_invalid')
    return value


class Probe(WebSourceProbe):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.calls=0;self.private_bytes=0
    def request(self,stage,url,body=None,**kwargs):
        self.calls+=1
        if self.calls>192:raise PreflightError('request_limit')
        try:return super().request(stage,url,body,**kwargs)
        finally:time.sleep(.15)
    def inspect_book(self,book_id,maximum,chapter_offset=0):
        selection_bounds(maximum,chapter_offset,4,10000)
        self.book_id=identifier(book_id);self.chapter=None
        progress_url=BASE+'/web/book/getProgress?'+urlencode({'bookId':self.book_id})
        before=reading_position(self.request('progress_before',progress_url),self.book_id,allow_unstarted=True)
        record,chapters=normalize_chapter_infos(self.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[self.book_id]}),self.book_id)
        catalog=projected_catalog(chapters);samples=[];scans=[]
        for chapter in select_chapters(chapters,before,maximum,chapter_offset):
            self.chapter=identifier(chapter['chapterUid'])
            state=read_reader_state(self.request('reader',reader_url_for(self.book_id,self.chapter),as_json=False))
            if state.book_id!=self.book_id or str(state.current_chapter.get('chapterUid'))!=self.chapter or not state.psvts:raise PreflightError('reader_source_scope_mismatch')
            params=make_content_params(self.book_id,self.chapter,state.psvts,sc=1)
            first=self.request('e_0',BASE+'/web/book/chapter/e_0',params,as_json=False)
            if first.lstrip().startswith('{'):raise PreflightError('non_xhtml_source')
            raw=decode_content_shards(first,*(self.request(key,BASE+'/web/book/chapter/'+key,params,as_json=False) for key in ('e_1','e_3')))
            if not raw.lstrip().startswith('<'):raise PreflightError('non_xhtml_source')
            self.private_bytes+=len(raw.encode())
            if self.private_bytes>LIMIT:raise PreflightError('source_limit')
            scan=Scan();scan.feed(raw);scans.append(scan)
            samples.append({'uid':self.chapter,'html':raw,'expected_notes':scan.expected_notes})
        later,later_chapters=normalize_chapter_infos(self.request('catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[self.book_id]}),self.book_id)
        after=reading_position(self.request('progress_after',progress_url),self.book_id,allow_unstarted=True)
        if projected_catalog(later_chapters)!=catalog or versions(later)!=versions(record):raise PreflightError('catalog_changed')
        if before!=after:raise PreflightError('progress_changed')
        if not samples:raise PreflightError('no_readable_sample')
        return {'chapters':catalog,'samples':samples},dict(chapters=len(samples),links=sum(len(s.links) for s in scans),
            note_references=sum(s.noterefs for s in scans),media_elements=sum(s.media for s in scans),
            image_note_payloads=sum(s.image_notes for s in scans),note_markers=sum(s.note_markers for s in scans),
            fragment_links=sum(href.startswith('#') for s in scans for href in s.links),
            foreign_file_links=sum(bool(href.split('#',1)[0]) and not re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:|^//',href) for s in scans for href in s.links))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--max-books',type=int,choices=range(1,9),default=4)
    parser.add_argument('--chapters-per-book',type=int,choices=range(1,5),default=4)
    parser.add_argument('--book-offset',type=offset_argument(5000),default=0,metavar='0..4999')
    parser.add_argument('--chapter-offset',type=offset_argument(10000),default=0,metavar='0..9999')
    parser.add_argument('--native',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.native and not args.lua_command:parser.error('--native requires --lua-command')
    if args.lua_command and not args.saved_session:parser.error('--lua-command requires --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),samples=[],
        account_data_writes_attempted=0,authentication_posts_attempted=0,private_data_on_regular_disk=False,
        book_offset=args.book_offset,chapter_offset=args.chapter_offset)
    probe=saved=store=None;reason=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            store=SessionStore();saved=store.load();probe=Probe();probe.vid=saved['vid']
            for key,value in saved['cookies'].items():probe.set_cookie(key,value)
            probe.verify_account()
            books=candidates(probe.request('shelf',BASE+'/web/shelf/sync'),args.max_books,args.book_offset)
            for book_id in books:
                payload,summary=probe.inspect_book(book_id,args.chapters_per_book,args.chapter_offset)
                if args.lua_command:
                    encoded=json.dumps(payload,ensure_ascii=False).encode()
                    if len(encoded)>LIMIT:raise PreflightError('source_limit')
                    child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=240 if args.native else 90)
                    if child.returncode:
                        try:
                            failure=json.loads(child.stdout)
                            counters=failure.get('counters') if isinstance(failure,dict) else None
                            if isinstance(counters,dict):report['native_last_result']=decode_result(FRAME+json.dumps(counters).encode(),payload)
                        except (ValueError,PreflightError):pass
                        raise PreflightError('lua_failed')
                    result=decode_result(child.stdout,payload)
                    if result['native_error_code']:report['native_last_result']=result
                    if args.native and (result['native_error_code'] or result['native_popup_checks']!=summary['image_note_payloads'] or result['native_jump_checks']!=summary['image_note_payloads'] or result['native_back_checks']!=summary['image_note_payloads']):raise PreflightError('native_note_mismatch')
                    if result['valid_converted_chapters']!=summary['chapters']:raise PreflightError('conversion_invalid')
                    if result['links']!=summary['links']:raise PreflightError('link_count_mismatch')
                    summary['lua']=result
                report['samples'].append(summary)
                payload.clear()
            report.update(result='PASS' if report['samples'] else 'NO_SAMPLE',books=len(report['samples']))
    except Exception as exc:
        safe={'http_rejected','api_rejected','catalog_changed','progress_changed','reader_source_scope_mismatch','non_xhtml_source',
              'connection_failed','request_timed_out','response_or_connection_invalid','catalog_invalid','catalog_ambiguous','source_limit','request_limit','no_readable_sample','lua_result_invalid','lua_failed','link_count_mismatch','native_note_mismatch','conversion_invalid'}
        reason=str(exc) if isinstance(exc,PreflightError) and str(exc) in safe else 'probe_failed'
        report.update(result='FAILED',reason=reason)
        stages=probe.report['stages'] if probe else []
        stage=stages[-1].get('stage') if stages else None
        if stage in {'account','shelf','progress_before','progress_after','catalog_before','catalog_after','reader','e_0','e_1','e_3'}:report['failure_stage']=stage
    finally:
        if probe:
            if probe.authenticated:
                try:
                    probe.verify_account()
                    report['rotated_cookies_saved']=save_refreshed_web_session(store,saved,probe)
                except Exception:report.update(result='FAILED',reason='final_account_unverified')
            report['http_statuses']=[row.get('status',0) for row in probe.report['stages']]
            report['request_count']=probe.calls
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('PASS','OFFLINE_ONLY') else 1


if __name__=='__main__':raise SystemExit(main())
