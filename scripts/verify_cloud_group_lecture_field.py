#!/usr/bin/env python3
"""One-shot empty-group trial for the E-Ink lectureBookIds request shape.

The old trials and their uncertain outcomes stay untouched. An independent
Keychain journal and dispatch claims prohibit replay, even across processes.
No credentials, group names, or shelf contents are printed or saved to files.
"""
import argparse
from contextlib import nullcontext
import json
from pathlib import Path
import resource
import tempfile

from cloud_group_binding import Binding as OldBinding
from cloud_group_contract import canonical, delete_request, digest, temporary_name
from cloud_group_fixture import Journal as UploadJournal, binding
from cloud_group_fixture_cleanup import Intent as CleanupIntent, project_after, verified_for
from cloud_group_journal import Journal
from cloud_group_nonempty_binding import Binding as GroupBinding
from cloud_group_nonempty_inspect import _same_scope
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_trial import Trial
from cloud_group_journal import Journal as OldJournal
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_format_trial import TargetReceipt
from verify_cloud_group_trial import FULL_SHELF, no_other_pending
from verify_eink_login import BASE, NativeProbe
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session

SERVICE = 'org.codex.weread.goal-cloud-group-lecture-v1'
CLAIMS = SERVICE + '-dispatch'


def create_request(name):
    if not temporary_name(name): raise ValueError('lecture_group/name')
    return dict(bookIds=[], lectureBookIds=[], archiveId=0, name=name)


def make_journal():
    path=Path(tempfile.gettempdir())/('codex-lecture-group-'+ACCOUNT+'.lock')
    return Journal(backend=MacKeychain(service=SERVICE,account=ACCOUNT),lock=lambda:project_lock(path))


def make_binding():
    path=Path(tempfile.gettempdir())/('codex-lecture-group-binding-'+ACCOUNT+'.lock')
    return OldBinding(backend=MacKeychain(service=SERVICE+'-read-binding',account=ACCOUNT),lock=lambda:project_lock(path))


