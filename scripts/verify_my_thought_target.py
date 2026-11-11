#!/usr/bin/env python3
"""Read-only thought quotation/range prototype; private data stays in memory.

Default offline. Existing native GETs and Web catalog/content read POSTs only.
No account data writes, reading reports, screenshots or private source files.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess
import time
from urllib.parse import urlencode

from my_thought_target import project,reference
from my_cloud_thoughts_model import complete,page
from personal_notes_position import unchanged,response_clock_matches
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from source_currentness import inspect,FIELDS
from verify_eink_login import BASE as NATIVE,NativeProbe
from verify_my_cloud_thoughts import ThoughtsProbe
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import WebSourceProbe,BASE,position


class TargetThoughtsProbe(ThoughtsProbe):
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        fixed=dict(shelf=NATIVE+'/shelf/sync',notebooks=NATIVE+'/user/notebooks?count=100')
        if self.identity:
            for count in (20,40,80,160,320,640,1280,2560,5000):
                fixed['thoughts_'+str(count)]=NATIVE+'/review/list?'+urlencode(dict(bookId=self.identity,listType=11,listMode=0,mine=1,synckey=0,count=count))
            for stage_name in ('progress_before','progress_after'):fixed[stage_name]=NATIVE+'/book/getProgress?'+urlencode(dict(bookId=self.identity))
        # Two complete progressive lists plus shelf/notebooks/position checks.
        if body is not None or stage not in fixed or url!=fixed[stage] or self.calls>=24:raise ValueError('my_thought_target/request_scope')
        self.calls+=1;return NativeProbe.request(self,stage,url,None,credentials,timeout)


def read_all(probe,credentials):
    previous=None
    for count in (20,40,80,160,320,640,1280,2560,5000):
        source=probe.request('thoughts_'+str(count),NATIVE+'/review/list?'+urlencode(dict(bookId=probe.identity,listType=11,listMode=0,mine=1,synckey=0,count=count)),credentials=credentials)
        value=page(source,probe.identity,credentials['vid'])
        if previous and (value['total_count']!=previous['total_count'] or len(value['reviews'])<=len(previous['reviews'])
                         or value['reviews'][:len(previous['reviews'])]!=previous['reviews']):raise ValueError('my_thought_target/changed')
        if not value['has_more']:return complete(source,probe.identity,credentials['vid'],1)
        previous=value
    raise ValueError('my_thought_target/incomplete')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    command=parser.add_mutually_exclusive_group();command.add_argument('--lua-command',nargs=argparse.REMAINDER);command.add_argument('--native-ui-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (args.lua_command or args.native_ui_command) and not args.saved_session:parser.error('comparisons require --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,private_files=False)
    saved=credentials=notes=web=None;ui_chapters=[]
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid']);notes=TargetThoughtsProbe()
            report['notes_preflight']=notes.prepare(credentials)
            model=notes.samples[0]['expected'];rows=[];excluded=0
            for row in model['reviews']:
                try:reference(notes.identity,str(row.get('chapterUid')),row);rows.append(row)
                except ValueError:excluded+=1
            report.update(total_thoughts=len(model['reviews']),eligible=len(rows),without_supported_quote=excluded)
            chapters=sorted({str(row['chapterUid']) for row in rows})
            if not rows or not 1<=len(chapters)<=8:raise ValueError('my_thought_target/no_supported_quote')
            web=WebSourceProbe();web.vid=saved['vid'];web.book_id=notes.identity
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();baseline=position(web.request('progress_before',BASE+'/web/book/getProgress?bookId='+notes.identity),notes.identity)
            matched=0;records=[];reasons={}
            for uid in chapters:
                time.sleep(.5);before,first=inspect(web,notes.identity,uid)
                after,sample=inspect(web,notes.identity,uid,{k:before[k] for k in FIELDS})
                if before!=after:raise ValueError('my_thought_target/source_changed')
                selected=[row for row in rows if str(row['chapterUid'])==uid];targets=[]
                for row in selected:
                    try:targets.append(project(sample['raw'],notes.identity,uid,row));matched+=1
                    except ValueError as error:
                        reason=str(error)
                        if not reason.startswith(('my_thought_target/','my_mark_target/')):reason='my_thought_target/unverified'
                        reasons[reason]=reasons.get(reason,0)+1;targets.append(dict(error=reason))
                records.append(dict(thoughts=len(selected),matched=sum('error' not in row for row in targets),source_read_twice=True))
                if args.lua_command:
                    payload=dict(raw=sample['raw'],book_id=notes.identity,chapter_uid=uid,rows=selected)
                    child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=90)
                    frame=b'\nWEREAD_MY_THOUGHT_TARGET_RESULT='
                    if child.returncode or len(child.stdout)>512*1024 or child.stdout.count(frame)!=1:raise ValueError('my_thought_target/lua')
                    if json.loads(child.stdout.split(frame)[1])!=targets:raise ValueError('my_thought_target/lua')
                if args.native_ui_command:
                    if any('error' in row for row in targets):raise ValueError('my_thought_target/unmatched')
                    ui_chapters.append(dict(chapter_uid=uid,raw=sample['raw'],rows=selected,targets=targets))
                first.clear();sample.clear()
            latest=read_all(notes,credentials);latest['fetched_at']=model['fetched_at']
            if latest!=model:raise ValueError('my_thought_target/changed')
            started=time.time();after=notes.request('progress_after',NATIVE+'/book/getProgress?'+urlencode(dict(bookId=notes.identity)),credentials=credentials)
            if not response_clock_matches(after,started,time.time()) or not unchanged(notes.before,after,notes.identity):raise ValueError('my_thought_target/position_changed')
            final=position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+notes.identity),notes.identity)
            if final!=baseline:raise ValueError('my_thought_target/position_changed')
            report.update(result='MY_THOUGHT_TARGET_VERIFIED' if matched==len(rows) else 'MY_THOUGHT_TARGET_PARTIAL',matched=matched,chapters=records,
                          unmatched_reasons=reasons,original_thoughts_unchanged=True,cloud_position_unchanged=True,server_range_not_used_as_progress_offset=True)
            if args.lua_command:report['lua_model_matches']=True
            if args.native_ui_command:
                payload=dict(book_id=notes.identity,owner=credentials['vid'],variant='thoughts',model=model,chapters=ui_chapters)
                raw=json.dumps(payload,ensure_ascii=False).encode()
                if len(raw)>12*1024*1024:raise ValueError('my_thought_target/ui')
                child=subprocess.run(args.native_ui_command,input=raw,capture_output=True,timeout=max(600,len(rows)*55))
                frame=b'\nWEREAD_MY_MARK_NAVIGATION_RESULT='
                if child.returncode or len(child.stdout)>512*1024 or child.stdout.count(frame)!=1:raise ValueError('my_thought_target/ui')
                ui=json.loads(child.stdout.split(frame)[1]);from run_my_mark_navigation_ui import public_report,validate
                report['native_ui']=public_report(ui)
                if (set(ui)!={'result','profile_removed','installed_bytes_match','installed_files','stages'} or ui.get('result')!='PASS'
                        or ui.get('profile_removed') is not True or ui.get('installed_bytes_match') is not True
                        or type(ui.get('installed_files')) is not int or not 1<=ui['installed_files']<=1000
                        or not isinstance(ui.get('stages'),list) or len(ui['stages'])!=2):raise ValueError('my_thought_target/ui')
                for stage,mode in zip(ui['stages'],('live','reopen')):validate(stage,mode,len(rows),len(chapters))
                final=position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+notes.identity),notes.identity)
                if final!=baseline:raise ValueError('my_thought_target/position_changed')
    except Exception as error:
        allowed={'my_thought_target/'+key for key in ('no_supported_quote','source_changed','changed','incomplete','position_changed','lua','ui','unmatched')}
        report.update(result='UNVERIFIED',reason=str(error) if str(error) in allowed else 'my_thought_target/prototype_failed')
    finally:
        if web:
            try:web.verify_account();report['rotation_saved']=save_refreshed_web_session(store,saved,web)
            except Exception:report.update(result='UNVERIFIED',reason='my_thought_target/session_check')
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.close()
        if notes:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in notes.report['stages']]
        for value in (saved,credentials):
            if value:value.clear()
        ui_chapters.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result'] not in ('OFFLINE_ONLY','MY_THOUGHT_TARGET_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
