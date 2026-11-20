#!/usr/bin/env python3
"""A distinct, single-use synthetic TXT import and native reading trial."""
import argparse
import hashlib
import json
import resource
import tempfile
from pathlib import Path

from cloud_group_nonempty_journal import Journal as GroupJournal
from personal_upload_trial import Journal as BaseJournal, check, hash_value, projection, validate
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cb_progress import cb_id
from verify_cb_txt_fixture import MARKER, Receipt, guarded_previous
from verify_cb_txt_native_fixture import (SingleJournal, command, previous_txt, previous_native,
                                          previous_native_short, verify_native)
from verify_eink_login import NativeProbe
from verify_personal_upload_trial import Probe
from verify_shelf_flags import WebFlagsProbe
from verify_synthetic_epub_upload import run

BODY = (MARKER + '\n' + ''.join(
    f'{i:03d} A second distinct line tests conversion of an uploaded plain text book.\n'
    f'{i:03d} A third original line exercises the native reading source without personal content.\n'
    for i in range(1, 33))).encode('utf-8')
BODY_HASH = hashlib.sha256(BODY).hexdigest()


def validate_plan(plan):
    validate(plan)
    if plan['body_sha256'] != BODY_HASH: raise ValueError('cb_txt_multipage/fixture')
    return plan


def prepare_plan(credentials, shelf, name):
    data=projection(shelf);data.pop('present')
    return validate_plan(dict(owner=credentials['vid'],name=name,body_sha256=BODY_HASH,
                              grant_sha256=hash_value(credentials),**data))


def check_plan(plan,credentials,shelf,target=None,expected=False):
    return check(plan,credentials,shelf,target,expected,validator=validate_plan)


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-cb-txt-multipage-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-cb-txt-multipage-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_plan)


def previous_single():
    state,token=SingleJournal().read()
    raw=Receipt(MacKeychain(service='org.codex.weread.goal-cb-txt-native-single-target-v1',account=ACCOUNT)).backend.load()
    value=json.loads(raw) if isinstance(raw,bytes) and len(raw)<=8192 else None
    if (not state or state['phase']!='restored' or not isinstance(value,dict)
            or set(value)!={'schema','owner','attempt','target','plan_sha256'} or value['schema']!=1
            or value['owner']!=state['plan']['owner'] or value['attempt']!=state['attempt']
            or value['target']!=state['target'] or value['plan_sha256']!=hash_value(state['plan'])
            or not cb_id(state['target'])):raise ValueError('cb_txt_multipage/previous')
    return state,token,raw


def execute(probe,journal,receipt,credentials,current,read_content,old_guard,previouses,*,apply=False,sleep=None,now=None):
    priors=tuple(getter() for getter in previouses)
    if (len(priors)!=4 or any(not row[0] or row[0]['plan']['owner']!=credentials['vid'] for row in priors)
            or receipt.backend.load() is not None or old_guard() is not True):raise ValueError('cb_txt_multipage/guard')
    def unchanged():return tuple(getter() for getter in previouses)==priors
    def record(j,r,p,target):
        if not unchanged() or target in {row[0]['target'] for row in priors}:raise ValueError('cb_txt_multipage/previous')
        receipt.record(j,r,p,target)
    def cleanup_gate(_j,_r,_p,target):
        group=GroupJournal();before=group.read()
        if (not before[0] or target in {row[0]['target'] for row in priors} or target==before[0]['target']
                or not unchanged() or old_guard() is not True):return False
        return group.read()==before and unchanged()
    kwargs={}
    if sleep is not None:kwargs['sleep']=sleep
    if now is not None:kwargs['now']=now
    return run(probe,journal,credentials,current,read_content,apply=apply,fixture_builder=lambda:BODY,
               prepare_plan=prepare_plan,check_plan=check_plan,fixture_extension='txt',readback_tries=7,
               notify_receipt=record,cleanup_gate=cleanup_gate,**kwargs)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--candidate')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('--apply requires --saved-session')
    if args.saved_session and not args.candidate:parser.error('saved session requires packaged candidate')
    if args.candidate:command(args.candidate,600,800,167)
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0)
    saved=grant=None;results=[]
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:
        if args.saved_session:
            session=SessionStore();saved=session.load();owner=saved['vid'];native_store=NativeSessionStore();grant=native_store.load(owner)
            def current(value=None):
                latest=session.load()
                return latest['vid']==owner and native_store.load(owner)==grant and (value is None or value==grant)
            def old_guard():
                snapshot=session.load()
                if snapshot['vid']!=owner:return False
                web=WebFlagsProbe();web.vid=owner
                for key,value in snapshot['cookies'].items():web.set_cookie(key,value)
                try:return guarded_previous(grant,lambda:session.load()==snapshot and native_store.load(owner)==grant,NativeProbe(),web)
                finally:web.close();snapshot.clear()
            journal=Journal();receipt=Receipt(MacKeychain(service='org.codex.weread.goal-cb-txt-multipage-target-v1',account=ACCOUNT))
            previouses=(previous_txt,previous_native,previous_native_short,previous_single)
            def read_content(target):
                for size in ((600,800,167),(1264,1680,300)):
                    result=dict(width=size[0],height=size[1],dpi=size[2],result='UNVERIFIED');results.append(result)
                    try:
                        if not verify_native(target,args.candidate,size,diagnostics=result):return False
                    except Exception:return False
                    result['result']='PASS'
                return True
            report=execute(Probe(journal,current),journal,receipt,grant,current,read_content,old_guard,previouses,apply=args.apply)
            report.update(native_sizes=results,old_group_guard_passed_after=old_guard(),prior_trials_unchanged=all(bool(f()) for f in previouses))
            report['account_data_writes']=report['notify_posts']+report['cleanup_posts']
    except Exception:
        report.update(result='UNVERIFIED',reason='cb_txt_multipage/guard_or_execution',authentication_posts=0,native_sizes=results)
        if args.apply:
            a,b=report.get('notify_posts'),report.get('cleanup_posts')
            report['account_data_writes']=a+b if type(a) is int and type(b) is int else None
    finally:
        if grant:grant.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','READ_ONLY_PREVIEW','TXT_IMPORT_AND_SOURCE_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
