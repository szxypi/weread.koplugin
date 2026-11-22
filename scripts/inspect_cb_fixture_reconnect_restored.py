#!/usr/bin/env python3
"""Independently reread the consumed reconnect fixture after its removal."""
import argparse
import json
import resource

from cb_existing_position_intent import digest
from cloud_group_contract import project
from reading_epub_trial import check as check_plan
from secure_native_session import NativeSessionStore
from secure_weread_session import ACCOUNT,SessionStore
from verify_cb_fixture_reconnect_trial import stores
from verify_personal_upload_trial import Probe as UploadProbe
from verify_web_source_progress import BASE as WEB,WebSourceProbe


def assess(plan,target,grant,read):
    previous=None
    for _ in range(2):
        native,web=read();check_plan(plan,grant,native,target,False)
        projected=project(web)
        if target in projected['members'] or project(native)['members']!=projected['members']:raise ValueError('readback/members')
        if previous is not None and projected!=previous:raise ValueError('readback/unstable')
        previous=projected
    return dict(result='RESTORED_READBACK_VERIFIED',rounds=2,native_original_shelf_verified=True,
                web_absent_and_members_match=True,position_posts=0,cleanup_posts=0)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',position_posts=0,cleanup_posts=0,authentication_posts=0)
    if not args.saved_session:print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        saved=SessionStore().load();owner=saved['vid'];native_store=NativeSessionStore();grant=native_store.load(owner)
        journal,initial,manual=stores();upload,_=journal.read()
        if not upload or upload['phase']!='restored' or upload['plan']['owner']!=owner:raise ValueError('readback/scope')
        target=upload['target'];values=[]
        for store,count in ((initial,1),(manual,4)):
            raw=store.backend.load();value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','owner','book','attempt','baseline','claimed'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or value['owner']!=digest(owner) or value['book']!=digest(target) or value['attempt']!=upload['attempt']
                    or type(value['claimed']) is not int or value['claimed']!=count or not store.verify(value,raw)):
                raise ValueError('readback/intent')
            values.append(value)
        if values[0]['baseline']!=values[1]['baseline']:raise ValueError('readback/intent')
        probe=UploadProbe(journal,lambda value:native_store.load(owner)==value)
        def read():
            if SessionStore().load()['vid']!=owner or native_store.load(owner)!=grant:raise ValueError('readback/session')
            native=probe.shelf(grant);web=WebSourceProbe();web.vid=owner
            try:
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account();raw=web.request('shelf',WEB+'/web/shelf/sync');web.verify_account();return native,raw
            finally:web.close()
        report.update(assess(upload['plan'],target,grant,read),upload_state='restored',initial_slots=1,reconnect_slots=4,
                      authentication_posts=0,private_data_in_report=False)
    except Exception:report['result']='UNVERIFIED'
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result']!='RESTORED_READBACK_VERIFIED')

if __name__=='__main__':raise SystemExit(main())
