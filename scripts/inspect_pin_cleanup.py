#!/usr/bin/env python3
"""Independently inspect the interrupted pin cleanup without account writes."""
import argparse
import hashlib
import json
from urllib.parse import urlencode
from native_shelf_trial import check
from secure_native_session import NativeSessionStore
from secure_pin_trial import PinTrialStore
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_eink_login import BASE
from verify_pin_gateway import SERVICE,KeyWeb,gateway,validate
from verify_pin_preflight import PinProbe,progress_fingerprint
from verify_web_source_progress import BASE as WEB


def assess(state,read):
    if not state or state['phase']!='add_cleanup_pending':raise ValueError('inspection/phase')
    observations=[];progress=[]
    for _ in range(2):
        sources,position=read()
        if set(sources)!={'native','web','gateway'}:raise ValueError('inspection/channels')
        for name,source in sources.items():check(state['plans'][name],source,False)
        digest=progress_fingerprint(position);progress.append(digest)
        observations.append(digest==state['progress_sha256'])
    return {'result':'READBACK_VERIFIED','original_shelf_restored':True,
            'progress_matches_before_add':all(observations),
            'current_progress_stable':progress[0]==progress[1],
            'readback_rounds':2,'channels_per_round':3}


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report={'result':'OFFLINE_ONLY','account_data_writes':0,'credentials_written_to_files':False}
    p=PinProbe();w=KeyWeb();credentials=saved=key=None
    try:
        if args.saved_session:
            state,_=PinTrialStore().read()
            if not state or state['phase']!='add_cleanup_pending':raise ValueError('inspection/phase')
            saved=SessionStore().load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
            if owner!=state['plans']['native']['membership']['owner']:raise ValueError('inspection/owner')
            key=validate(json.loads(MacKeychain(service=SERVICE,account=ACCOUNT).load()),owner)['key']
            if hashlib.sha256(key.encode()).hexdigest()!=state['skill_sha256']:raise ValueError('inspection/key')
            p.target=state['plans']['native']['membership']['book_id'];w.vid=owner
            for name,value in saved['cookies'].items():w.set_cookie(name,value)
            def read():
                w.verify_account()
                sources={'native':p.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials),
                         'web':w.request('shelf',WEB+'/web/shelf/sync'),'gateway':gateway(key)}
                position=p.request('pin_progress',BASE+'/book/getProgress?'+urlencode({'bookId':p.target}),credentials=credentials)
                return sources,position
            report.update(assess(state,read));w.verify_account();report['intent_state']=state['phase']
    except (Exception,KeyboardInterrupt):report['result']='UNVERIFIED'
    finally:
        w.close();p.target=None;key=None
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
