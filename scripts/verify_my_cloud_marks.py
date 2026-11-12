#!/usr/bin/env python3
"""Own cloud highlights/bookmarks: GET only; offline without --saved-session.

Raw text, identifiers and credentials stay in memory/captured pipes. This does
not read public heat-map annotations or claim the unverified own-thought API.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess
import time
from urllib.parse import urlencode

from my_cloud_marks_model import project,identifier,integer
from personal_notes_position import unchanged,response_clock_matches
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import NativeProbe,BASE
from verify_eink_readtime import validate_position


class MarksProbe(NativeProbe):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.identity=None;self.source=None;self.model=None;self.book=None;self.baseline=None;self.calls=0

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        fixed={'shelf':BASE+'/shelf/sync','notebooks':BASE+'/user/notebooks?count=100'}
        if self.identity:
            fixed.update(marks=BASE+'/book/bookmarklist?'+urlencode(dict(bookId=self.identity,synckey=0)),
                         progress_before=BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity)),
                         progress_after=BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity)))
        if body is not None or stage not in fixed or url!=fixed[stage] or self.calls>=5:raise ValueError('my_marks_request_scope')
        self.calls+=1;return super().request(stage,url,body,credentials,timeout)

    def prepare(self,credentials):
        shelf=self.request('shelf',BASE+'/shelf/sync',credentials=credentials)
        notebooks=self.request('notebooks',BASE+'/user/notebooks?count=100',credentials=credentials)
        if not isinstance(shelf.get('books'),list) or not isinstance(notebooks.get('books'),list) or len(notebooks['books'])>5000:raise ValueError('my_marks_books')
        lookup={str(row.get('bookId')):row for row in shelf['books'] if isinstance(row,dict) and identifier(str(row.get('bookId')))}
        choices=[]
        for row in notebooks['books']:
            if not isinstance(row,dict):raise ValueError('my_marks_notebook')
            book=row.get('book',row);identity=str(book.get('bookId')) if isinstance(book,dict) else None
            if identity not in lookup:continue
            if row.get('bookId') is not None and str(row['bookId'])!=identity:raise ValueError('my_marks_notebook_scope')
            counts=[row.get(name,0) for name in ('noteCount','bookmarkCount')]
            if any(not integer(value,100000) for value in counts):raise ValueError('my_marks_notebook_count')
            choices.append((sum(counts),identity))
        if not choices:raise ValueError('my_marks_empty_selection')
        declared,self.identity=sorted(choices,key=lambda row:(-row[0],row[1]))[0]
        self.book=lookup[self.identity]
        before_started=time.time()
        before=self.request('progress_before',BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity)),credentials=credentials)
        before_finished=time.time()
        validate_position(before,self.identity)
        self.baseline=before
        self.source=self.request('marks',BASE+'/book/bookmarklist?'+urlencode(dict(bookId=self.identity,synckey=0)),credentials=credentials)
        self.model=project(self.source,self.identity,credentials['vid'],int(time.time()))
        after_started=time.time()
        after=self.request('progress_after',BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity)),credentials=credentials)
        after_finished=time.time()
        validate_position(after,self.identity)
        clocks=response_clock_matches(before,before_started,before_finished) and response_clock_matches(after,after_started,after_finished)
        if not clocks:raise ValueError('my_marks_position_clock')
        if not unchanged(before,after,self.identity):
            self.position_diagnostic={}
            for level in ('root','book'):
                left,right=(before,after) if level=='root' else (before.get('book'),after.get('book'))
                if isinstance(left,dict) and isinstance(right,dict):
                    self.position_diagnostic[level]={key:left.get(key)==right.get(key) and (key in left)==(key in right)
                        for key in ('bookId','chapterUid','chapterIdx','chapterOffset','progress','updateTime','readUpdateTime','synckey')
                        if key in left or key in right}
            raise ValueError('my_marks_position_changed')
        return dict(shelf_books=len(shelf['books']),notebook_books=len(notebooks['books']),marks=len(self.model['updated']),
                    chapters=len(self.model['chapters']),declared_count_matches=declared==len(self.model['updated']),
                    position_unchanged=True,response_clock_verified=clocks,response_timestamp_changed=before.get('timestamp')!=after.get('timestamp'),text_rows=sum(bool(row.get('markText')) for row in self.model['updated']))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-ui',action='store_true');parser.add_argument('--native-http',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session or args.native_http and not args.lua_command:parser.error('pair saved-session and Lua command for native HTTP')
    if args.native_ui and not args.native_http:parser.error('--native-ui requires --native-http')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,private_values_saved=False)
    credentials=probe=None
    try:
        if args.saved_session:
            credentials=NativeSessionStore().load(SessionStore().load()['vid']);probe=MarksProbe()
            report.update(probe.prepare(credentials),result='MY_CLOUD_MARKS_READ_VERIFIED')
            if args.lua_command:
                payload=dict(source=probe.source,book_id=probe.identity,owner=credentials['vid'],now=probe.model['fetched_at'])
                if args.native_http:payload['credentials']=credentials
                child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=60)
                frame=b'\nWEREAD_MY_MARKS_RESULT='
                if len(child.stdout)>12*1024*1024 or child.stdout.count(frame)!=1:raise ValueError('my_marks_lua')
                actual=json.loads(child.stdout.split(frame)[1])
                if args.native_ui and isinstance(actual.get('ui'),dict):
                    diagnostics=[]
                    for row in actual['ui'].get('stages',[])[:2]:
                        if isinstance(row,dict):
                            diagnostics.append({key:row[key] for key in ('failed_line','requests','forbidden','pages','quotes')
                                                if type(row.get(key)) is int and 0<=row[key]<=100000})
                    report['ui_diagnostics']=diagnostics
                if child.returncode:raise ValueError('my_marks_lua')
                if actual.get('model')!=probe.model:raise ValueError('my_marks_model')
                report['lua_model_matches']=True
                if args.native_http:
                    if actual.get('native')!=probe.model or actual.get('requests')!=1:raise ValueError('my_marks_native')
                    report.update(native_https_matches=True,native_gets=1)
                if args.native_ui:
                    from run_my_cloud_marks_ui import validate_stage
                    ui=actual['ui']
                    if (set(ui)!={'result','profile_removed','installed_bytes_match','installed_files','stages'} or ui['result']!='PASS'
                            or ui['profile_removed'] is not True or ui['installed_bytes_match'] is not True
                            or type(ui['installed_files']) is not int or not 1<=ui['installed_files']<=1000
                            or not isinstance(ui['stages'],list) or len(ui['stages'])!=2):raise ValueError('my_marks_ui')
                    for row,mode in zip(ui['stages'],('live','reopen')):validate_stage(row,mode,len(probe.model['updated']))
                    report['ui']=ui
    except Exception as error:
        report.update(result='UNVERIFIED',reason='my_cloud_marks_unverified')
        if str(error) in {'my_marks_position_changed','my_marks_owner','my_marks_book','my_marks_text','my_marks_chapter',
                          'my_marks_incomplete','my_marks_rows','my_marks_rejected','my_marks_lua','my_marks_model','my_marks_native','my_marks_ui'}:
            report['diagnostic']=str(error)
        if probe and hasattr(probe,'position_diagnostic'):report['position_fields_unchanged']=probe.position_diagnostic
    finally:
        if credentials:credentials.clear()
        if probe:
            report['stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in probe.report['stages']]
            probe.source=probe.model=probe.book=probe.baseline=None
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0 if report['result'] in ('OFFLINE_ONLY','MY_CLOUD_MARKS_READ_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
