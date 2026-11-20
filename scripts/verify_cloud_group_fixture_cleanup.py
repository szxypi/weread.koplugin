#!/usr/bin/env python3
"""Remove only the bound, untouched synthetic fixture of a prior group trial.

Offline by default. An independent permanent intent permits at most one shelf
removal; an unknown result is never resent. The unresolved group request and
its original records are not changed. Credentials and shelf data stay private.
"""
import argparse
import json
import resource

from cloud_group_binding import Binding as OldBinding
from cloud_group_contract import digest
from cloud_group_fixture import Journal as UploadJournal, binding
from cloud_group_journal import Journal as OldJournal
from cloud_group_nonempty_binding import Binding as GroupBinding
from cloud_group_nonempty_inspect import _same_scope
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_fixture_cleanup import Intent, execute
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from synthetic_format_trial import TargetReceipt
from verify_cb_fixture_highlight_trial import ScopedNative as NotesProbe
from verify_cb_reading import CbReadingProbe, baseline_position
from verify_cloud_group_trial import FULL_SHELF, no_other_pending
from verify_eink_login import BASE, NativeProbe
from verify_personal_upload_trial import acknowledged
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session


class ScopedNative(NativeProbe):
    def __init__(self,grant,current,intent,group,upload,target,opener=None):
        super().__init__(opener);self.grant=grant;self.current=current;self.intent=intent
        self.group=group;self.upload=upload;self.target=target;self.posts=0
    def shelf(self):
        if not self.current():raise ValueError('group_fixture_cleanup/stale')
        return super().request('shelf',FULL_SHELF,credentials=self.grant)
    def delete(self,target,receipt,plan):
        state,stored=self.intent.read()
        if (self.posts or not self.current() or no_other_pending() is not True or not state or stored!=receipt
                or state['phase']!='claimed' or state['plan']!=plan or target!=self.target
                or plan['target']!=digest(target) or plan['owner']!=digest(self.grant['vid'])
                or plan['grant']!=digest(self.grant) or plan['group']!=digest(self.group)
                or plan['upload']!=digest(self.upload)):
            raise ValueError('group_fixture_cleanup/dispatch')
        self.posts+=1
        body=dict(bookIds=[target],albumIds=[],archiveIds=[])
        return acknowledged(super().request('cleanup',BASE+'/shelf/delete',body=body,credentials=self.grant))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    modes=parser.add_mutually_exclusive_group();modes.add_argument('--preview',action='store_true');modes.add_argument('--apply',action='store_true');modes.add_argument('--status',action='store_true')
    args=parser.parse_args(argv)
    if args.saved_session != bool(args.preview or args.apply or args.status):parser.error('saved session requires one explicit mode')
    report=dict(result='OFFLINE_ONLY',cleanup_posts=0,group_posts=0,authentication_posts=0,no_replay=True)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=web=native=None
    try:
        if args.saved_session:
            intent=Intent()
            if args.status:
                state,_=intent.read();report.update(result='STATUS',phase=state['phase'] if state else 'absent')
            else:
                session=SessionStore();saved=session.load();native_store=NativeSessionStore();grant=native_store.load(saved['vid'])
                uploads=UploadJournal();groups=GroupJournal();old=OldJournal();target_receipt=TargetReceipt('epub',scope='group-fixture')
                upload,upload_token=binding(uploads,target_receipt.backend);group,group_token=groups.read();previous,previous_token=old.read()
                if (not group or group['phase']!='create_claimed' or group['dispatched'] is not True
                        or not previous or previous['phase']!='closed_unverified' or previous['owner']!=grant['vid']
                        or previous['grant_hash']!=digest(grant) and not OldBinding().matches(previous,previous_token,grant)
                        or not _same_scope(group,group_token,grant,GroupBinding())
                        or group['target']!=upload['target'] or group['upload_attempt']!=upload['attempt']
                        or group['upload_plan_hash']!=hash_value(upload['plan']) or no_other_pending() is not True):
                    raise ValueError('group_fixture_cleanup/binding')
                target=upload['target'];names=(previous['name'],group['name'])
                def current():
                    return (session.load()==saved and native_store.load(saved['vid'])==grant
                            and binding(uploads,target_receipt.backend)==(upload,upload_token)
                            and groups.read()==(group,group_token) and old.read()==(previous,previous_token)
                            and no_other_pending() is True)
                web=WebFlagsProbe();web.vid=saved['vid']
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                web.verify_account();native=ScopedNative(grant,current,intent,group,upload,target)
                def read_pair():
                    web.verify_account()
                    return dict(native=native.shelf(),web=web.request('shelf','https://weread.qq.com/web/shelf/sync'))
                def read_notes():
                    if not current():raise ValueError('group_fixture_cleanup/stale')
                    native_notes=NotesProbe(target,grant,current,None).observe(grant)
                    position=native_notes['position']
                    native_unstarted=(position['chapter_uid']==0 and position['chapter_idx']==0
                                      and position['chapter_offset']==0 and position['raw_percent']==0 and position['summary']=='')
                    empty=native_notes['marks']['updated']=={} and native_notes['marks']['chapters']=={} and native_notes['thoughts']=={}
                    probe=CbReadingProbe();probe.vid=saved['vid'];probe.allowed={target};probe.book_id=target
                    try:
                        for key,value in saved['cookies'].items():probe.set_cookie(key,value)
                        probe.verify_account()
                        a=baseline_position(probe.request('progress_before','https://weread.qq.com/web/book/getProgress?bookId='+target),target)
                        b=baseline_position(probe.request('progress_after','https://weread.qq.com/web/book/getProgress?bookId='+target),target)
                        probe.verify_account()
                        return dict(empty=empty,unstarted=native_unstarted and a==b==dict(chapter='0',offset=0,percent=0),
                                    native_state=digest(native_notes),web_state=digest(a))
                    finally:probe.samples.clear();probe.close()
                report.update(execute(saved['vid'],grant,target,group,upload,names,intent,current,read_pair,read_notes,native.delete,apply=args.apply))
                web.verify_account();report['web_rotation_saved']=save_refreshed_web_session(session,saved,web)
    except Exception as error:
        allowed={'group_fixture_cleanup/binding','group_fixture_cleanup/preflight','group_fixture_cleanup/scope',
                 'group_fixture_cleanup/shelf','group_fixture_cleanup/channels','group_fixture_cleanup/occupied',
                 'group_fixture_cleanup/changed','group_fixture_cleanup/notes','group_fixture_cleanup/stale',
                 'group_fixture_cleanup/dispatch','group_fixture_cleanup/not_removed','group_fixture_cleanup/unconfirmed',
                 'group_fixture_cleanup/consumed'}
        report.update(result='UNVERIFIED',reason=str(error) if str(error) in allowed else 'unavailable')
        if args.saved_session:
            try:
                state,_=Intent().read();report['intent_phase']=state['phase'] if state else 'absent'
            except Exception:report['intent_phase']='unverified'
    finally:
        if native is not None:report['cleanup_posts']=native.posts
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','STATUS','READ_ONLY_PREVIEW','FIXTURE_CLEANED') else 1


if __name__=='__main__':raise SystemExit(main())
