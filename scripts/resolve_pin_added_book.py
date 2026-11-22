#!/usr/bin/env python3
"""Resolve only the added-book stage of an interrupted one-use pin trial."""
import argparse
import hashlib
import json
from urllib.parse import urlencode

from pin_trial_contract import verify
from secure_native_session import NativeSessionStore
from secure_pin_trial import PinTrialStore,SERVICE_V2
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_eink_login import BASE
from verify_finish_roundtrip import acknowledged
from verify_pin_gateway import SERVICE,KeyWeb,gateway,validate
from verify_pin_preflight import PinProbe,fingerprint,progress_fingerprint,reading_fingerprint
from verify_web_source_progress import BASE as WEB


def baseline(state,current,read,progress_digest=progress_fingerprint):
    values=[]
    for _ in range(2):
        current();sources,progress=read()
        if set(sources)!={'native','web','gateway'}:raise ValueError('cleanup/channels')
        target=verify(sources,state['plans'],True)
        if any(row['pinned']=={'value':True} for row in target.values()):raise ValueError('cleanup/pinned')
        values.append((target,progress_digest(progress)))
    if values[0]!=values[1]:raise ValueError('cleanup/unstable')
    return values[0]


def cleanup(store,current,read,remove,apply=False,*,progress_digest=progress_fingerprint,reading_only=False):
    state,raw=store.read()
    if not state or state['phase']!='add_acknowledged':raise ValueError('cleanup/phase')
    baseline(state,current,read,progress_digest)
    if not apply:return {'result':'CLEANUP_PREVIEW_VERIFIED','account_data_posts_attempted':0}
    _,raw=store.cleanup(raw)
    response=remove()
    if not acknowledged(response):raise ValueError('cleanup/receipt')
    for _ in range(2):
        current();sources,progress=read()
        verify(sources,state['plans'],False)
        if progress_digest(progress)!=state['progress_sha256']:raise ValueError('cleanup/progress')
    store.cleanup(raw,verified=True,reading_only=reading_only)
    return {'result':'ADDED_BOOK_REMOVED_AND_READING_VERIFIED' if reading_only else 'ADDED_BOOK_REMOVED_AND_ORIGINAL_VERIFIED',
            'account_data_posts_attempted':1}


class RemovalProbe(PinProbe):
    def __init__(self):super().__init__();self.permit=None;self.attempts=0;self.grant=None
    def guard(self,stage,url,body):
        if body is not None:
            if self.permit!=(stage,url,body):raise ValueError('cleanup/blocked')
            self.permit=None;return
        return super().guard(stage,url,body)
    def remove(self,credentials):
        if self.attempts or not self.target or fingerprint(credentials)!=self.grant:raise ValueError('cleanup/blocked')
        stage='cleanup_remove';url=BASE+'/shelf/delete';body={'bookIds':[self.target]}
        self.permit=(stage,url,body);self.attempts+=1
        try:return self.request(stage,url,body,credentials)
        finally:self.permit=None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true');parser.add_argument('--v2',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('--apply requires --saved-session')
    report={'result':'OFFLINE_ONLY','account_data_posts_attempted':0,'no_automatic_replay':True,'credentials_written_to_files':False}
    p=RemovalProbe();web=KeyWeb();store=PinTrialStore(service=SERVICE_V2) if args.v2 else PinTrialStore();saved=credentials=key=None
    try:
        if args.saved_session:
            state,_=store.read()
            if not state or state['phase']!='add_acknowledged':raise ValueError('cleanup/phase')
            saved=SessionStore().load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
            if state['plans']['native']['membership']['owner']!=owner or state['plans']['native']['membership']['grant_sha256']!=fingerprint(credentials):raise ValueError('cleanup/owner')
            key_store=MacKeychain(service=SERVICE,account=ACCOUNT);key=validate(json.loads(key_store.load()),owner)['key']
            if hashlib.sha256(key.encode()).hexdigest()!=state['skill_sha256']:raise ValueError('cleanup/key')
            p.target=state['plans']['native']['membership']['book_id'];p.grant=fingerprint(credentials);web.vid=owner
            for name,value in saved['cookies'].items():web.set_cookie(name,value)
            def current():
                if (SessionStore().load()['vid']!=owner or NativeSessionStore().load(owner)!=credentials
                    or hashlib.sha256(validate(json.loads(key_store.load()),owner)['key'].encode()).hexdigest()!=state['skill_sha256']):raise ValueError('cleanup/owner')
                web.verify_account()
            def read():
                sources={'native':p.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials),
                         'web':web.request('shelf',WEB+'/web/shelf/sync'),'gateway':gateway(key)}
                progress=p.request('pin_progress',BASE+'/book/getProgress?'+urlencode({'bookId':p.target}),credentials=credentials)
                return sources,progress
            report.update(cleanup(store,current,read,lambda:p.remove(credentials),apply=args.apply,
                                  progress_digest=reading_fingerprint if args.v2 else progress_fingerprint,reading_only=args.v2))
            if args.v2:report['progress_projection']='exclude_server_clock_and_book_update_time'
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if str(error) in {'cleanup/phase','cleanup/owner','cleanup/key','cleanup/channels','cleanup/pinned',
                          'cleanup/unstable','cleanup/receipt','cleanup/progress','native_shelf/presence',
                          'native_shelf/unrelated_change'}:report['detail']=str(error)
    finally:
        report['account_data_posts_attempted']=p.attempts
        try:
            state,_=store.read();report['intent_state']=state['phase'] if state else 'absent'
        except Exception:report['intent_state']='unknown'
        report['native_stages']=[{k:r[k] for k in ('stage','status') if k in r} for r in p.report['stages']]
        web.close();p.target=None;p.permit=None;key=None
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
