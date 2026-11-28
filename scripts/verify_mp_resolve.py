#!/usr/bin/env python3
"""Read-only WeChat article URL resolution; offline unless explicitly requested.

Protocol reference: weread-omni 0.1.2, MIT, public-accounts.js. The lookup
POST is scoped to one validated URL and cannot mutate shelf or reading state.
"""
import argparse,json,re,resource,subprocess
from datetime import datetime,timezone
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from secure_translation_generation import TranslationGenerationStore
from native_time_capture import NativeCaptureStore
from readtime_history_capture import CaptureStore
from verify_eink_login import BASE,NativeProbe
from verify_mp_catalog import KNOWN_REVIEW,article_projection
from verify_mp_export import ExportProbe
from verify_mp_link import canonical,metadata,text_of
from verify_translation_preflight import save_refreshed_web_session
from shelf_flag_change_contract import state_hash


def project(source,raw,known=None):
    source=canonical(source)
    if not source or not isinstance(raw,dict) or not isinstance(raw.get('reviewIds'),list) or len(raw['reviewIds'])!=1:raise ValueError('mp_resolve/response')
    row=raw['reviewIds'][0]
    if not isinstance(row,dict) or canonical(row.get('url'))!=source:raise ValueError('mp_resolve/source')
    review=row.get('reviewId')
    if not isinstance(review,str) or not 1<=len(review)<=512 or re.search(r'[\x00-\x20\x7f]',review):raise ValueError('mp_resolve/identity')
    if known is not None:
        match=re.fullmatch(r'MP_WXS_[0-9]+_(.+)',known)
        if not match or review not in (known,match.group(1)):raise ValueError('mp_resolve/mismatch')
    return review


def same_article(first,second):
    title=metadata(first).title
    body=text_of(first)
    return bool(title and title==metadata(second).title and body and body==text_of(second)
                and article_projection(first)==article_projection(second))


class Probe(NativeProbe):
    def __init__(self,source,opener=None):
        super().__init__(opener);self.source=canonical(source);self.lookups=0
        if not self.source:raise ValueError('mp_resolve/source')
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if stage=='shelf' and url==BASE+'/shelf/sync' and body is None:return super().request(stage,url,credentials=credentials,timeout=timeout)
        if stage=='lookup' and url==BASE+'/mp/getreviewid' and body=={'urls':[self.source]} and self.lookups==0:
            self.lookups+=1;return super().request(stage,url,body=body,credentials=credentials,timeout=timeout)
        raise ValueError('mp_resolve/scope')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.lua_command and not a.saved_session:p.error('--lua-command requires --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),lookup_posts=0,account_data_posts=0,
        authentication_posts=0,private_data_on_regular_disk=False)
    if not a.saved_session:print(json.dumps(report,indent=2));return 0
    saved=grant=web=api=None;baseline=original=retained=None;phase='init';stores=[]
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0));session=SessionStore();saved=session.load();grant=NativeSessionStore().load(saved['vid'])
        stores=[TranslationGenerationStore(),NativeCaptureStore(),CaptureStore()];retained=[s.read() for s in stores]
        web=ExportProbe();web.vid=saved['vid']
        for k,v in saved['cookies'].items():web.set_cookie(k,v)
        web.verify_account();original=web.content();source=metadata(original).source
        if not source:raise ValueError('mp_resolve/source')
        api=Probe(source);phase='baseline';baseline=state_hash(api.request('shelf',BASE+'/shelf/sync',credentials=grant))
        phase='lookup';raw=api.request('lookup',BASE+'/mp/getreviewid',body={'urls':[source]},credentials=grant)
        resolved=project(source,raw,KNOWN_REVIEW)
        if a.lua_command:
            phase='native_lua_lookup';report['native_lua_lookup_attempted']=True
            payload=json.dumps(dict(source=source,credentials=grant,cookies=saved['cookies'],expected=KNOWN_REVIEW,expected_title=metadata(original).title)).encode()
            completed=subprocess.run(a.lua_command,input=payload,capture_output=True,timeout=90)
            frame=b'\nWEREAD_MP_LINK_RESULT='
            if completed.returncode or len(completed.stdout)>65536 or completed.stdout.count(frame)!=1:raise ValueError('mp_resolve/lua')
            result=json.loads(completed.stdout.split(frame)[1])
            if result!={'ok':True,'native_requests':1,'web_requests':1,'title_matches':True}:raise ValueError('mp_resolve/lua')
            report['native_lua_identity_matched']=True
        phase='independent_readback'
        if state_hash(api.request('shelf',BASE+'/shelf/sync',credentials=grant))!=baseline or not same_article(original,web.content()):raise ValueError('mp_resolve/changed')
        web.verify_account()
        if NativeSessionStore().load(saved['vid'])!=grant or [s.read() for s in stores]!=retained:raise ValueError('mp_resolve/scope_changed')
        save_refreshed_web_session(session,saved,web)
        report.update(result='PASS_REAL_MP_RESOLUTION',source_and_review_identity_matched=True,resolved_full_identity=resolved==KNOWN_REVIEW,shelf_and_article_unchanged=True,
            native_grant_and_retained_scopes_unchanged=True)
    except Exception as error:
        report.update(result='UNVERIFIED',phase=phase)
        if str(error) in ('mp_resolve/response','mp_resolve/source','mp_resolve/identity','mp_resolve/mismatch','mp_resolve/changed','mp_resolve/scope_changed','mp_resolve/lua'):report['reason']=str(error)
    finally:
        if report['result']=='UNVERIFIED' and api and api.lookups:
            try:report['failure_shelf_unchanged']=state_hash(api.request('shelf',BASE+'/shelf/sync',credentials=grant))==baseline
            except Exception:report['failure_shelf_unchanged']=None
            try:report['failure_article_unchanged']=same_article(original,web.content())
            except Exception:report['failure_article_unchanged']=None
            try:report['retained_scopes_unchanged']=([s.read() for s in stores]==retained and NativeSessionStore().load(saved['vid'])==grant)
            except Exception:report['retained_scopes_unchanged']=None
        if report['result']=='UNVERIFIED' and web and saved:
            try:
                web.verify_account();save_refreshed_web_session(session,saved,web)
            except Exception:report['web_session_preserved']=False
        if api:
            report['lookup_posts']=api.lookups;report['native_stages']=[{k:v[k] for k in ('stage','status','error_code') if k in v} for v in api.report['stages']]
        if web:
            report['web_stages']=[{k:v[k] for k in ('stage','status','api_code') if k in v} for v in web.report['stages']];web.close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
