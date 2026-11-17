#!/usr/bin/env python3
"""Isolated nonempty group trial; offline by default, no automatic replay."""
import argparse
import json
import os
from pathlib import Path
import resource

from cloud_group_binding import Binding
from cloud_group_nonempty_binding import Binding as NonemptyBinding
from cloud_group_fixture import Journal as UploadJournal, binding
from cloud_group_journal import Journal as OldJournal
from cloud_group_nonempty_inspect import inspect, inspect_original
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_nonempty_transport import ScopedNative
from cloud_group_nonempty_workflow import execute
from cloud_group_old_guard import Guard
from cloud_group_upload_transport import GuardedUploadProbe
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from synthetic_format_trial import TargetReceipt
from verify_cloud_group_trial import no_other_pending
from verify_shelf_flags import WebFlagsProbe
from verify_synthetic_epub_upload import read_source
from verify_translation_preflight import save_refreshed_web_session

MARKER=Path(__file__).resolve().parents[2]/'.validation'/'cloud-group-nonempty-once-v1.json'


def reserve_once(path=MARKER):
    """A second permanent guard, acquired before any fixture upload."""
    flags=os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0)
    fd=os.open(path,flags,0o600)
    try:
        os.write(fd,b'{"scope":"cloud-group-nonempty-v1","claimed":true}\n');os.fsync(fd)
    finally:os.close(fd)
    directory=os.open(path.parent,os.O_RDONLY)
    try:os.fsync(directory)
    finally:os.close(directory)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--preview',action='store_true');modes.add_argument('--apply',action='store_true')
    modes.add_argument('--status',action='store_true');modes.add_argument('--inspect',action='store_true')
    modes.add_argument('--bind-inspection',action='store_true')
    args=parser.parse_args(argv)
    if args.saved_session != bool(args.preview or args.apply or args.status or args.inspect or args.bind_inspection):
        parser.error('saved session requires one explicit mode')
    report=dict(result='OFFLINE_ONLY',data_posts=0,authentication_posts=0,no_automatic_replay=True)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=web=native=probe=None
    try:
        if args.saved_session:
            uploads=UploadJournal();groups=GroupJournal();receipt=TargetReceipt('epub',scope='group-fixture')
            if args.status:
                u,_=uploads.read();g,_=groups.read()
                report.update(result='STATUS',fixture_phase=u['phase'] if u else 'absent',
                              group_phase=g['phase'] if g else 'absent',target_receipt_present=receipt.backend.load() is not None,
                              one_shot_claimed=MARKER.exists())
            else:
                store=SessionStore();saved=store.load();owner=saved['vid'];nativestore=NativeSessionStore();grant=nativestore.load(owner)
                web=WebFlagsProbe();web.vid=owner
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account()
                def current():return store.load()==saved and nativestore.load(owner)==grant
                def read_pair():
                    web.verify_account()
                    return dict(native=native.shelf(),web=web.request('shelf','https://weread.qq.com/web/shelf/sync'))
                old=OldJournal();guard=Guard(old,Binding(),grant,current,read_pair)
                native=ScopedNative(groups,lambda:binding(uploads,receipt.backend),grant,current,no_other_pending,
                                    lambda:bool(guard.check(False)))
                if args.bind_inspection:
                    state,token=groups.read();NonemptyBinding().bind(state,token,grant)
                    report.update(result='INSPECTION_BOUND',phase=state['phase'])
                elif args.inspect:
                    readonly=NonemptyBinding()
                    report.update(inspect(groups,lambda:binding(uploads,receipt.backend),grant,current,read_pair,readonly))
                    report.update(inspect_original(old,groups,lambda:binding(uploads,receipt.backend),grant,current,read_pair,guard.check,readonly))
                else:
                    if (uploads.read()[0] is not None or groups.read()[0] is not None or receipt.backend.load() is not None
                            or MARKER.exists() or no_other_pending() is not True):raise ValueError('group_scope')
                    guard.check(True)
                    if args.apply:reserve_once()
                    probe=GuardedUploadProbe(uploads,lambda value:current() and value==grant,groups,receipt,guard.check,no_other_pending)
                    report.update(execute(upload_probe=probe,upload_journal=uploads,group_journal=groups,target_receipt=receipt,
                        grant=grant,current=current,old_guard=guard.check,read_pair=read_pair,post=native.post,
                        pending=no_other_pending,read_content=lambda target:read_source(saved,target),apply=args.apply))
                    report['data_posts']=native.write_attempts+probe.attempts['notify']+probe.attempts['cleanup']
                    report['fixture_credential_requests']=probe.attempts['credential'];report['fixture_put_attempts']=probe.attempts['put']
                web.verify_account();report['web_rotation_saved']=save_refreshed_web_session(store,saved,web)
    except Exception:
        report['result']='UNVERIFIED';report['reason']='group_workflow_unavailable'
    finally:
        if native is not None:report['group_posts']=native.write_attempts
        if probe is not None:
            report['fixture_cleanup_posts']=probe.attempts['cleanup']
            report['fixture_notify_posts']=probe.attempts['notify']
            report['fixture_credential_requests']=probe.attempts['credential']
            report['fixture_put_attempts']=probe.attempts['put']
            report['data_posts']=(native.write_attempts if native else 0)+probe.attempts['notify']+probe.attempts['cleanup']
        if web:web.close()
        if grant:grant.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','STATUS','READ_ONLY_PREVIEW','PASS','INSPECTED','INSPECTION_BOUND') else 1


if __name__=='__main__':raise SystemExit(main())
