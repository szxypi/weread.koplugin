#!/usr/bin/env python3
"""Native private-reading UI with independent host reads after both changes.

Default is offline. A completed or interrupted apply intent cannot relaunch.
All credentials and source data reach the native supervisor through pipes.
"""
import argparse
from copy import deepcopy
import hashlib
import json
from urllib.parse import urlencode
from native_shelf_flag_trial import bind,check,validate_plan
from secure_native_shelf_flag_trial import NativeFlagTrialStore
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import canonical
from secure_weread_session import SessionStore
from verify_eink_login import NativeProbe,BASE
from finish_change_contract import flags
from verify_native_metadata import normalize_native
from verify_native_finish_trial import run as run_inspected,TrialFailure


class FlagTrialProbe(NativeProbe):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.bound=None;self.payload=None;self.targets=set()

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={BASE+'/shelf/sync'}|{BASE+'/book/'+route+'?'+urlencode(dict(bookId=identity))
            for identity in self.targets for route in ('getProgress','info')}
        if body is not None or url not in allowed:raise ValueError('native_shelf_flag/read_scope')
        return super().request(stage,url,credentials=credentials,timeout=timeout)

    def prepare(self,credentials):
        if self.bound is not None:raise ValueError('native_shelf_flag/already_prepared')
        shelf=self.request('private_shelf',BASE+'/shelf/sync',credentials=credentials);rows=flags(shelf)
        candidates=sorted(key for key,row in rows.items() if key.isascii() and key.isdigit() and not key.startswith('0')
                          and len(key)<=20 and row['private']=={'value':False})
        for identity in candidates[:3]:
            self.targets.add(identity)
            progress=self.request('private_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials)
            try:plan=bind(credentials['vid'],identity,hashlib.sha256(canonical(credentials)).hexdigest(),shelf,progress)
            except ValueError:continue
            self.bound=plan;break
        if self.bound is None:raise ValueError('native_shelf_flag/selection')
        metadata=normalize_native(self.request('private_metadata',BASE+'/book/info?'+urlencode(dict(bookId=identity)),credentials=credentials),identity)
        self.payload=dict(credentials=credentials,book_id=identity,expected_metadata=metadata,shelf_books=len(rows),
                          mark=deepcopy(plan['mark']),restore=deepcopy(plan['restore']))
        self.read(credentials,False);return self.bound

    def current(self,credentials):
        validate_plan(self.bound)
        if hashlib.sha256(canonical(credentials)).hexdigest()!=self.bound['grant_sha256']:raise ValueError('native_shelf_flag/grant')

    def read(self,credentials,private):
        self.current(credentials);identity=self.bound['book_id']
        shelf=self.request('private_independent_shelf',BASE+'/shelf/sync',credentials=credentials)
        progress=self.request('private_independent_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials)
        return check(self.bound,shelf,progress,private)


def run(*args,**kwargs):
    result=run_inspected(*args,**kwargs)
    result['intent_state']='retired' if kwargs.get('armed') else 'absent'
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--dry-run',action='store_true');mode.add_argument('--apply',action='store_true')
    mode.add_argument('--status',action='store_true');parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);credentials=probe=None;phase='init'
    try:
        if args.saved_session:
            store=NativeFlagTrialStore();state,_receipt=store.read()
            if args.status:
                report.update(result='PASS',intent_state=state['phase'] if state else 'absent')
                print(json.dumps(report,indent=2));return 0
            from verify_native_thought_trial import other_pending
            from secure_native_thought_trial import NativeThoughtTrialStore
            from secure_selection_trial import SelectionTrialStore
            if state is not None or other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('native_shelf_flag/pending')
            phase='load_session';owner=SessionStore().load()['vid'];credentials=NativeSessionStore().load(owner)
            phase='prepare';probe=FlagTrialProbe();probe.prepare(credentials)
            if args.apply or args.dry_run:
                if not args.native_ui_command:raise ValueError('native_shelf_flag/command')
                def current():
                    if NativeSessionStore().load(owner)!=credentials:raise ValueError('native_shelf_flag/grant_replaced')
                phase='apply' if args.apply else 'dry-run';report=run(probe,credentials,store,args.native_ui_command,armed=args.apply,current=current)
            elif args.native_ui_command:raise ValueError('native_shelf_flag/command')
            else:report.update(result='PASS',shelf_books=probe.payload['shelf_books'],public_selected=True,private_and_restore_plans=True,
                full_flags_groups_position_bound=True,intent_state='absent',reserved_posts=0)
        elif args.native_ui_command or any((args.apply,args.dry_run,args.status)):raise ValueError('native_shelf_flag/offline')
    except (Exception,KeyboardInterrupt) as error:
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=None if phase=='apply' else 0,authentication_posts=0,no_automatic_replay=True)
        if isinstance(error,TrialFailure):report.update(native_ui=error.runner,independent_steps=error.steps)
        try:
            state,_receipt=NativeFlagTrialStore().read();report['intent_state']=state['phase'] if state else 'absent'
        except Exception:report['intent_state']='unverified'
    finally:
        if credentials:credentials.clear()
        if probe:report['host_stages']=[{key:row[key] for key in ('stage','status') if key in row} for row in probe.report['stages']]
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
