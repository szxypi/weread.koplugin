#!/usr/bin/env python3
"""Independently reread a completed native pin trial without account writes."""
import argparse
import hashlib
import json
from urllib.parse import urlencode
from native_shelf_trial import check
from secure_native_session import NativeSessionStore
from secure_native_cloud_pin_trial import NativeCloudPinTrialStore
from secure_pin_trial import PinTrialStore,SERVICE_V3,validate as validate_trial
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_eink_login import BASE
from verify_pin_gateway import SERVICE,KeyWeb,gateway,validate
from verify_pin_preflight import PinProbe,fingerprint,reading_fingerprint
from verify_web_source_progress import BASE as WEB


def assess(state,read):
    validate_trial(state)
    if state['phase']!='restored':raise ValueError('native_pin/not_restored')
    for _ in range(2):
        sources,progress=read()
        if set(sources)!={'native','web','gateway'}:raise ValueError('native_pin/channels')
        for name,source in sources.items():check(state['plans'][name],source,False)
        if reading_fingerprint(progress)!=state['progress_sha256']:raise ValueError('native_pin/reading_changed')
    return dict(result='RESTORED_READBACK_VERIFIED',original_shelf_restored=True,
                reading_fields_unchanged=True,book_update_time_compared=False,readback_rounds=2,channels_per_round=3)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,gateway_read_posts=0,credentials_written_to_files=False)
    p=PinProbe();w=KeyWeb();credentials=saved=key=None
    try:
        if args.saved_session:
            state,_=PinTrialStore(service=SERVICE_V3).read();validate_trial(state)
            inner,_=NativeCloudPinTrialStore().read()
            if not inner or inner['phase']!='retired':raise ValueError('native_pin/inner_not_retired')
            saved=SessionStore().load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
            membership=state['plans']['native']['membership']
            if owner!=membership['owner'] or fingerprint(credentials)!=membership['grant_sha256']:raise ValueError('native_pin/owner')
            key_store=MacKeychain(service=SERVICE,account=ACCOUNT);key=validate(json.loads(key_store.load()),owner)['key']
            if hashlib.sha256(key.encode()).hexdigest()!=state['skill_sha256']:raise ValueError('native_pin/key')
            p.target=membership['book_id'];w.vid=owner
            for name,value in saved['cookies'].items():w.set_cookie(name,value)
            def read():
                if SessionStore().load()['vid']!=owner or NativeSessionStore().load(owner)!=credentials:raise ValueError('native_pin/owner')
                w.verify_account()
                sources={'native':p.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials),
                         'web':w.request('shelf',WEB+'/web/shelf/sync')}
                report['gateway_read_posts']+=1;sources['gateway']=gateway(key)
                progress=p.request('pin_progress',BASE+'/book/getProgress?'+urlencode({'bookId':p.target}),credentials=credentials)
                return sources,progress
            report.update(assess(state,read));w.verify_account();report['intent_state']=state['phase'];report['native_intent_state']=inner['phase']
    except (Exception,KeyboardInterrupt):report['result']='UNVERIFIED'
    finally:
        w.close();p.target=None;key=None
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
