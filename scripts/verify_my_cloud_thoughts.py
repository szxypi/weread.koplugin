#!/usr/bin/env python3
"""Own-thought GET prototype; offline by default, no writes or renewal.

All raw content, identifiers, cursors and credentials remain in memory. Only
bounded counts, type information and scope checks enter the public report.
"""
import argparse
from datetime import datetime,timezone
import json
from urllib.parse import urlencode
import time
import subprocess

from my_cloud_thoughts_model import page,complete,ThoughtsError
from personal_notes_position import unchanged,response_clock_matches
from run_my_cloud_marks_ui import native_budget

from my_cloud_marks_model import identifier,integer
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import NativeProbe,BASE
from verify_eink_readtime import validate_position

FIELDS={'reviews','review','book','author','bookId','book_id','userVid','vid','reviewId','content','htmlContent','abstract',
        'chapterName','chapterUid','chapterIdx','range','type','createTime','star','isPrivate','isFinish','totalCount',
        'hasMore','reviewsHasMore','reviewsCnt','recentTotalCnt','synckey','idx','errcode','errCode','succ'}


def shape(value,depth=0):
    if isinstance(value,dict):return {k:shape(v,depth+1) for k,v in value.items() if k in FIELDS} if depth<4 else 'object'
    if isinstance(value,list):return ['array',len(value),shape(value[0],depth+1) if value else 'empty']
    return 'null' if value is None else type(value).__name__


def inspect_scope(source,identity,owner):
    if not isinstance(source,dict) or not isinstance(source.get('reviews'),list) or len(source['reviews'])>5000:raise ValueError('thought_rows')
    report=dict(rows=len(source['reviews']),books_match=True,owners_match=True,book_fields=0,owner_fields=0)
    def visit(value,depth=0):
        if not isinstance(value,dict) or depth>4:return
        for key in ('bookId','book_id'):
            if value.get(key) is not None:
                report['book_fields']+=1;report['books_match'] &= str(value[key])==identity
        for key in ('userVid','vid'):
            if value.get(key) is not None:
                report['owner_fields']+=1;report['owners_match'] &= str(value[key])==owner
        for key in ('review','book','author'):visit(value.get(key),depth+1)
    for row in source['reviews']:visit(row)
    return report


