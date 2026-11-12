#!/usr/bin/env python3
"""Read-only planning for the native single-operation completion strategy.

No account data POST in this host. All native changes use fresh production
previews and confirmations, and wait for independent host readback.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import secrets
import subprocess
import time
from urllib.parse import urlencode
from native_finish_trial import bind,check,validate_plan
from native_trial_pipe import Frames,write_initial,reply,stop
from secure_native_finish_trial import NativeFinishTrialStore
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import canonical
from secure_weread_session import SessionStore
from verify_eink_login import NativeProbe,BASE
from finish_change_contract import flags
from verify_native_metadata import normalize_native
from run_native_finish_trial import validate_stage


class TrialFailure(ValueError):
    def __init__(self,runner=None,steps=0):
        super().__init__('native_finish/unverified');self.runner=runner;self.steps=steps


class FinishTrialProbe(NativeProbe):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.bound=None;self.payload=None;self.targets=set()
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={BASE+'/shelf/sync'}|{BASE+'/book/'+route+'?'+urlencode(dict(bookId=identity))
            for identity in self.targets for route in ('getProgress','info')}
        if body is not None or url not in allowed:raise ValueError('native_finish/read_scope')
        return super().request(stage,url,credentials=credentials,timeout=timeout)
    def prepare(self,credentials):
        if self.bound is not None:raise ValueError('native_finish/already_prepared')
        shelf=self.request('finish_shelf',BASE+'/shelf/sync',credentials=credentials);rows=flags(shelf)
        candidates=sorted(key for key,row in rows.items() if key.isascii() and key.isdigit() and not key.startswith('0') and len(key)<=20
                          and row['finished']=={'value':False})
        for identity in candidates[:3]:
            self.targets.add(identity)
            progress=self.request('finish_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials)
            try:plan=bind(credentials['vid'],identity,hashlib.sha256(canonical(credentials)).hexdigest(),shelf,progress)
            except ValueError:continue
            self.bound=plan;break
        if self.bound is None:raise ValueError('native_finish/selection')
        metadata=normalize_native(self.request('finish_metadata',BASE+'/book/info?'+urlencode(dict(bookId=identity)),credentials=credentials),identity)
        self.payload=dict(credentials=credentials,book_id=identity,expected_metadata=metadata,shelf_books=len(rows),
                          mark=deepcopy(plan['mark']),restore=deepcopy(plan['restore']))
        self.read(credentials,False);return self.bound
    def current(self,credentials):
        validate_plan(self.bound)
        if hashlib.sha256(canonical(credentials)).hexdigest()!=self.bound['grant_sha256']:raise ValueError('native_finish/grant')
    def read(self,credentials,finished):
        self.current(credentials);identity=self.bound['book_id']
        shelf=self.request('finish_independent_shelf',BASE+'/shelf/sync',credentials=credentials)
        progress=self.request('finish_independent_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials)
        return check(self.bound,shelf,progress,finished)


def validate_result(value,armed):
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed','stage'}
            or value['result'] not in ('PASS','UNVERIFIED') or type(value['profile_removed']) is not bool):raise ValueError('native_finish/result')
    if value['stage'] is not None:validate_stage(value['stage'],armed)
    if value['result']=='PASS':
        item=value['installed']
        if (not value['profile_removed'] or value['stage'] is None or value['stage']['result']!='PASS'
                or not isinstance(item,dict) or set(item)!={'files','bytes_match'} or type(item['files']) is not int
                or not 1<=item['files']<=1000 or item['bytes_match'] is not True):raise ValueError('native_finish/installation')
    return value


def run(probe,credentials,store,command,*,armed=False,mock_port=None,current=None):
    if type(armed) is not bool or not command or any(not isinstance(v,str) or not v for v in command):raise ValueError('native_finish/command')
    if store.pending():raise ValueError('native_finish/pending')
    probe.current(credentials);probe.read(credentials,False);payload=deepcopy(probe.payload)
    payload.update(permit_writes=armed,rpc_token=secrets.token_hex(16))
    if mock_port is not None:payload['mock_port']=mock_port
    receipt=store.reserve(probe.bound) if armed else None
    child=frames=runner=None;steps=0;awaiting=None
    try:
        if current:current()
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'],timeout=300)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':runner=validate_result(value,armed);break
            awaiting=value.get('seq')
            if (not armed or set(value)!={'seq'} or type(awaiting) is not int or awaiting!=steps+1 or awaiting>2
                    or not store.owns(receipt,probe.bound)):raise ValueError('native_finish/step')
            if current:current()
            probe.read(credentials,awaiting==1);steps=awaiting
            reply(child.stdin,dict(seq=awaiting,ok=True));awaiting=None
        if child.wait(timeout=15) or steps!=(2 if armed else 0) or runner['result']!='PASS':raise ValueError('native_finish/child')
        if runner['stage']['shelf_books']!=payload['shelf_books']:raise ValueError('native_finish/receipt')
        if current:current()
        probe.read(credentials,False)
        if receipt:store.finish(receipt,restored_verified=True)
        if store.pending():raise ValueError('native_finish/cleanup')
        return dict(result='PASS',mode='apply' if armed else 'dry-run',native_ui=runner,independent_steps=steps,
            account_data_posts=2 if armed else 0,authentication_posts=0,reserved_posts=2 if armed else 0,
            original_flags_groups_and_exact_position_restored=True,intent_state='absent',no_automatic_replay=True)
    except (Exception,KeyboardInterrupt):
        if child is not None and frames is not None and child.poll() is None and awaiting is not None:
            try:
                reply(child.stdin,dict(seq=awaiting,ok=False));frames.deadline=time.monotonic()+15
                kind,value=frames.next()
                if kind=='RESULT':runner=validate_result(value,armed)
                child.wait(timeout=10)
            except Exception:pass
        raise TrialFailure(runner,steps) from None
    finally:
        if child is not None:stop(child)
        payload.clear()


def resolve(credentials,store,probe=None):
    value,receipt=store.read()
    if value is None:return dict(result='PASS',intent_state='absent',account_data_posts=0,authentication_posts=0)
    plan=value['plan'];validate_plan(plan)
    if credentials['vid']!=plan['owner']:raise ValueError('native_finish/owner')
    probe=probe or FinishTrialProbe();probe.targets={plan['book_id']}
    for _i in range(2):
        shelf=probe.request('finish_resolution_shelf',BASE+'/shelf/sync',credentials=credentials)
        progress=probe.request('finish_resolution_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=plan['book_id'])),credentials=credentials)
        check(plan,shelf,progress,False)
    store.finish(receipt,restored_verified=True)
    return dict(result='PASS',intent_state='absent',account_data_posts=0,authentication_posts=0,
        original_flags_groups_and_exact_position_restored=True,prior_native_trial_success_claimed=False,no_automatic_replay=True)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--dry-run',action='store_true');mode.add_argument('--apply',action='store_true')
    mode.add_argument('--status',action='store_true');mode.add_argument('--resolve',action='store_true')
    parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);credentials=probe=None;phase='init'
    try:
        if args.saved_session:
            store=NativeFinishTrialStore()
            if args.status:
                report.update(result='PASS',intent_state='pending' if store.pending() else 'absent')
                print(json.dumps(report,indent=2));return 0
            from verify_native_thought_trial import other_pending
            from secure_native_thought_trial import NativeThoughtTrialStore
            from secure_selection_trial import SelectionTrialStore
            if other_pending(exclude_native_finish=True) or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('native_finish/pending')
            phase='load_session';owner=SessionStore().load()['vid'];credentials=NativeSessionStore().load(owner)
            if args.resolve:phase='resolve';report=resolve(credentials,store)
            else:
                if store.pending():raise ValueError('native_finish/pending')
                phase='prepare';probe=FinishTrialProbe();probe.prepare(credentials)
                if args.apply or args.dry_run:
                    if not args.native_ui_command:raise ValueError('native_finish/command')
                    def current():
                        if NativeSessionStore().load(owner)!=credentials:raise ValueError('native_finish/grant_replaced')
                    phase='apply' if args.apply else 'dry-run';report=run(probe,credentials,store,args.native_ui_command,armed=args.apply,current=current)
                elif args.native_ui_command:raise ValueError('native_finish/command')
                else:report.update(result='PASS',shelf_books=probe.payload['shelf_books'],unfinished_selected=True,mark_and_restore_plans=True,
                    full_flags_groups_position_bound=True,intent_state='absent',reserved_posts=0)
        elif args.native_ui_command or any((args.apply,args.dry_run,args.resolve,args.status)):raise ValueError('native_finish/offline')
    except (Exception,KeyboardInterrupt) as error:
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=None if phase=='apply' else 0,authentication_posts=0,no_automatic_replay=True)
        if isinstance(error,TrialFailure):report.update(native_ui=error.runner,independent_steps=error.steps)
        try:report['intent_state']='pending' if NativeFinishTrialStore().pending() else 'absent'
        except Exception:report['intent_state']='unverified'
    finally:
        if credentials:credentials.clear()
        if probe:report['host_stages']=[{key:row[key] for key in ('stage','status') if key in row} for row in probe.report['stages']]
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
