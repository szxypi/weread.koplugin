#!/usr/bin/env python3
"""Bounded native membership trial with independent host reads after each POST.

Offline by default. The host only reads; production native controls perform the
two writes. Both slots are reserved before launch in a distinct durable intent.
Unknown writes stop and block a new trial. --resolve only accepts a freshly
verified original membership/flag/group projection and never changes the cloud.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import secrets
import subprocess
import time
from native_shelf_trial import bind,check,validate_plan
from native_trial_pipe import Frames,write_initial,reply,stop
from owner_shelf_membership_contract import FRAME,decode_runner
from secure_native_shelf_trial import NativeShelfTrialStore
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import canonical,fingerprint
from secure_weread_session import SessionStore
from verify_eink_login import BASE
from verify_native_discovery import DiscoveryProbe
from verify_owner_shelf_membership import prepare


class ShelfTrialProbe(DiscoveryProbe):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.source=None;self.bound=None;self.payload=None

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        value=super().request(stage,url,body,credentials,timeout)
        if self.bound is None and stage=='discovery_shelf':self.source=deepcopy(value)
        return value

    def prepare(self,credentials):
        if self.bound is not None:raise ValueError('native_shelf/already_prepared')
        membership,self.payload=prepare(credentials,self)
        self.bound=bind(membership,self.source);self.source=None
        return self.bound

    def current(self,credentials):
        validate_plan(self.bound)
        if self.bound['membership']['grant_sha256']!=hashlib.sha256(canonical(credentials)).hexdigest():
            raise ValueError('native_shelf/grant_changed')

    def read(self,credentials,present):
        self.current(credentials)
        value=self.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials)
        check(self.bound,value,present)
        return True


class TrialFailure(ValueError):
    def __init__(self,runner=None,steps=0):
        super().__init__('native_shelf/unverified');self.runner=runner;self.steps=steps


def validate_result(value,armed):
    if not isinstance(value,dict) or set(value)!={'runner','installed'}:raise ValueError('native_shelf/runner')
    envelope=decode_runner(FRAME+json.dumps(value['runner']).encode(),armed)
    installed=value['installed']
    if envelope['report']['result']=='PASS' and (not isinstance(installed,dict) or set(installed)!={'files','bytes_match'}
            or type(installed['files']) is not int or not 1<=installed['files']<=1000 or installed['bytes_match'] is not True):
        raise ValueError('native_shelf/installation')
    return envelope,installed


def public_result(value,armed):
    envelope,installed=validate_result(value,armed)
    return dict(**envelope['report'],installed=installed)


def run(probe,credentials,store,command,*,armed=False,mock_port=None,current=None):
    if type(armed) is not bool or not command or any(not isinstance(v,str) or not v for v in command):raise ValueError('native_shelf/command')
    if store.pending():raise ValueError('native_shelf/pending')
    probe.current(credentials);probe.read(credentials,False)
    payload=deepcopy(probe.payload);token=secrets.token_hex(16)
    payload.update(permit_writes=armed,plan_fingerprint=fingerprint(probe.bound['membership']),intent_digest='',host_steps=dict(rpc_token=token))
    if mock_port is not None:payload['mock_port']=mock_port
    receipt=store.reserve(probe.bound) if armed else None
    if receipt:payload['intent_digest']=hashlib.sha256(receipt.pending).hexdigest()
    child=frames=runner=None;steps=0;awaiting=None
    try:
        if current:current()
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=240)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':runner=value;envelope,_installed=validate_result(value,armed);break
            awaiting=value.get('seq')
            if (not armed or set(value)!={'seq'} or type(awaiting) is not int or awaiting!=steps+1 or awaiting>2
                    or not store.owns(receipt,probe.bound)):raise ValueError('native_shelf/step')
            if current:current()
            probe.read(credentials,awaiting==1);steps=awaiting
            reply(child.stdin,dict(seq=awaiting,ok=True));awaiting=None
        if child.wait(timeout=15) or steps!=(2 if armed else 0) or envelope['report']['result']!='PASS':raise ValueError('native_shelf/child')
        private=envelope['private']
        if (private['plan_fingerprint']!=payload['plan_fingerprint'] or private['intent_digest']!=payload['intent_digest']
                or private['final_members_digest']!=probe.bound['membership']['members_sha256']
                or envelope['report']['stage']['shelf_books']!=payload['shelf_books']):raise ValueError('native_shelf/receipt')
        if current:current()
        probe.read(credentials,False)
        if receipt:store.finish(receipt,restored_verified=True)
        if store.pending():raise ValueError('native_shelf/cleanup')
        return dict(result='PASS',mode='apply' if armed else 'dry-run',native_ui=public_result(runner,armed),
            independent_steps=steps,account_data_posts=2 if armed else 0,authentication_posts=0,reserved_posts=2 if armed else 0,
            original_members_flags_groups_restored=True,intent_state='absent',no_automatic_replay=True)
    except (Exception,KeyboardInterrupt):
        if child is not None and frames is not None and child.poll() is None and awaiting is not None:
            try:
                reply(child.stdin,dict(seq=awaiting,ok=False));frames.deadline=time.monotonic()+15
                kind,value=frames.next()
                if kind=='RESULT':runner=value;validate_result(value,armed)
                child.wait(timeout=10)
            except Exception:pass
        safe=None
        try:
            if runner is not None:safe=public_result(runner,armed)
        except ValueError:pass
        raise TrialFailure(safe,steps) from None
    finally:
        if child is not None:stop(child)
        payload.clear()


def resolve(credentials,store,probe=None):
    value,receipt=store.read()
    if value is None:return dict(result='PASS',intent_state='absent',account_data_posts=0,authentication_posts=0)
    plan=value['plan'];validate_plan(plan)
    if credentials['vid']!=plan['membership']['owner']:raise ValueError('native_shelf/owner')
    probe=probe or DiscoveryProbe()
    # Two independent current reads. No dispatch count or successful trial is
    # inferred from a restored state; only this pending intent is resolved.
    for _i in range(2):check(plan,probe.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials),False)
    store.finish(receipt,restored_verified=True)
    return dict(result='PASS',intent_state='absent',account_data_posts=0,authentication_posts=0,restored_projection_verified=True,
                prior_native_trial_success_claimed=False,no_automatic_replay=True)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--dry-run',action='store_true');mode.add_argument('--apply',action='store_true')
    mode.add_argument('--status',action='store_true');mode.add_argument('--resolve',action='store_true')
    parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);credentials=probe=None;phase='init'
    try:
        if args.saved_session:
            store=NativeShelfTrialStore()
            if args.status:report.update(result='PASS',intent_state='pending' if store.pending() else 'absent')
            else:
                from verify_native_thought_trial import other_pending
                from secure_native_thought_trial import NativeThoughtTrialStore
                from secure_selection_trial import SelectionTrialStore
                if other_pending(exclude_native_shelf=True) or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():
                    raise ValueError('native_shelf/other_pending')
                phase='load_session';saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid'])
                if args.resolve:phase='resolve';report=resolve(credentials,store)
                else:
                    if not args.native_ui_command or not (args.apply or args.dry_run) or store.pending():raise ValueError('native_shelf/command')
                    phase='prepare';probe=ShelfTrialProbe();probe.prepare(credentials)
                    def current():
                        if NativeSessionStore().load(saved['vid'])!=credentials:raise ValueError('native_shelf/grant_replaced')
                    phase='apply' if args.apply else 'dry-run'
                    report=run(probe,credentials,store,args.native_ui_command,armed=args.apply,current=current)
        elif args.native_ui_command or any((args.apply,args.dry_run,args.status,args.resolve)):raise ValueError('native_shelf/offline')
    except (Exception,KeyboardInterrupt) as error:
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=0 if phase!='apply' else None,
                    authentication_posts=0,no_automatic_replay=True)
        if isinstance(error,TrialFailure):report.update(native_ui=error.runner,independent_steps=error.steps)
        try:report['intent_state']='pending' if NativeShelfTrialStore().pending() else 'absent'
        except Exception:report['intent_state']='unverified'
    finally:
        if probe:report['host_stages']=[{key:row[key] for key in ('stage','status') if key in row} for row in probe.report['stages']]
        if credentials:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
