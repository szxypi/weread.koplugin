#!/usr/bin/env python3
"""Obtain an owner-scoped Skill key and examine the official shelf, without pin writes."""
import argparse
from datetime import datetime,timezone
import json
import re
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_eink_login import BASE
from verify_pin_observability import Reads,Web,gateway,project
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB

SERVICE='org.codex.weread.goal-skill-validation'
KEY_URL=WEB+'/api/skills/apikeyGet'


def validate(value,owner):
    if (not isinstance(value,dict) or set(value)!={'schema','scope','owner','key','created_at'}
            or value['schema']!=1 or value['scope']!=ACCOUNT or value['owner']!=owner
            or not isinstance(value['created_at'],str) or not 1<=len(value['created_at'])<=64
            or not isinstance(value['key'],str) or not re.fullmatch(r'wrk-[\x21-\x7e]{8,4092}',value['key'])):
        raise ValueError('skill/key_invalid')
    return value


class KeyWeb(Web):
    def guard(self,stage,url,body):
        if stage=='skill_key' and url==KEY_URL and body is None and self.authenticated:return
        return super().guard(stage,url,body)


def obtain(web,backend,owner,allow_create,report):
    saved=backend.load()
    if saved is not None:
        payload=validate(json.loads(saved),owner)
        report['keychain_reused']=True
        return payload['key']
    if not allow_create:raise ValueError('skill/key_missing')
    web.verify_account()
    report['key_request_attempted']=True
    response=web.request('skill_key',KEY_URL)
    if not isinstance(response,dict) or any(response.get(k,0) not in (None,0) for k in ('errcode','errCode')):
        raise ValueError('skill/key_response')
    payload=validate(dict(schema=1,scope=ACCOUNT,owner=owner,key=response.get('apikey'),
        created_at=datetime.now(timezone.utc).isoformat()),owner)
    data=json.dumps(payload,separators=(',',':')).encode()
    backend.save(data)
    if backend.load()!=data:raise ValueError('skill/keychain_readback')
    report['keychain_saved']=True
    web.verify_account()
    return payload['key']


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--create-key',action='store_true')
    args=parser.parse_args(argv)
    if args.create_key and not args.saved_session:parser.error('--create-key requires --saved-session')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,gateway_read_posts=0,
        key_request_attempted=False,keychain_saved=False,keychain_reused=False,credentials_written_to_files=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    saved=credentials=key=None;web=KeyWeb();native=Reads()
    try:
        from verify_native_thought_trial import other_pending
        if other_pending():raise ValueError('skill/pending')
        sessions=SessionStore();saved=sessions.load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
        web.vid=owner
        for name,value in saved['cookies'].items():web.set_cookie(name,value)
        web.verify_account()
        native_before,native_rows=project(native.request('pin_shelf',BASE+'/shelf/sync',credentials=credentials))
        web_before,web_rows=project(web.request('shelf',WEB+'/web/shelf/sync'))
        with project_lock():
            key=obtain(web,MacKeychain(service=SERVICE,account=ACCOUNT),owner,args.create_key,report)
        report['gateway_read_posts']=1
        official,official_rows=project(gateway(key))
        native_after,native_rows_after=project(native.request('pin_shelf',BASE+'/shelf/sync',credentials=credentials))
        web_after,web_rows_after=project(web.request('shelf',WEB+'/web/shelf/sync'))
        web.verify_account();save_refreshed_web_session(sessions,saved,web)
        stable=native_rows==native_rows_after and web_rows==web_rows_after
        common=set(native_rows)==set(web_rows)==set(official_rows)
        other_flags=common and all(native_rows[k][field]==web_rows[k][field]==official_rows[k][field]
            for k in native_rows for field in ('private','finished'))
        report.update(result='GATEWAY_OBSERVED' if stable and common else 'UNVERIFIED',
            native=native_before,web=web_before,gateway=official,stable_readback=stable,
            same_members=common,visible_other_flags_match=bool(other_flags),
            observable_pin=official['pinned'].get('true',0)+official['pinned'].get('false',0)>0,
            native_summary_unchanged=native_before==native_after,web_summary_unchanged=web_before==web_after)
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        report['native_stages']=[{k:row[k] for k in ('stage','status') if k in row} for row in native.report['stages']]
        report['web_stages']=[{k:row[k] for k in ('stage','status') if k in row} for row in web.report['stages']]
        web.close();key=None
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
