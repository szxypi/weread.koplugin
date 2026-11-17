#!/usr/bin/env python3
"""Scoped empty-group trial; offline by default, with no automatic replay.

The owner may opt in to a saved-session one-shot create/delete experiment.
Private shelf data and credentials remain in memory; the permanent Keychain
journal stores only the identity needed to recognize the temporary group.
"""
import argparse
import json

from cloud_group_contract import create_request, delete_request, digest, inspect_closed
from cloud_group_journal import Journal
from cloud_group_trial import Trial
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from verify_eink_login import BASE, NativeProbe, ProbeError
from verify_native_thought_trial import other_pending
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session

FULL_SHELF = BASE + '/shelf/sync?userFlag=0&synckey=&teenmode=0&album=1'


def no_other_pending():
    return not other_pending() and not NativeThoughtTrialStore().pending() and not SelectionTrialStore().pending()


class ScopedNative(NativeProbe):
    def __init__(self, journal, grant, current, pending_check=no_other_pending, opener=None):
        super().__init__(opener);self.journal=journal;self.grant=grant;self.current=current;self.pending_check=pending_check
        self.write_attempts=0;self.dispatched=set()

    def shelf(self):
        if self.current() is not True: raise ProbeError('group_scope')
        return super().request('group_shelf', FULL_SHELF, credentials=self.grant)

    def post(self, path, body):
        if self.current() is not True or self.pending_check() is not True:
            raise ProbeError('group_scope')
        state, _token = self.journal.read()
        if not state or state['owner'] != self.grant['vid'] or state['grant_hash'] != digest(self.grant):
            raise ProbeError('group_scope')
        if path == '/shelf/archive' and state['phase'] == 'create_claimed': expected = create_request(state['name'])
        elif path == '/shelf/deleteArchive' and state['phase'] == 'delete_claimed': expected = delete_request(state['group_id'])
        else: raise ProbeError('group_scope')
        if body != expected or state['phase'] in self.dispatched or self.current() is not True:
            raise ProbeError('group_scope')
        self.dispatched.add(state['phase'])
        self.write_attempts += 1
        return super().request('group_write', BASE + path, body=body, credentials=self.grant)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--preview',action='store_true');mode.add_argument('--apply',action='store_true');mode.add_argument('--status',action='store_true');mode.add_argument('--close-unchanged',action='store_true');mode.add_argument('--inspect',action='store_true')
    args=parser.parse_args(argv)
    if args.saved_session != bool(args.preview or args.apply or args.status or args.close_unchanged or args.inspect):parser.error('saved session requires one explicit mode')
    report=dict(result='OFFLINE_ONLY',data_posts=0,authentication_posts=0,private_values_saved_to_files=False,no_automatic_replay=True)
    saved=grant=web=native=None
    try:
        if args.saved_session:
            journal=Journal()
            if args.status:
                state,_=journal.read();report.update(result='STATUS',phase=state['phase'] if state else 'absent')
            else:
                if args.apply and journal.read()[0] is not None:
                    report['phase']='scope_consumed';raise ValueError('group_scope_consumed')
                if not (args.preview or args.inspect) and not no_other_pending():raise ValueError('group_pending')
                webstore=SessionStore();saved=webstore.load();owner=saved['vid'];nativestore=NativeSessionStore();grant=nativestore.load(owner)
                web=WebFlagsProbe();web.vid=owner
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account()
                def current():
                    return webstore.load()==saved and nativestore.load(owner)==grant
                native=ScopedNative(journal,grant,current)
                def read_pair():
                    web.verify_account()
                    return dict(native=native.shelf(),web=web.request('shelf','https://weread.qq.com/web/shelf/sync'))
                trial=Trial(journal,read_pair,native.post,current)
                if args.inspect:
                    state,_token=journal.read()
                    if not state or state['phase'] not in ('create_claimed','closed_unverified') or state['owner']!=owner or state['grant_hash']!=digest(grant):
                        raise ValueError('group_scope')
                    first=trial._read(require_match=False);second=trial._read(require_match=False)
                    if first!=second:raise ValueError('group_changed')
                    left=inspect_closed(first[0],state['name'],state['native_before'])
                    right=inspect_closed(first[1],state['name'],state['web_before'])
                    report.update(result='INSPECTED',phase=state['phase'],same_owner_verified=True,
                        native_present=left['present'],web_present=right['present'],
                        native_other_state_unchanged=left['other_state_unchanged'],web_other_state_unchanged=right['other_state_unchanged'],
                        same_group_when_visible=bool(left['ident'] and left['ident']==right['ident']),
                        native_empty_books=left['empty_books'],native_album_ids_visible=left['albums_visible'],native_empty_albums=left['empty_albums'],
                        two_matching_readbacks=True)
                elif args.close_unchanged:
                    state,token=journal.read()
                    if not state or state['phase']!='create_claimed' or state['owner']!=owner or state['grant_hash']!=digest(grant):
                        raise ValueError('group_scope')
                    observations=trial.observe_stable();journal.close_unchanged(token,observations)
                    report.update(result='CLOSED_UNVERIFIED',phase='closed_unverified',same_owner_verified=True,
                                  two_matching_unchanged_readbacks=True)
                elif args.preview:
                    before=trial.preview()
                    if not before[0]['albums']['present'] or any('albumIds' not in row for row in before[0]['groups'].values()):
                        raise ValueError('group_album_visibility')
                    report.update(result='PREVIEW_VERIFIED',same_owner_verified=True,full_native_album_visibility=True)
                else:
                    report.update(trial.run(owner,digest(grant)))
                    report['native_write_attempts']=native.write_attempts
                web.verify_account()
                report['web_rotation_saved']=save_refreshed_web_session(webstore,saved,web)
    except Exception:
        report['result']='UNVERIFIED';report['reason']='group_trial_unavailable'
        if native is not None:report['native_write_attempts']=native.write_attempts
    finally:
        if native:
            report['native_stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in native.report['stages']]
        if web:web.close()
        if grant:grant.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','PREVIEW_VERIFIED','PASS','STATUS','CLOSED_UNVERIFIED','INSPECTED') else 1


if __name__=='__main__':raise SystemExit(main())
