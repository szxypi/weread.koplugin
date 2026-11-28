#!/usr/bin/env python3
"""One synthetic-name COS credential observation; no file upload or notify.

Offline by default. The optional request creates temporary server credentials;
all returned values remain in memory and no private object is written.
"""
import argparse,json,re,resource,time
from datetime import datetime,timezone
from urllib.parse import urlencode
from mp_subscription_trial import Journal
from native_time_capture import NativeCaptureStore
from readtime_history_capture import CaptureStore
from secure_native_session import NativeSessionStore
from secure_translation_generation import TranslationGenerationStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE,NativeProbe

NAME='KOReaderValidation'
URL=BASE+'/cos/getcredential?'+urlencode(dict(name=NAME,**{'from':''}))


def project(value,now):
    if not isinstance(value,dict):raise ValueError('upload_preflight/invalid')
    response=value.get('Response');credentials=response.get('Credentials') if isinstance(response,dict) else None
    bucket,key=value.get('bucket'),value.get('ObjectName')
    if (not isinstance(bucket,str) or len(bucket)>128 or not re.fullmatch(r'[a-z0-9][a-z0-9-]*-[0-9]{1,20}',bucket)
            or not isinstance(key,str) or not 1<=len(key)<=2048 or re.search(r'[\x00-\x20\x7f\\?#]',key)
            or any(part in ('.','..') for part in key.split('/')) or not isinstance(credentials,dict)):
        raise ValueError('upload_preflight/invalid')
    for name in ('TmpSecretId','TmpSecretKey','Token'):
        item=credentials.get(name)
        if not isinstance(item,str) or not 1<=len(item)<=8192 or re.search(r'[\x00-\x20\x7f]',item):raise ValueError('upload_preflight/invalid')
    expiry=response.get('ExpiredTime')
    if type(expiry) is not int or not now<expiry<=now+86400:raise ValueError('upload_preflight/invalid')
    return dict(credentials_valid=True,object_path_safe=True,bucket_host_pattern_valid=True,expiration_in_future=True)


class Probe(NativeProbe):
    def __init__(self,opener=None):super().__init__(opener);self.requests=0
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if stage=='shelf' and url==BASE+'/shelf/sync' and body is None:return super().request(stage,url,credentials=credentials,timeout=timeout)
        if stage=='credential' and url==URL and body is None and self.requests==0:
            self.requests+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)
        raise ValueError('upload_preflight/scope')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');a=p.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',credential_requests=0,account_data_posts=0,authentication_posts=0,cos_uploads=0,
                notify_posts=0,private_data_on_regular_disk=False)
    if not a.saved_session:print(json.dumps(report,indent=2));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=probe=None;phase='init';baseline=None
    try:
        saved=SessionStore().load();store=NativeSessionStore();grant=store.load(saved['vid']);probe=Probe()
        stores=[Journal(),TranslationGenerationStore(),NativeCaptureStore(),CaptureStore()];retained=[s.read() for s in stores]
        phase='baseline';baseline=state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=grant))
        phase='credential';value=probe.request('credential',URL,credentials=grant);observation=project(value,int(time.time()))
        phase='readback'
        if state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=grant))!=baseline:raise ValueError('upload_preflight/changed')
        if store.load(saved['vid'])!=grant or [s.read() for s in stores]!=retained:raise ValueError('upload_preflight/changed')
        report.update(result='TEMPORARY_CREDENTIAL_OBSERVED',shelf_and_existing_scopes_unchanged=True,**observation)
    except Exception:report.update(result='UNVERIFIED',phase=phase)
    finally:
        if report['result']=='UNVERIFIED' and probe and probe.requests and baseline:
            try:report['failure_shelf_unchanged']=state_hash(probe.request('shelf',BASE+'/shelf/sync',credentials=grant))==baseline
            except Exception:report['failure_shelf_unchanged']=None
            try:report['previous_scopes_unchanged']=store.load(saved['vid'])==grant and [s.read() for s in stores]==retained
            except Exception:report['previous_scopes_unchanged']=None
        if probe:
            report['credential_requests']=probe.requests;report['stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in probe.report['stages']]
        if saved:saved.clear()
        if grant:grant.clear()
    report['checked_at']=datetime.now(timezone.utc).isoformat();print(json.dumps(report,indent=2))
    return 0 if report['result']=='TEMPORARY_CREDENTIAL_OBSERVED' else 1


if __name__=='__main__':raise SystemExit(main())
