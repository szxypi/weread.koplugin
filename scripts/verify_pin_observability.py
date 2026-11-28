#!/usr/bin/env python3
"""Bounded read-only pin discovery. No pin write, renewal or raw data output."""
import argparse
from collections import Counter
from datetime import datetime,timezone
import json
from urllib.error import HTTPError
from urllib.request import Request,build_opener
from finish_change_contract import flags
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import NativeProbe,BASE,NoRedirect
from verify_shelf_flags import WebFlagsProbe
from verify_web_source_progress import BASE as WEB,PreflightError
from verify_translation_preflight import save_refreshed_web_session

QUERIES=('', '?synckey=0', '?synckey=0&lectureSynckey=0&onlyBookid=0')
GATEWAY=BASE+'/api/agent/gateway'
KEY_URL=WEB+'/api/skills/apikeyGet?only_show=1'


def unwrap(value):
    for _i in range(4):
        if not isinstance(value,dict) or any(value.get(key,0) not in (None,0) for key in ('errcode','errCode')):raise ValueError('pin/response')
        if isinstance(value.get('books'),list):return value
        value=value.get('data',value.get('result'))
    raise ValueError('pin/shelf')


def project(value):
    shelf=unwrap(value);rows=flags(shelf)
    return dict(books=len(rows),pinned=dict(Counter('true' if row['pinned'].get('value') is True else
        'false' if row['pinned'].get('value') is False else row['pinned']['reason'] for row in rows.values()))),rows


class Reads(NativeProbe):
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if stage!='pin_shelf' or body is not None or url not in {BASE+'/shelf/sync'+query for query in QUERIES}:raise ValueError('pin/read_scope')
        return super().request(stage,url,credentials=credentials,timeout=timeout)


class Web(WebFlagsProbe):
    def guard(self,stage,url,body):
        if stage=='account' and url==KEY_URL and body is None and self.authenticated:return
        return super().guard(stage,url,body)


def gateway(key,opener=None):
    if not isinstance(key,str) or not key.startswith('wrk-') or not 12<=len(key)<=4096 or any(ord(c)<33 or ord(c)>126 for c in key):raise ValueError('pin/key')
    request=Request(GATEWAY,data=json.dumps(dict(api_name='/shelf/sync',skill_version='1.0.5')).encode(),
        headers={'Authorization':'Bearer '+key,'Content-Type':'application/json','Accept':'application/json'})
    try:
        with (opener or build_opener(NoRedirect())).open(request,timeout=20) as response:
            if response.status!=200:raise ValueError('pin/gateway')
            raw=response.read(4*1024*1024+1)
        if len(raw)>4*1024*1024:raise ValueError('pin/size')
        return unwrap(json.loads(raw))
    except HTTPError as error:
        error.close();raise ValueError('pin/gateway_http') from None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes=0,authentication_posts=0,
        gateway_read_posts=0,credentials_written_to_files=False)
    saved=credentials=None;web=None;native=Reads()
    try:
        if args.saved_session:
            from verify_native_thought_trial import other_pending
            if other_pending():raise ValueError('pin/pending')
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid']);web=Web();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();channels={};models={}
            for index,query in enumerate(QUERIES):
                channels['native_'+str(index)],models['native_'+str(index)]=project(native.request('pin_shelf',BASE+'/shelf/sync'+query,credentials=credentials))
            channels['web'],models['web']=project(web.request('shelf',WEB+'/web/shelf/sync'))
            key=web.request('account',KEY_URL).get('apikey')
            report['gateway_key_available']=isinstance(key,str) and bool(key)
            if report['gateway_key_available']:
                report['gateway_read_posts']=1
                channels['gateway'],models['gateway']=project(gateway(key))
            key=None
            web.verify_account();save_refreshed_web_session(store,saved,web)
            baseline=models['native_0'];same_members=all(set(rows)==set(baseline) for rows in models.values())
            visible_other_flags_match=all(all(rows[key][field]==baseline[key][field] for key in baseline for field in ('private','finished')) for rows in models.values()) if same_members else False
            report.update(result='PIN_OBSERVABILITY_READ_VERIFIED',channels=channels,same_members=same_members,
                visible_other_flags_match=visible_other_flags_match,observable_pin_channels=[name for name,row in channels.items() if row['pinned'].get('true',0)+row['pinned'].get('false',0)>0])
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        report['native_stages']=[{key:row[key] for key in ('stage','status') if key in row} for row in native.report['stages']]
        if web:
            report['web_stages']=[{key:row[key] for key in ('stage','status') if key in row} for row in web.report['stages']];web.close()
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
