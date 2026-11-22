#!/usr/bin/env python3
"""Read-only native offline-reconnect rehearsal for one ordinary XHTML book.

No write-capable mode exists. Source and credentials stay in memory or the
runner's temporary RAM filesystem. Every progress POST is denied in Lua.
"""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import hashlib
import json
import re
import resource

from fetch_weread_epub import decode_content_shards,normalize_chapter_infos
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_fixture_reconnect_trial import run_ui,source_summary
from verify_owner_progress_preview import Preflight
from verify_reader_progress import project
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE


class CapturedPreflight(Preflight):
    def __init__(self):
        super().__init__();self.catalog=None;self.shelf=None

    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage=='catalog_after':self.catalog=deepcopy(value)
        if stage=='shelf':self.shelf=deepcopy(value)
        return value


def build_payload(web,saved):
    book=web.book_id;baseline=web.plan['baseline']
    if not isinstance(book,str) or not re.fullmatch('[1-9][0-9]{0,19}',book):raise ValueError('ordinary_reconnect/book')
    _record,chapters=normalize_chapter_infos(web.catalog,book)
    matches=[row for row in chapters if str(row.get('chapterUid'))==str(web.chapter)]
    if (len(matches)!=1 or type(matches[0].get('chapterIdx')) is not int
            or matches[0]['chapterIdx']!=baseline['chapter_idx'] or type(matches[0].get('wordCount')) is not int
            or matches[0]['wordCount']<=0 or len(chapters)>2000):raise ValueError('ordinary_reconnect/catalog')
    source=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
    if not 1<=len(source.encode())<=2*1024*1024:raise ValueError('ordinary_reconnect/source')
    model=FilteredSource(source)
    if not source_summary(model,baseline['chapter_offset']):raise ValueError('ordinary_reconnect/baseline')
    payload=dict(book=book,chapter=str(web.chapter),chapter_idx=baseline['chapter_idx'],first_offset=baseline['chapter_offset'],
                 next_offset=baseline['chapter_offset'],source=source,source_format='web_xhtml',chapters=chapters,book_version=0,
                 owner=web.vid,cookies=dict(saved['cookies']),armed=False,ordinary=True,reconnect=True,reconnect_discover=True)
    return payload,model


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.saved_session!=bool(a.lua_command) or not all(1<=n<=4096 for n in (a.width,a.height,a.dpi)):
        p.error('saved session and private reader command must be paired')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,private_data_on_regular_disk=False,guarded_write_mode=False)
    store=web=saved=payload=None;secrets=set()
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            store=SessionStore();saved=store.load();web=CapturedPreflight();web.vid=saved['vid']
            secrets.update(str(value) for value in saved['cookies'].values())
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();web.prepare()
            if not web.report.get('read_snapshot_consistent'):raise ValueError('ordinary_reconnect/stale')
            before=project(web.raw_progress,web.book_id);source_sha=hashlib.sha256(decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3'))).encode()).hexdigest()
            original_catalog=deepcopy(web.catalog);shelf_sha=state_hash(web.shelf)
            web.verify_account();save_refreshed_web_session(store,saved,web);saved=store.load()
            secrets.update(str(value) for value in saved['cookies'].values());secrets.add(web.book_id)
            payload,model=build_payload(web,saved)
            discovered=run_ui(a.lua_command,payload,a.width,a.height,a.dpi)
            offset=discovered['offset']
            if offset==payload['first_offset']:raise ValueError('ordinary_reconnect/no_movement')
            summary=source_summary(model,offset)
            if not summary:raise ValueError('ordinary_reconnect/source')
            secrets.add(summary);payload.pop('reconnect_discover');payload.update(next_offset=offset,expected_summary=summary)
            preview=run_ui(a.lua_command,payload,a.width,a.height,a.dpi)
            if preview['writes']!=0 or preview['denied']!=1:raise ValueError('ordinary_reconnect/scope')
            web.verify_account();web.inspect(web.book_id)
            if (project(web.raw_progress,web.book_id)!=before or web.catalog!=original_catalog
                    or hashlib.sha256(decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3'))).encode()).hexdigest()!=source_sha
                    or not web.report.get('read_snapshot_consistent')):raise ValueError('ordinary_reconnect/changed')
            if state_hash(web.request('shelf',BASE+'/web/shelf/sync'))!=shelf_sha:raise ValueError('ordinary_reconnect/shelf')
            web.verify_account();save_refreshed_web_session(store,saved,web)
            report.update(result='ORDINARY_RECONNECT_DISARMED_VERIFIED',offline_intent=True,reconnect_choice=True,
                          signed_target_checked=True,write_blocked=True,independent_position_source_catalog_shelf_unchanged=True,
                          tmpfs_profile_removed=True,screenshots=0)
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and re.fullmatch('ordinary_reconnect/[a-z_]+',str(error)):report['reason']=str(error)
        else:report['reason']='ordinary_reconnect/preflight_or_runtime'
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,store.load(),web)
                except Exception:report['result']='UNVERIFIED';report['reason']='ordinary_reconnect/session'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.shards.clear();web.close()
        for value in (saved,payload):
            if isinstance(value,dict):value.clear()
    encoded=json.dumps(report,ensure_ascii=True)
    if any(len(v)>=8 and (v in encoded or json.dumps(v,ensure_ascii=True)[1:-1] in encoded) for v in secrets):
        report=dict(result='UNVERIFIED',reason='ordinary_reconnect/privacy',account_data_posts=0,authentication_posts=0)
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
