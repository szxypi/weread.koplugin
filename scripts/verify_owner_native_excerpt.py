#!/usr/bin/env python3
"""Actual TXT bookReader -> parent-owned background excerpt -> offline reopen.

No apply/renewal mode; optional native grant permits three read-only GETs. Source and credentials stay in
captured pipes, with book/profile files confined to the Linux runner's tmpfs.
"""
import argparse
from datetime import datetime,timezone
import json
import resource
import subprocess
from secure_weread_session import SessionStore
from verify_owner_reading import TxtReadingPreflight,reading_position
from verify_web_source_progress import BASE
from verify_translation_preflight import save_refreshed_web_session
from owner_native_excerpt_contract import decode,compare
from verify_cb_progress import cb_id
from secure_native_session import NativeSessionStore
from verify_reader_progress import project,find_node


class UnstartedSample(ValueError):pass


class Preflight(TxtReadingPreflight):
    """Include independently observed CB_ shelf display GETs in the UI scope."""
    def __init__(self,require_started=False):
        super().__init__();self.display_ids=[];self.require_started=require_started

    def choose_chapter(self,chapters):
        value=super().choose_chapter(chapters)
        if self.require_started and self.baseline['chapter']=='0':raise UnstartedSample()
        return value

    def inspect_book(self,book_id,hint=None):
        try:return super().inspect_book(book_id,hint)
        except UnstartedSample:return False

    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage=='shelf':
            rows=value.get('books') if isinstance(value,dict) else None
            if not isinstance(rows,list) or len(rows)>5000:raise ValueError('native_excerpt/shelf')
            self.display_ids=list(dict.fromkeys(row['bookId'] for row in rows if isinstance(row,dict) and cb_id(row.get('bookId'))))
        return value

    def prepare(self):
        value=super().prepare()
        value['shelf_ids']=list(dict.fromkeys(value['shelf_ids']+self.display_ids))
        return value


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    p.add_argument('--native-routing-preview',action='store_true')
    p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.saved_session!=bool(a.lua_command):p.error('pair saved session and private native command')
    if a.native_routing_preview and not a.saved_session:p.error('native preview requires saved session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,screenshots=0,private_data_on_regular_disk=False,production_upload_enabled=False)
    saved=web=payload=envelope=None;phase='preflight'
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            store=SessionStore();saved=store.load();web=Preflight(require_started=a.native_routing_preview);web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();payload=web.prepare();raw=web.sample['plain']
            web.verify_account();save_refreshed_web_session(store,saved,web);saved=store.load()
            payload.update(vid=web.vid,cookies=saved['cookies'],native_source_excerpt=True)
            if a.native_routing_preview:
                phase='native_credentials'
                grant=NativeSessionStore().load(web.vid)
                phase='expected_remote'
                observed_raw=web.request('progress_after',BASE+'/web/book/getProgress?bookId='+web.book_id)
                node=find_node(observed_raw,web.book_id)
                report['expected_remote_fields']={name:any(k in node for k in keys) for name,keys in (
                    ('index',('chapterIdx','chapterIndex','chapter_idx')),('offset',('chapterOffset','chapterPos','offset','chapter_offset')),
                    ('uid',('chapterUid','chapterId','chapter_uid')),('percent',('progress','readingProgress','bookProgress')))}
                observed=project(observed_raw,web.book_id)
                report['expected_remote_fields']['uid_started']=str(observed.get('chapter_uid')) not in ('0','None')
                report['expected_remote_fields']['uid_is_selected']=str(observed.get('chapter_uid'))==web.chapter
                if not observed['has_chapter_offset'] or not report['expected_remote_fields']['index']:
                    raise ValueError('native_excerpt/incomplete_remote')
                expected={key:observed[key] for key in ('book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent')}
                expected.update(chapter_uid=str(expected['chapter_uid']),source='web',has_chapter_offset=True,has_chapter_index=True)
                payload.update(native_grant=grant,native_routing_preview=True,expected_native_remote=expected)
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>256*1024:raise ValueError('native_excerpt/input')
            phase='reader_process'
            child=subprocess.run(a.lua_command,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=420)
            phase='reader_contract'
            envelope=decode(child.stdout,web.vid);report['ui']=envelope['report']
            web.cookies.clear()
            for key,value in envelope['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            after=reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+web.book_id),web.book_id,allow_unstarted=True)
            report['cloud_position_unchanged']=after==web.baseline
            save_refreshed_web_session(store,saved,web)
            if child.returncode or report['ui']['result']!='PASS' or not report['cloud_position_unchanged']:raise ValueError('native_excerpt/ui')
            compare(envelope['candidate_private'],raw,payload)
            for stage in report['ui']['stages']:
                if stage['native_source_excerpt']['native_prepare_checks']!=int(a.native_routing_preview and stage['mode']=='live'):
                    raise ValueError('native_excerpt/native_routing')
            report.update(result='OWNER_NATIVE_TXT_EXCERPTS_VERIFIED',excerpts_compared=6,independent_python_source_match=True,
                          fresh_offline_process=True,official_summary_rule_verified=False)
    except (Exception,KeyboardInterrupt):report.update(result='UNVERIFIED',failure_stage=phase)
    finally:
        if web:
            report['stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.sample=None;web.shards.clear();web.close()
        for value in (saved,payload,envelope):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
