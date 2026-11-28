#!/usr/bin/env python3
"""Read-only latest-article proof; private inputs pass only through memory."""
import argparse,json,re,resource,subprocess
from datetime import datetime,timezone
from urllib.parse import urlencode
from mp_subscription_trial import Journal
from native_time_capture import NativeCaptureStore
from readtime_history_capture import CaptureStore
from secure_translation_generation import TranslationGenerationStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_mp_catalog import book_id
from verify_mp_link import metadata,text_of
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe


def project(value,account):
    if not book_id(account) or not isinstance(value,dict):raise ValueError('mp_latest/invalid')
    for key in ('errCode','errcode'):
        if key in value and (type(value[key]) is not int or value[key]!=0):raise ValueError('mp_latest/invalid')
    review,title=value.get('reviewId'),value.get('title')
    if (not isinstance(review,str) or len(review)>512 or re.fullmatch(re.escape(account)+r'_[A-Za-z0-9_-]+',review) is None
            or not isinstance(title,str) or not title or len(title.encode())>4096 or re.search(r'[\x00-\x1f\x7f]',title)):
        raise ValueError('mp_latest/invalid')
    return dict(reviewId=review,title=title,bookId=account)


class Probe(WebSourceProbe):
    def __init__(self):super().__init__();self.allowed={};self.sent={'cover':0,'content':0}
    def guard(self,stage,url,body):
        if self.authenticated and body is None and self.allowed.get(stage)==url and self.sent.get(stage)==0:
            self.sent[stage]+=1;return
        return super().guard(stage,url,body)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.lua_command and not a.saved_session:p.error('--lua-command requires --saved-session')
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False)
    if not a.saved_session:print(json.dumps(report,indent=2));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=probe=None;phase='init';retained=None
    try:
        session=SessionStore();saved=session.load();probe=Probe();probe.vid=saved['vid']
        for k,v in saved['cookies'].items():probe.set_cookie(k,v)
        stores=[Journal(),TranslationGenerationStore(),NativeCaptureStore(),CaptureStore()];retained=[s.read() for s in stores]
        probe.verify_account();baseline=probe.request('shelf',BASE+'/web/shelf/sync')
        accounts=[book_id(row.get('bookId')) for row in baseline['books'] if isinstance(row,dict) and book_id(row.get('bookId'))]
        if not accounts:raise ValueError('mp_latest/no_account')
        account=accounts[0];phase='cover';probe.allowed['cover']=BASE+'/api/mp/cover?'+urlencode(dict(bookId=account))
        latest=project(probe.request('cover',probe.allowed['cover']),account)
        phase='content';probe.allowed['content']=BASE+'/web/mp/content?'+urlencode(dict(reviewId=latest['reviewId']))
        html=probe.request('content',probe.allowed['content'],as_json=False)
        if metadata(html).title!=latest['title'] or not text_of(html):raise ValueError('mp_latest/content')
        if a.lua_command:
            phase='lua';payload=json.dumps(dict(vid=saved['vid'],cookies=saved['cookies'],latest=latest),ensure_ascii=False).encode()
            child=subprocess.run(a.lua_command,input=payload,capture_output=True,timeout=90);frame=b'\nWEREAD_MP_LATEST_RESULT='
            if child.returncode or len(child.stdout)>65536 or child.stdout.count(frame)!=1:raise ValueError('mp_latest/lua')
            if json.loads(child.stdout.split(frame)[1])!={'matches':True,'requests':1}:raise ValueError('mp_latest/lua')
            report['native_lua_identity_and_title_match']=True
        phase='readback';after=probe.request('shelf',BASE+'/web/shelf/sync')
        if state_hash(after)!=state_hash(baseline) or [s.read() for s in stores]!=retained:raise ValueError('mp_latest/changed')
        report.update(result='LATEST_ARTICLE_VERIFIED',owner_verified=True,identity_and_title_match_body=True,shelf_and_previous_scopes_unchanged=True)
    except Exception:report.update(result='UNVERIFIED',phase=phase)
    finally:
        if probe and probe.authenticated and saved:
            try:probe.verify_account();save_refreshed_web_session(session,saved,probe);report['web_session_preserved']=True
            except Exception:report.update(result='UNVERIFIED',web_session_preserved=False)
        if probe:
            report['cover_requests']=probe.sent['cover'];report['content_requests']=probe.sent['content']
            report['stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in probe.report['stages']];probe.close()
        if saved:saved.clear()
    report['checked_at']=datetime.now(timezone.utc).isoformat();print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result']=='LATEST_ARTICLE_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