class ThoughtsProbe(NativeProbe):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.identity=None;self.source=None;self.before=None;self.calls=0;self.samples=[];self.owner=None;self.page_probe=False;self.select_empty=False

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        fixed=dict(shelf=BASE+'/shelf/sync',notebooks=BASE+'/user/notebooks?count=100')
        if self.identity:
            for count in (1,2,20,40,80,160,320,640,1280,2560,5000):fixed['thoughts_'+str(count)]=BASE+'/review/list?'+urlencode(dict(bookId=self.identity,listType=11,listMode=0,mine=1,synckey=0,count=count))
            fixed.update(
                         progress_before=BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity)),
                         progress_after=BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity)))
        if body is not None or stage not in fixed or url!=fixed[stage] or self.calls>=(15 if self.page_probe else 13):raise ValueError('thought_scope')
        self.calls+=1;return super().request(stage,url,body,credentials,timeout)

    def prepare(self,credentials):
        self.owner=credentials['vid']
        shelf=self.request('shelf',BASE+'/shelf/sync',credentials=credentials)
        notebooks=self.request('notebooks',BASE+'/user/notebooks?count=100',credentials=credentials)
        if (not isinstance(shelf.get('books'),list) or len(shelf['books'])>5000 or not isinstance(notebooks.get('books'),list) or len(notebooks['books'])>5000):raise ValueError('thought_books')
        ids={str(row.get('bookId')) for row in shelf['books'] if isinstance(row,dict) and identifier(str(row.get('bookId')))}
        choices=[]
        for row in notebooks['books']:
            if not isinstance(row,dict):raise ValueError('thought_notebook')
            book=row.get('book',row);identity=str(book.get('bookId')) if isinstance(book,dict) else None
            count=row.get('reviewCount',0)
            if identity in ids and row.get('bookId') is not None and str(row['bookId'])!=identity:raise ValueError('thought_notebook')
            if not integer(count,100000):raise ValueError('thought_notebook')
            if identity in ids and (count==0 if self.select_empty else count>0):choices.append((count,identity))
        if not choices:raise ValueError('thought_empty_selection')
        declared,self.identity=sorted(choices,key=lambda row:(-row[0],row[1]))[0]
        before_started=time.time()
        self.before=self.request('progress_before',BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity)),credentials=credentials)
        before_finished=time.time()
        validate_position(self.before,self.identity)
        self.source=self.request('thoughts_20',BASE+'/review/list?'+urlencode(dict(bookId=self.identity,listType=11,listMode=0,mine=1,synckey=0,count=20)),credentials=credentials)
        current=page(self.source,self.identity,credentials['vid']);count=20
        while current['has_more']:
            if count>=5000:raise ValueError('thought_incomplete')
            count=min(5000,count*2)
            raw=self.request('thoughts_'+str(count),BASE+'/review/list?'+urlencode(dict(bookId=self.identity,listType=11,listMode=0,mine=1,synckey=0,count=count)),credentials=credentials)
            projected=page(raw,self.identity,credentials['vid'])
            if (projected['total_count']!=current['total_count'] or len(projected['reviews'])<=len(current['reviews'])
                    or projected['reviews'][:len(current['reviews'])]!=current['reviews']):raise ValueError('thought_prefix')
            self.source=raw;current=projected
        report=inspect_scope(self.source,self.identity,credentials['vid']);report['declared_count_matches']=report['rows']==declared
        report['shape']=shape(self.source)
        result=complete(self.source,self.identity,credentials['vid'],int(time.time()))
        self.samples=[dict(source=self.source,book_id=self.identity,owner=credentials['vid'],now=result['fetched_at'],expected=result)]
        if self.page_probe:
            reports=[]
            for count in (1,2):
                raw=self.request('thoughts_'+str(count),BASE+'/review/list?'+urlencode(dict(bookId=self.identity,listType=11,listMode=0,mine=1,synckey=0,count=count)),credentials=credentials)
                self.last_page=dict(rows=len(raw.get('reviews',[])) if isinstance(raw.get('reviews'),list) else 0,
                    total=raw.get('totalCount') if integer(raw.get('totalCount'),5000) else None,
                    more=raw.get('hasMore') if type(raw.get('hasMore')) in (int,bool) and raw.get('hasMore') in (0,1) else None)
                projected=page(raw,self.identity,credentials['vid'])
                prefix=projected['reviews']==result['reviews'][:len(projected['reviews'])]
                reports.append(dict(requested=count,returned=len(projected['reviews']),total=projected['total_count'],has_more=projected['has_more'],reported_has_more=bool(raw['hasMore']),prefix_matches=prefix))
                if not prefix:raise ValueError('thought_prefix')
                self.samples.append(dict(source=raw,book_id=self.identity,owner=credentials['vid'],now=result['fetched_at'],expected_page=projected))
            report['prefix_probes']=reports
            # Force a response-clock boundary; coordinates/state must still match.
            time.sleep(1.1)
        after_started=time.time()
        after=self.request('progress_after',BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity)),credentials=credentials)
        after_finished=time.time()
        report['response_clock_verified']=response_clock_matches(self.before,before_started,before_finished) and response_clock_matches(after,after_started,after_finished)
        if not report['response_clock_verified']:raise ValueError('thought_position_clock')
        validate_position(after,self.identity);report['position_unchanged']=unchanged(self.before,after,self.identity)
        report['response_timestamp_changed']=self.before.get('timestamp')!=after.get('timestamp')
        keys=('bookId','chapterUid','chapterIdx','chapterOffset','progress','summary','updateTime','readUpdateTime','synckey','readingTime','timestamp','time','ts')
        self.position_diagnostic={}
        for level in ('root','book','progress'):
            left,right=(self.before,after) if level=='root' else (self.before.get(level),after.get(level))
            if isinstance(left,dict) and isinstance(right,dict):
                self.position_diagnostic[level]={key:left.get(key)==right.get(key) and (key in left)==(key in right) for key in keys if key in left or key in right}
                self.position_diagnostic[level]['changed_other_fields']=sum(left.get(key)!=right.get(key) or (key in left)!=(key in right) for key in set(left)|set(right) if key not in keys and key not in ('book','progress'))
        report['position_field_checks']=self.position_diagnostic
        if not report['position_unchanged']:raise ValueError('thought_position_changed')
        if not report['books_match'] or not report['owners_match'] or report['rows']>0 and (not report['book_fields'] or not report['owner_fields']):raise ValueError('thought_response_scope')
        return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--page-probe',action='store_true');parser.add_argument('--select-empty',action='store_true')
    parser.add_argument('--native-http',action='store_true');parser.add_argument('--native-ui',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session or args.native_http and not args.lua_command or args.native_ui and not args.native_http:parser.error('use saved-session with Lua command; native-ui requires native-http')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,private_values_saved=False)
    credentials=probe=None
    try:
        if args.saved_session:
            credentials=NativeSessionStore().load(SessionStore().load()['vid']);probe=ThoughtsProbe();probe.page_probe=args.page_probe;probe.select_empty=args.select_empty
            report.update(probe.prepare(credentials),result='MY_CLOUD_THOUGHTS_READ_VERIFIED')
            if args.lua_command:
                selected=probe.samples[0]
                payload=dict(source=selected['source'],book_id=probe.identity,owner=credentials['vid'],now=selected['now'],variant='thoughts')
                if args.native_http:payload['credentials']=credentials
                child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=120)
                frame=b'\nWEREAD_MY_MARKS_RESULT='
                if len(child.stdout)>12*1024*1024 or child.stdout.count(frame)!=1:raise ValueError('thought_lua')
                actual=json.loads(child.stdout.split(frame)[1])
                if isinstance(actual.get('ui'),dict):
                    report['ui_diagnostics']=[{k:r[k] for k in ('failed_line','requests','forbidden','pages','quotes')
                        if type(r.get(k)) is int and 0<=r[k]<=100000} for r in actual['ui'].get('stages',[])[:2] if isinstance(r,dict)]
                if child.returncode or actual.get('model')!=selected['expected']:raise ValueError('thought_lua')
                report['lua_model_matches']=True
                if args.native_http:
                    if actual.get('native')!=selected['expected'] or actual.get('requests')!=native_budget(len(selected['expected']['reviews'])):raise ValueError('thought_native')
                    report.update(native_https_matches=True,native_gets=actual['requests'])
                if args.native_ui:
                    from run_my_cloud_marks_ui import validate_stage
                    ui=actual['ui']
                    if (set(ui)!={'result','profile_removed','installed_bytes_match','installed_files','stages'} or ui['result']!='PASS'
                            or ui['profile_removed'] is not True or ui['installed_bytes_match'] is not True
                            or type(ui['installed_files']) is not int or not 1<=ui['installed_files']<=1000
                            or not isinstance(ui['stages'],list) or len(ui['stages'])!=2):raise ValueError('thought_ui')
                    for row,mode in zip(ui['stages'],('live','reopen')):validate_stage(row,mode,len(selected['expected']['reviews']),thoughts=True)
                    report['ui']=ui
    except Exception as error:
        report.update(result='UNVERIFIED',reason=str(error) if str(error) in {'thought_rows','thought_books','thought_notebook',
            'thought_empty_selection','thought_response_scope','thought_scope','thought_position_changed','thought_prefix','thought_incomplete','thought_lua','thought_native','thought_ui','thought_position_clock'} else 'thought_probe_failed')
        if probe and hasattr(probe,'position_diagnostic'):report['position_field_checks']=probe.position_diagnostic
        if isinstance(error,ThoughtsError):report['model_error']=str(error)
        if probe and hasattr(probe,'last_page'):report['page_diagnostic']=probe.last_page
        if probe and probe.source is not None:
            try:report.update(inspect_scope(probe.source,probe.identity,credentials['vid']),shape=shape(probe.source))
            except Exception:report['response_shape_invalid']=True
    finally:
        if credentials:credentials.clear()
        if probe:
            report['stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in probe.report['stages']]
            probe.source=probe.before=None;probe.samples.clear()
    print(json.dumps(report,indent=2));return 0 if report['result']!='UNVERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