class DispatchClaims:
    def __init__(self, backend=None, lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=CLAIMS,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-lecture-group-dispatch-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def claim(self,journal,grant,phase):
        if phase not in ('create_claimed','delete_claimed'):raise ValueError('lecture_group/phase')
        with self.lock():
            state,token=journal.read()
            if (not state or not isinstance(token,bytes) or state['phase']!=phase
                    or state['owner']!=grant['vid'] or state['grant_hash']!=digest(grant)):
                raise ValueError('lecture_group/stale')
            raw=self.backend.load()
            if raw is None:
                value=dict(schema=1,owner=digest(grant['vid']),claims={})
            else:
                try:
                    if not isinstance(raw,bytes) or not 0<len(raw)<=4096:raise ValueError()
                    value=json.loads(raw)
                    if (not isinstance(value,dict) or set(value)!={'schema','owner','claims'}
                            or type(value['schema']) is not int or value['schema']!=1
                            or value['owner']!=digest(grant['vid']) or not isinstance(value['claims'],dict)
                            or any(k not in ('create_claimed','delete_claimed') or not isinstance(v,str)
                                   or len(v)!=64 or any(c not in '0123456789abcdef' for c in v)
                                   for k,v in value['claims'].items())):raise ValueError()
                except (ValueError,TypeError,UnicodeError):raise ValueError('lecture_group/claims') from None
            claims=value['claims']
            if phase in claims or (phase=='delete_claimed' and 'create_claimed' not in claims):
                raise ValueError('lecture_group/claimed')
            claims[phase]=digest(token.decode('utf-8'))
            new=canonical(value);self.backend.save(new)
            if self.backend.load()!=new or journal.read()!=(state,token):raise ValueError('lecture_group/stale')
            return state


class ScopedNative(NativeProbe):
    def __init__(self,journal,claims,grant,current,opener=None):
        super().__init__(opener);self.journal=journal;self.claims=claims;self.grant=grant;self.current=current
        self.posts=0

    def shelf(self):
        if self.current() is not True:raise ValueError('lecture_group/stale')
        return super().request('shelf',FULL_SHELF,credentials=self.grant)

    def post(self,path,body):
        if self.current() is not True or no_other_pending() is not True:raise ValueError('lecture_group/stale')
        state,_=self.journal.read()
        if not state:raise ValueError('lecture_group/stale')
        if path=='/shelf/archive' and state['phase']=='create_claimed':expected=create_request(state['name'])
        elif path=='/shelf/deleteArchive' and state['phase']=='delete_claimed':expected=delete_request(state['group_id'])
        else:raise ValueError('lecture_group/phase')
        if body!=expected or self.current() is not True:raise ValueError('lecture_group/scope')
        claimed=self.claims.claim(self.journal,self.grant,state['phase'])
        if claimed!=state or self.current() is not True:raise ValueError('lecture_group/stale')
        self.posts+=1
        return super().request('group_write',BASE+path,body=body,credentials=self.grant)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--preview',action='store_true');modes.add_argument('--apply',action='store_true')
    modes.add_argument('--inspect',action='store_true');modes.add_argument('--status',action='store_true')
    modes.add_argument('--close-unchanged',action='store_true');modes.add_argument('--bind-inspection',action='store_true')
    args=parser.parse_args(argv)
    if args.saved_session!=bool(args.preview or args.apply or args.inspect or args.status or args.close_unchanged or args.bind_inspection):parser.error('saved session requires one mode')
    report=dict(result='OFFLINE_ONLY',group_posts=0,authentication_posts=0,no_replay=True)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=web=native=None
    try:
        journal=make_journal()
        if args.status:
            state,_=journal.read();report.update(result='STATUS',phase=state['phase'] if state else 'absent')
        elif args.saved_session:
            sessions=SessionStore();saved=sessions.load();owner=saved['vid'];native_store=NativeSessionStore();grant=native_store.load(owner)
            old,groups,uploads=OldJournal(),GroupJournal(),UploadJournal()
            receipt=TargetReceipt('epub',scope='group-fixture');cleanup=CleanupIntent()
            prior,prior_token=old.read();group,group_token=groups.read();upload,upload_token=binding(uploads,receipt.backend)
            cleanup_state,cleanup_token=cleanup.read()
            if (not prior or prior['phase']!='closed_unverified' or prior['owner']!=owner
                    or prior['grant_hash']!=digest(grant) and not OldBinding().matches(prior,prior_token,grant)
                    or not group or group['phase']!='create_claimed' or group['dispatched'] is not True
                    or not _same_scope(group,group_token,grant,GroupBinding())
                    or group['target']!=upload['target'] or group['upload_attempt']!=upload['attempt']
                    or group['upload_plan_hash']!=hash_value(upload['plan'])
                    or not verified_for(cleanup,group,upload,owner) or no_other_pending() is not True):
                raise ValueError('lecture_group/history')
            names=(prior['name'],group['name']);target=upload['target']
            def current():
                return (sessions.load()==saved and native_store.load(owner)==grant and old.read()==(prior,prior_token)
                        and groups.read()==(group,group_token) and binding(uploads,receipt.backend)==(upload,upload_token)
                        and cleanup.read()==(cleanup_state,cleanup_token) and no_other_pending() is True)
            web=WebFlagsProbe();web.vid=owner
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();native=ScopedNative(journal,DispatchClaims(),grant,current)
            def read_pair():
                web.verify_account()
                raw=dict(native=native.shelf(),web=web.request('shelf','https://weread.qq.com/web/shelf/sync'))
                project_after(raw,target,names)
                return raw
            trial=Trial(journal,read_pair,native.post,current,request_builder=create_request)
            if args.preview:
                if journal.read()[0] is not None:raise ValueError('lecture_group/consumed')
                before=trial.preview()
                if not before[0]['albums']['present'] or any('albumIds' not in g for g in before[0]['groups'].values()):
                    raise ValueError('lecture_group/albums')
                report.update(result='PREVIEW_VERIFIED',old_trials_absent=True,fixture_removed=True)
            elif args.inspect:
                state,token=journal.read()
                if (not state or state['owner']!=owner or state['phase'] not in ('create_claimed','closed_unverified')
                        or state['grant_hash']!=digest(grant) and not make_binding().matches(state,token,grant)):
                    raise ValueError('lecture_group/scope')
                first=trial._read();second=trial._read()
                if first!=second or journal.read()!=(state,token):raise ValueError('lecture_group/changed')
                report.update(result='INSPECTED',phase=state['phase'],native_present=any(g['name']==state['name'] for g in first[0]['groups'].values()),
                              web_present=any(g['name']==state['name'] for g in first[1]['groups'].values()),
                              native_baseline_unchanged=digest(first[0])==state['native_before'],
                              web_baseline_unchanged=digest(first[1])==state['web_before'])
            elif args.close_unchanged:
                state,token=journal.read()
                if not state or state['owner']!=owner or state['grant_hash']!=digest(grant):raise ValueError('lecture_group/scope')
                journal.close_unchanged(token,trial.observe_stable())
                report.update(result='CLOSED_UNVERIFIED',phase='closed_unverified')
            elif args.bind_inspection:
                state,token=journal.read();make_binding().bind(state,token,grant)
                report.update(result='INSPECTION_BOUND',phase=state['phase'])
            else:
                report.update(trial.run(owner,digest(grant)))
            web.verify_account();report['web_rotation_saved']=save_refreshed_web_session(sessions,saved,web)
    except Exception:
        report.update(result='UNVERIFIED',reason='lecture_group_unavailable')
    finally:
        if native is not None:report['group_posts']=native.posts
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','STATUS','PREVIEW_VERIFIED','PASS','INSPECTED','CLOSED_UNVERIFIED','INSPECTION_BOUND') else 1


if __name__=='__main__':raise SystemExit(main())
