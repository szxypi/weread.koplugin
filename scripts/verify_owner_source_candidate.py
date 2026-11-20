#!/usr/bin/env python3
"""Opt-in real native capture -> candidate -> independent source comparison.

The default is offline. No apply mode, mutation or authentication POST exists.
Private records cross captured memory pipes only; the native profile is tmpfs.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess

from secure_weread_session import SessionStore
from verify_owner_reading import ReadingPreflight,reading_position
from verify_web_source_progress import BASE
from fetch_weread_epub import decode_content_shards,normalize_chapter_infos
from verify_translation_preflight import save_refreshed_web_session
from owner_source_candidate_contract import decode,compare,ModelError,ERRORS


class Preflight(ReadingPreflight):
    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage=='catalog_after':self.chapters=normalize_chapter_infos(value,self.book_id)[1]
        return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('pair --saved-session and --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                authentication_posts_attempted=0,private_data_on_regular_disk=False,screenshots=0,
                actual_upload_service_called=False,precision_source_upload_enabled=False)
    saved=web=payload=envelope=raw=None
    try:
        if args.saved_session:
            store,web=SessionStore(),Preflight();saved=store.load();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            try:payload=web.prepare()
            finally:
                web.verify_account();report['preflight_rotation_saved']=save_refreshed_web_session(store,saved,web)
                saved=store.load()
            raw=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
            payload.update(vid=web.vid,cookies=saved['cookies'],source_upload_preview=True)
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>256*1024:raise ValueError('candidate_input_limit')
            child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=420)
            envelope=decode(child.stdout,web.vid);report['ui']=envelope['report']
            web.cookies.clear()
            for key,value in envelope['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            after=reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+web.book_id),web.book_id)
            report['cloud_position_unchanged']=after==web.baseline
            report['final_rotation_saved']=save_refreshed_web_session(store,saved,web)
            if child.returncode or report['ui']['result']!='PASS' or not report['cloud_position_unchanged']:
                raise ValueError('candidate_native_unverified')
            compare(envelope['candidate_private'],raw,web.chapters,payload)
            report.update(result='OWNER_NATIVE_SOURCE_CANDIDATES_VERIFIED_NO_WRITE',candidates_compared=6,
                          independent_source_model_verified=True,fresh_offline_process=True,offline_http_requests=0)
    except Exception as exc:
        report.update(result='UNVERIFIED',reason='candidate_acceptance_unverified')
        if isinstance(exc,ModelError):report['model_diagnostic']=exc.diagnostic
        elif str(exc) in ERRORS:report['detail']=str(exc)
    finally:
        if web:
            report['stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.shards.clear();web.close()
        for value in (saved,payload,envelope):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
