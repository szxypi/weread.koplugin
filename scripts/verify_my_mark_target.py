#!/usr/bin/env python3
"""Read-only source-range comparison for all selected-book personal highlights.

Default offline. --saved-session permits existing native GETs and the verified
Web catalog/content read POSTs only. No account/authentication mutations, UI
reading report, persistent source, private screenshots or credential files.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess
import time
from urllib.parse import urlencode

from my_cloud_marks_model import project as marks_project
from my_mark_target import project
from annotation_source_quotes import SourceQuotes
from personal_notes_position import unchanged,response_clock_matches
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from source_currentness import inspect,FIELDS
from verify_eink_login import BASE as NATIVE
from verify_my_cloud_marks import MarksProbe
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import WebSourceProbe,BASE,position


class TargetMarksProbe(MarksProbe):
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        # The original fixed five-call preflight stays intact; allow one final
        # independent same-book snapshot and precise-position read afterwards.
        if stage in ('final_marks','final_position'):
            suffix='/book/bookmarklist?' + urlencode(dict(bookId=self.identity,synckey=0)) if stage=='final_marks' else '/book/getProgress?'+urlencode(dict(bookId=self.identity))
            if body is not None or url!=NATIVE+suffix or self.calls!={'final_marks':5,'final_position':6}[stage]:raise ValueError('my_mark_target/request')
            self.calls+=1
            return super(MarksProbe,self).request(stage,url,body,credentials,timeout)
        return super().request(stage,url,body,credentials,timeout)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--personal-display',action='store_true')
    command=parser.add_mutually_exclusive_group()
    command.add_argument('--lua-command',nargs=argparse.REMAINDER);command.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if (args.lua_command or args.native_ui_command) and not args.saved_session:parser.error('comparisons require --saved-session')
    if args.personal_display and not args.native_ui_command:parser.error('personal display requires a native UI command')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,private_data_saved_to_files=False)
    saved=credentials=marks=web=None;ui_chapters=[]
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid']);marks=TargetMarksProbe()
            report['marks_preflight']=marks.prepare(credentials)
            rows=[row for row in marks.model['updated'] if row.get('type')==1 and row.get('markText')]
            chapters=sorted({str(row.get('chapterUid')) for row in rows})
            if not rows or not 1<=len(chapters)<=8:raise ValueError('my_mark_target/selection')
            web=WebSourceProbe();web.vid=saved['vid'];web.book_id=marks.identity
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();baseline=position(web.request('progress_before',BASE+'/web/book/getProgress?bookId='+marks.identity),marks.identity)
            verified=0;reasons={};chapter_records=[];quote_diagnostics=[]
            for uid in chapters:
                time.sleep(.5)
                before,_sample=inspect(web,marks.identity,uid)
                expected={key:before[key] for key in FIELDS}
                after,sample=inspect(web,marks.identity,uid,expected)
                if before!=after:raise ValueError('my_mark_target/source_changed')
                selected=[row for row in rows if str(row.get('chapterUid'))==uid];matched=0;expected_targets=[]
                for row in selected:
                    try:expected_targets.append(project(sample['raw'],marks.identity,uid,row));matched+=1
                    except ValueError as error:
                        reason=str(error)
                        if reason not in {'my_mark_target/'+s for s in ('scope','quote','range','source','quote_changed','source_unsupported','ambiguous','unmatched','boundary')}:reason='my_mark_target/other'
                        reasons[reason]=reasons.get(reason,0)+1
                        expected_targets.append(dict(error=reason))
                        if reason=='my_mark_target/quote_changed':
                            # Fixed comparisons only, never source text, offsets,
                            # identifiers, hashes of quotes or actual characters.
                            from html import unescape
                            source_quote=SourceQuotes(sample['raw'],body_only=True).quote(row['range']);saved_quote=row['markText']
                            normalize=lambda value:''.join(c for c in value if not c.isspace())
                            quote_diagnostics.append(dict(source_quote_empty=not source_quote,
                                whitespace_normalized_equal=normalize(source_quote)==normalize(saved_quote),
                                trimmed_equal=source_quote.strip()==saved_quote.strip(),
                                html_unescaped_saved_equal=source_quote==unescape(saved_quote),
                                saved_has_non_bmp=any(ord(c)>65535 for c in saved_quote),
                                source_has_non_bmp=any(ord(c)>65535 for c in source_quote)))
                if args.lua_command:
                    payload=dict(raw=sample['raw'],book_id=marks.identity,chapter_uid=uid,rows=selected)
                    child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=90)
                    frame=b'\nWEREAD_MY_MARK_TARGET_RESULT='
                    if child.returncode or len(child.stdout)>512*1024 or child.stdout.count(frame)!=1:raise ValueError('my_mark_target/lua_failed')
                    actual=json.loads(child.stdout.split(frame)[1])
                    if actual!=expected_targets:raise ValueError('my_mark_target/lua_differs')
                    report['lua_chapters_compared']=report.get('lua_chapters_compared',0)+1
                if args.native_ui_command:
                    if matched!=len(selected):raise ValueError('my_mark_target/ui_unmatched')
                    ui_chapters.append(dict(chapter_uid=uid,raw=sample['raw'],rows=selected,targets=expected_targets))
                verified+=matched;chapter_records.append(dict(highlights=len(selected),matched=matched,source_read_twice=True))
                sample.clear();_sample.clear()
            final=position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+marks.identity),marks.identity)
            web.verify_account()
            latest=marks.request('final_marks',NATIVE+'/book/bookmarklist?'+urlencode(dict(bookId=marks.identity,synckey=0)),credentials=credentials)
            if marks_project(latest,marks.identity,credentials['vid'],marks.model['fetched_at'])!=marks.model:raise ValueError('my_mark_target/marks_changed')
            started=time.time();native_after=marks.request('final_position',NATIVE+'/book/getProgress?'+urlencode(dict(bookId=marks.identity)),credentials=credentials);finished=time.time()
            if not response_clock_matches(native_after,started,finished) or not unchanged(marks.baseline,native_after,marks.identity) or final!=baseline:raise ValueError('my_mark_target/position_changed')
            report.update(result='MY_MARK_TARGET_PROTOTYPE_VERIFIED' if verified==len(rows) else 'MY_MARK_TARGET_PROTOTYPE_PARTIAL',
                highlights=len(rows),matched=verified,chapters=chapter_records,unmatched_reasons=reasons,quote_diagnostics=quote_diagnostics,marks_unchanged=True,cloud_position_unchanged=True,
                source_reads_per_chapter=2,upload_enabled=False,server_range_not_used_as_progress_offset=True)
            if args.lua_command:report['lua_model_matches']=True
            if args.native_ui_command:
                payload=dict(book_id=marks.identity,owner=credentials['vid'],model=marks.model,chapters=ui_chapters)
                raw=json.dumps(payload,ensure_ascii=False).encode()
                if len(raw)>12*1024*1024:raise ValueError('my_mark_target/ui_input')
                child=subprocess.run(args.native_ui_command,input=raw,capture_output=True,timeout=max(600,len(rows)*55))
                frame=b'\nWEREAD_MY_MARK_NAVIGATION_RESULT='
                if len(child.stdout)>512*1024 or child.stdout.count(frame)!=1:raise ValueError('my_mark_target/ui_frame')
                ui=json.loads(child.stdout.split(frame)[1])
                from run_my_mark_navigation_ui import validate,public_report
                report['native_ui']=public_report(ui)
                if child.returncode or ui.get('result')!='PASS' or ui.get('profile_removed') is not True or ui.get('installed_bytes_match') is not True:raise ValueError('my_mark_target/ui_unverified')
                if len(ui['stages'])!=2:raise ValueError('my_mark_target/ui_unverified')
                for stage,mode in zip(ui['stages'],('live','reopen')):validate(stage,mode,len(rows),len(chapters),personal=args.personal_display)
                # Verify real cloud state after the native process as well.
                final=position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+marks.identity),marks.identity)
                if final!=baseline:raise ValueError('my_mark_target/position_changed')
    except Exception as error:
        allowed={'my_mark_target/'+s for s in ('selection','request','source_changed','marks_changed','position_changed','lua_failed','lua_differs',
            'ui_unmatched','ui_input','ui_frame','ui_unverified')}
        report.update(result='UNVERIFIED',reason=str(error) if str(error) in allowed else 'my_mark_target/prototype_failed')
    finally:
        if web:
            try:
                web.verify_account();report['rotation_saved']=save_refreshed_web_session(store,saved,web)
            except Exception:report.update(result='UNVERIFIED',reason='my_mark_target/session_check')
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.close()
        if marks:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in marks.report['stages']]
        for value in (saved,credentials):
            if value:value.clear()
        ui_chapters.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result'] not in ('OFFLINE_ONLY','MY_MARK_TARGET_PROTOTYPE_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
