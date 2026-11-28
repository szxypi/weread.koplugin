#!/usr/bin/env python3
"""Read-only by default; explicit --apply-private claims two once-only writes."""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import hashlib
import json
import subprocess
from urllib.parse import urlencode
from finish_change_contract import flags
from secure_shelf_experiment import canonical
from secure_shelf_flag_trial import FlagTrialStore
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import make,check,request,state_hash,position
from verify_eink_login import NativeProbe,BASE
from verify_finish_roundtrip import acknowledged
from verify_shelf_flags import WebFlagsProbe
from verify_web_source_progress import BASE as WEB
from verify_translation_preflight import save_refreshed_web_session
from my_cloud_marks_model import identifier


def digest(value):return hashlib.sha256(canonical(value)).hexdigest()


class Probe(NativeProbe):
    def __init__(self,opener=None):super().__init__(opener);self.grant=None;self.target=None;self.posts=0;self.dispatch=None
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if self.grant!=digest(credentials):raise ValueError('shelf_flag/grant')
        if body is None:
            allowed={BASE+'/shelf/sync'}
            if self.target:allowed|={BASE+'/book/'+path+'?'+urlencode({'bookId':self.target}) for path in ('getProgress','info')}
            if url not in allowed:raise ValueError('shelf_flag/read_scope')
        else:
            if not self.dispatch or self.posts>=2 or url!=BASE+'/book/secret' or body!=request('private',self.target,self.posts==0):raise ValueError('shelf_flag/write_scope')
            self.dispatch();self.posts+=1
        return super().request(stage,url,body,credentials,timeout)
    def observe(self,credentials):
        shelf=self.request('flag_shelf',BASE+'/shelf/sync',credentials=credentials)
        point=self.request('flag_position',BASE+'/book/getProgress?'+urlencode({'bookId':self.target}),credentials=credentials)
        return shelf,point
    def prepare(self,credentials,owner):
        self.grant=digest(credentials);first=self.request('flag_shelf',BASE+'/shelf/sync',credentials=credentials);rows=flags(first)
        candidates=sorted(key for key,row in rows.items() if identifier(key) and row['private']=={'value':False})
        plan=None
        for key in candidates[:3]:
            self.target=key
            progress=self.request('flag_position',BASE+'/book/getProgress?'+urlencode({'bookId':key}),credentials=credentials)
            try:
                change=make(first,progress,key,'private',True);changed=deepcopy(first)
                next(row for row in changed['books'] if str(row['bookId'])==key)['secret']=1
                restore=make(changed,progress,key,'private',False)
            except ValueError:continue
            plan=dict(owner=owner,grant_sha256=self.grant,change=change['metadata'],restore=restore['metadata']);break
        if plan is None:raise ValueError('shelf_flag/no_public_sample')
        second,progress=self.observe(credentials)
        if make(second,progress,self.target,'private',True)['metadata']!=plan['change']:raise ValueError('shelf_flag/changed')
        return plan,second,progress


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply-private',action='store_true');parser.add_argument('--lua-model-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_model_command and not args.saved_session:parser.error('--lua-model-command requires --saved-session')
    if args.apply_private and not args.saved_session:parser.error('--apply-private requires --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,credentials_written_to_files=False)
    credentials={};probe=None;trial=None
    try:
        if args.saved_session:
            from verify_native_thought_trial import other_pending
            if other_pending():raise ValueError('shelf_flag/other_pending')
            session=SessionStore();saved=session.load();owner=saved['vid']
            credentials=NativeSessionStore().load(owner);probe=Probe();plan,shelf,progress=probe.prepare(credentials,owner)
            web=WebFlagsProbe();web.vid=owner
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();web_shelf=web.request('shelf',WEB+'/web/shelf/sync');web.verify_account()
            save_refreshed_web_session(session,saved,web)
            if flags(web_shelf)!=flags(shelf):raise ValueError('shelf_flag/channels_differ')
            report.update(result='PRIVATE_FLAG_READ_ONLY_PLAN_VERIFIED',shelf_books=len(flags(shelf)),private_before=False,private_desired=True,
                private_restore=False,pinned_observable=sum('value' in row['pinned'] for row in flags(shelf).values()),channels_match=True)
            metadata=probe.request('flag_metadata',BASE+'/book/info?'+urlencode({'bookId':probe.target}),credentials=credentials)
            containers=[metadata]+[metadata[key] for key in ('book','data','bookInfo') if isinstance(metadata.get(key),dict)]
            from shelf_flags_contract import flag
            report['metadata_pin_values_provided']=sum('value' in flag(row,'isTop') for row in containers)
            report['known_root_pin_lists_present']=sum(key in shelf or key in web_shelf for key in ('top','tops','topBooks','topBookIds','pinnedBooks','pinnedBookIds'))
            if args.lua_model_command:
                payload=dict(shelf=shelf,progress=progress,book_id=probe.target,expected=[plan['change'],plan['restore']])
                child=subprocess.run(args.lua_model_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=60)
                frame=b'\nWEREAD_SHELF_FLAG_MODEL='
                if child.returncode or len(child.stdout)>1024*1024 or child.stdout.count(frame)!=1:raise ValueError('shelf_flag/lua')
                if json.loads(child.stdout.split(frame)[1])!=payload['expected']:raise ValueError('shelf_flag/model_differs')
                report['lua_model_matches']=True
            if args.apply_private:
                trial=FlagTrialStore();receipt=trial.reserve(plan)
                for step,before_phase,pending_phase,after_phase,desired in (
                    ('change','prepared','change_pending','change_verified',True),('restore','change_verified','restore_pending','retired',False)):
                    if digest(NativeSessionStore().load(owner))!=plan['grant_sha256']:raise ValueError('shelf_flag/grant_changed')
                    observed,point=probe.observe(credentials)
                    if make(observed,point,probe.target,'private',desired)['metadata']!=plan[step]:raise ValueError('shelf_flag/changed')
                    def claim():
                        nonlocal receipt
                        receipt=trial.advance(receipt,before_phase,pending_phase)
                    probe.dispatch=claim
                    response=probe.request('flag_private_write',BASE+'/book/secret',request('private',probe.target,desired),credentials)
                    probe.dispatch=None
                    report[step+'_acknowledged']=acknowledged(response)
                    report[step+'_receipt_fields']={key:type(response[key]).__name__ for key in ('succ','success','errcode','errCode','private','secret') if key in response}
                    observed,point=probe.observe(credentials)
                    report[step+'_independent_readback']=check(observed,point,plan[step])
                    if not report[step+'_acknowledged'] or not report[step+'_independent_readback']:raise ValueError('shelf_flag/unconfirmed')
                    receipt=trial.advance(receipt,pending_phase,after_phase)
                report.update(result='PRIVATE_FLAG_ROUNDTRIP_VERIFIED',private_restored=True,other_flags_groups_and_position_unchanged=True)
    except Exception:report.update(result='UNVERIFIED',reason='shelf_flag_verification_failed')
    finally:
        if probe:report.update(account_data_posts=probe.posts,stages=[{key:row[key] for key in ('stage','status','error_code') if key in row} for row in probe.report['stages']])
        if trial:
            try:report['trial_phase']=trial.read()[0]['phase']
            except Exception:report['trial_phase']='unreadable'
        credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
