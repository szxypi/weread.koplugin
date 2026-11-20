#!/usr/bin/env python3
"""Real native positions and production upload bodies, with dispatch disabled.

There is no --apply mode. One synthetic enter acknowledgement lets the actual
ReadReport service build its reports; every report is intercepted before HTTP.
This does not grant source-coordinate upload rights or prove a real write.
"""
import argparse
from datetime import datetime, timezone
import json
import subprocess
import time

from secure_weread_session import SessionStore
from verify_owner_reading import BASE, ReadingPreflight, reading_position
from verify_reader_context import project as reader_context
from verify_position_roundtrip import prepare_plan, payload as wire_payload, validate_payload, WRITE_ORDER
from verify_translation_preflight import save_refreshed_web_session
from fetch_weread_epub import decode_content_shards
from owner_progress_preview_contract import decode, compare, ERRORS


class Preflight(ReadingPreflight):
    def __init__(self):
        super().__init__()
        self.raw_progress = self.reader = self.plan = None

    def request(self, stage, url, body=None, **options):
        value=super().request(stage,url,body,**options)
        if stage=='progress_before': self.raw_progress=value
        if stage=='reader': self.reader=reader_context(dict(book_id=self.book_id),value)
        return value

    def prepare(self):
        value=super().prepare()
        source=decode_content_shards(*(self.shards[k] for k in ('e_0','e_1','e_3')))
        self.plan=prepare_plan(self.book_id,self.raw_progress,self.reader,source)
        if self.plan['target'] is None: raise ValueError('progress_preview_no_adjacent_point')
        for stage in WRITE_ORDER: validate_payload(self.plan,stage,wire_payload(self.plan,stage))
        fields=('book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')
        value['progress_preview']={name:{key:self.plan[name][key] for key in fields} for name in ('baseline','target')}
        return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):
        parser.error('pair --saved-session and --lua-command; put --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),
                account_data_writes_attempted=0,authentication_posts_attempted=0,private_data_on_regular_disk=False,
                screenshots=0,real_plugin_write_verified=False,source_upload_gate_enabled=False)
    web=saved=payload=envelope=None
    try:
        if args.saved_session:
            report['phase']='preflight'
            store,web=SessionStore(),Preflight()
            saved=store.load();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            try:payload=web.prepare()
            finally:
                web.verify_account()
                report['preflight_rotation_saved']=save_refreshed_web_session(store,saved,web)
                saved=store.load()
            payload.update(vid=web.vid,cookies=saved['cookies'])
            raw=json.dumps(payload,ensure_ascii=False).encode()
            if len(raw)>256*1024:raise ValueError('progress_preview_input_limit')
            started=int(time.time())
            report['phase']='native'
            child=subprocess.run(args.lua_command,input=raw,capture_output=True,timeout=240)
            finished=int(time.time())
            report['phase']='decode'
            envelope=decode(child.stdout,web.vid)
            report['ui']=envelope['report']
            web.cookies.clear()
            report['phase']='postflight'
            for key,value in envelope['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            after=reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+web.book_id),web.book_id)
            report['cloud_position_unchanged']=after==web.baseline
            report['final_rotation_saved']=save_refreshed_web_session(store,saved,web)
            if child.returncode or report['ui']['result']!='PASS':raise ValueError(report['ui']['runner_error'])
            if not report['cloud_position_unchanged']:raise ValueError()
            report['phase']='compare'
            compare(envelope['progress_private']['records'],web.plan,started,finished)
            report.update(result='OWNER_NATIVE_UPLOAD_PREVIEW_VERIFIED',independent_payloads_verified=True,
                          payloads_compared=4,probe_utf16_delta=1,planned_post_limit=4,synthetic_enter_acknowledgement=True,
                          same_owner_verified=True,offline_reopen_included=False)
            report['phase']='complete'
    except Exception as exc:
        report.update(result='UNVERIFIED',reason='owner_progress_preview_unverified')
        known={'roundtrip_incomplete_context','roundtrip_chapter_index_missing','roundtrip_context_changed',
               'roundtrip_payload_invalid','progress_preview_no_adjacent_point','progress_preview_clock',
               'progress_preview_context','progress_preview_payload_count'} | ERRORS
        if str(exc) in known:report['detail']=str(exc)
    finally:
        if web:
            report['preflight_stages']=[{k:row[k] for k in ('stage','status','api_code') if k in row} for row in web.report['stages']]
            web.shards.clear();web.raw_progress=web.reader=web.plan=None;web.close()
        for value in (saved,payload,envelope):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','OWNER_NATIVE_UPLOAD_PREVIEW_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
