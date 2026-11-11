#!/usr/bin/env python3
"""Read-only real native unmarked-selection -> production submit-boundary proof.

No apply or renewal mode. Every account data POST is blocked by the native
gate. Private text and credentials cross captured pipes; profiles use tmpfs.
"""
import argparse
from datetime import datetime,timezone
import json
import secrets
import subprocess

from annotation_experiment_model import digest,note_text
from fetch_weread_epub import decode_content_shards,normalize_chapter_infos
from owner_selection_preview import choose,compare,decode,ERRORS,validate_input
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from source_upload_candidate import chapter_index
from verify_annotation_experiment import AnnotationProbe
from verify_eink_login import BASE as NATIVE
from verify_owner_reading import ReadingPreflight,reading_position
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE


class Preflight(ReadingPreflight):
    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage=='catalog_after':self.chapters=normalize_chapter_infos(value,self.book_id)[1]
        return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.native_ui_command):parser.error('pair --saved-session and --native-ui-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,private_data_on_regular_disk=False,screenshots=0,write_permission=False)
    saved=credentials=payload=envelope=None;web=notes=None
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid'])
            web=Preflight();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();payload=web.prepare();raw=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
            notes=AnnotationProbe();notes.identity=payload['book_id'];notes.grant=digest(credentials)
            before=notes.observe(credentials,'selection_baseline')
            metadata=notes.request('selection_metadata',NATIVE+'/book/info?bookId='+payload['book_id'],credentials=credentials)
            if str(metadata.get('bookId'))!=payload['book_id']:raise ValueError('selection_scope')
            selected=choose(raw,before['marks']['updated'],payload['book_id'],payload['chapter_uid'],
                            chapter_index(web.chapters,payload['chapter_uid']))
            row=selected['reference'];body=dict(bookId=payload['book_id'],chapterUid=payload['chapter_uid'],
                bookVersion=metadata.get('bookVersion',metadata.get('version')),type=1,range=row['range'],abstract=row['markText'],
                isPrivate=1,content=note_text(secrets.token_hex(16)))
            if any(item['content']==body['content'] for item in before['thoughts'].values()):raise ValueError('selection_scope')
            payload.update(vid=saved['vid'],cookies=saved['cookies'],selection_preview=dict(credentials=credentials,
                first=selected['first'],last=selected['last'],reference=row,body=body))
            validate_input(payload)
            if notes.observe(credentials,'selection_independent')!=before:raise ValueError('selection_preflight_changed')
            web.verify_account();report['preflight_rotation_saved']=save_refreshed_web_session(store,saved,web);saved=store.load()
            payload['cookies']=saved['cookies']
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>256*1024:raise ValueError('selection_input')
            child=subprocess.run(args.native_ui_command,input=encoded,capture_output=True,timeout=600)
            envelope=decode(child.stdout,web.vid);report['ui']=envelope['report']
            web.cookies.clear()
            for key,value in envelope['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            final=reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+web.book_id),web.book_id)
            report['cloud_position_unchanged']=final==web.baseline
            report['original_cloud_state_unchanged']=notes.observe(credentials,'selection_final')==before
            report['final_rotation_saved']=save_refreshed_web_session(store,saved,web)
            if (child.returncode or report['ui']['result']!='PASS' or not report['cloud_position_unchanged']
                    or not report['original_cloud_state_unchanged']):raise ValueError('selection_native_unverified')
            compare(envelope['selection_private'],raw,payload)
            report.update(result='OWNER_NATIVE_NEW_SELECTION_PREVIEW_VERIFIED_NO_WRITE',independent_model_verified=True,
                disjoint_from_existing_marks=True,selected_quote_reuses_saved_mark=False,production_submit_boundary=True,
                fresh_offline_draft_restored=True,offline_http_requests=0,automatic_write_replay=False)
    except Exception as exc:
        report.update(result='UNVERIFIED',reason=str(exc) if str(exc) in ERRORS else 'selection_acceptance_unverified')
    finally:
        if web:
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.shards.clear();web.close()
        if notes:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in notes.report['stages']]
        for value in (saved,credentials,payload,envelope):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
