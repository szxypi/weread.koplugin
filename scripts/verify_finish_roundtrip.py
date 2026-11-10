#!/usr/bin/env python3
"""Prototype mark-finished before any Lua write integration. Offline by default.

--saved-session is read-only. A separately approved --apply --expected-plan
may mark one unfinished shelf book finished, independently read back, restore
its original flag and independently read back. At most two data POSTs; no
renewal, replay, fallback, target switch or automatic uncertain rollback.
Raw snapshots, positions, book titles and login credentials stay in memory.

Request reference: MiuRead c1893562aa25a870b8dd076d7be062a3348f823e,
miuread/eink_client.lua, mark_book_finished (AGPL-3.0-only).
"""
import argparse
from dataclasses import dataclass
from datetime import datetime,timezone
import hashlib
import json
import re
import time
from urllib.parse import urlencode

from secure_finish_experiment import FinishExperimentStore,canonical,fingerprint
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import ShelfExperimentStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE,NativeProbe,ProbeError
from verify_eink_renewal import book_id,validate_credentials
from verify_reader_progress import project as project_position,ProgressError


class FinishError(ValueError):pass


def digest(value):return hashlib.sha256(canonical(value)).hexdigest()


def shelf_flags(value):
    if not isinstance(value,dict) or not isinstance(value.get('books'),list) or len(value['books'])>5000:
        raise FinishError('finish_shelf_invalid')
    flags={};rows={}
    for row in value['books']:
        identity=book_id(row.get('bookId')) if isinstance(row,dict) else None
        if not identity or identity in flags:raise FinishError('finish_shelf_invalid')
        flag=row.get('finishReading')
        if flag is not None and (type(flag) not in (int,bool) or flag not in (0,1)):raise FinishError('finish_shelf_invalid')
        flags[identity]=None if flag is None else bool(flag);rows[identity]=row
    return flags,rows


def point(value,identity):
    try:result=project_position(value,identity,source='native')
    except ProgressError:raise FinishError('finish_position_invalid') from None
    if not result['has_chapter_offset'] or 'chapter_uid' not in result:raise FinishError('finish_position_invalid')
    return dict(chapter_uid=str(result['chapter_uid']),chapter_idx=result['chapter_idx'],
                chapter_offset=result['chapter_offset'],percent=result['raw_percent'])


def acknowledged(value):
    if not isinstance(value,dict):return False
    if any(key in value and not (value[key] is None or type(value[key]) is int and value[key]==0)
           for key in ('errcode','errCode')):return False
    if 'succ' in value and not (value['succ'] is True or type(value['succ']) is int and value['succ']==1):return False
    if 'success' in value and value['success'] is not True:return False
    return 'succ' in value or value.get('success') is True


@dataclass(frozen=True,repr=False)
class Plan:
    bound:dict
    flags:dict
    position:dict


class FinishProbe(NativeProbe):
    def __init__(self,opener=None,sleep=time.sleep):
        super().__init__(opener);self.sleep=sleep;self.plan=None;self.dispatch=None;self.credentials_digest=None;self.original=None
        self.report.update(data_writes_attempted=0,authentication_posts_attempted=0,steps_verified=False,operations=[],write_receipts=[])

    def _current(self):
        if (not self.plan or fingerprint(self.plan.bound)!=self.original or digest(self.plan.flags)!=self.plan.bound['shelf_flags_sha256']
                or digest(self.plan.position)!=self.plan.bound['position_sha256']):raise FinishError('finish_plan_changed')

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if self.original:self._current()
        if self.credentials_digest is None or digest(credentials)!=self.credentials_digest:raise FinishError('finish_grant_changed')
        identity=self.plan.bound['book_id'] if self.plan else None
        allowed=body is None and (url==BASE+'/shelf/sync' or identity and url==BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)))
        if body is not None:allowed=self.dispatch==(stage,url,body)
        if not allowed:raise FinishError('finish_request_blocked')
        value=super().request(stage,url,body,credentials,timeout)
        if self.report['stages'][-1].get('status')!=200:raise FinishError('finish_http_unverified')
        for key in ('errcode','errCode'):
            if key in value and not (value[key] is None or type(value[key]) is int and value[key]==0):raise FinishError('finish_api_rejected')
        return value

    def prepare(self,credentials):
        if self.plan is not None or self.report['data_writes_attempted']:raise FinishError('finish_plan_consumed')
        validate_credentials(credentials);self.credentials_digest=digest(credentials)
        flags,rows=shelf_flags(self.request('finish_preview_shelf',BASE+'/shelf/sync',credentials=credentials))
        identity=next((key for key in sorted(flags) if flags[key] is False and re.fullmatch('[1-9][0-9]{0,19}',key)),None)
        if identity is None:raise FinishError('finish_target_unavailable')
        bound=dict(owner=credentials['vid'],book_id=identity,before=False,shelf_flags_sha256=digest(flags),
                   position_sha256='0'*64,grant_sha256=self.credentials_digest)
        self.plan=Plan(bound,flags,{})
        position=point(self.request('finish_preview_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials),identity)
        bound['position_sha256']=digest(position);self.plan=Plan(bound,flags,position);self.original=fingerprint(bound)
        self.report.update(shelf_books=len(flags),finished_books=sum(value is True for value in flags.values()),
                           unknown_flags=sum(value is None for value in flags.values()),before=False,desired=True,
                           position_baseline_verified=True,plan_fingerprint=fingerprint(bound))
        return self.plan,rows[identity]

    def observe(self,credentials,stage):
        identity=self.plan.bound['book_id']
        flags,_rows=shelf_flags(self.request(stage+'_shelf',BASE+'/shelf/sync',credentials=credentials))
        position=point(self.request(stage+'_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials),identity)
        return flags,position

    def _post(self,credentials,desired,ordinal):
        if self.report['data_writes_attempted']!=ordinal or ordinal not in (0,1):raise FinishError('finish_post_limit')
        body=dict(bookId=self.plan.bound['book_id'],auto=0,finishInfo=0,isCancel=0 if desired else 1,status=4)
        stage='finish_write' if desired else 'finish_restore';url=BASE+'/book/markstatus'
        self.dispatch=(stage,url,body)
        self.report['data_writes_attempted']+=1
        try:
            response=self.request(stage,url,body=body,credentials=credentials)
            # Keep only a fixed-key shape summary when an undocumented ACK
            # differs from expectations; never include response values/IDs.
            self.report['write_receipts'].append(dict(
                known_fields=[key for key in ('succ','success','errcode','errCode','status') if key in response],
                other_fields_count=len(set(response)-{'succ','success','errcode','errCode','status'})))
            return acknowledged(response)
        except (ProbeError,FinishError):return False
        finally:self.dispatch=None

    def _readback(self,credentials,expected,stage):
        for attempt in range(3):
            if attempt:self.sleep(.5*attempt)
            try:flags,position=self.observe(credentials,stage)
            except (ProbeError,FinishError):continue
            if position!=self.plan.position:raise FinishError('finish_position_changed')
            # Any unrelated flag or membership change stops the experiment.
            identity=self.plan.bound['book_id'];target=flags.get(identity)
            comparable=dict(flags);comparable[identity]=self.plan.flags[identity]
            if comparable!=self.plan.flags:raise FinishError('finish_unrelated_state_changed')
            if flags==expected:return True
            if type(target) is not bool:raise FinishError('finish_status_unknown')
        return False

    def run(self,credentials,plan,*,confirmed=False):
        if confirmed is not True or plan is not self.plan or self.report['data_writes_attempted']:
            raise FinishError('finish_confirmation_required')
        self._current()
        if digest(credentials)!=plan.bound['grant_sha256']:raise FinishError('finish_grant_changed')
        if self.observe(credentials,'finish_preflight')!=(plan.flags,plan.position):raise FinishError('finish_preflight_changed')
        desired=dict(plan.flags);desired[plan.bound['book_id']]=True
        for ordinal,(finished,expected) in enumerate(((True,desired),(False,plan.flags))):
            if ordinal and self.observe(credentials,'finish_restore_preflight')!=(desired,plan.position):
                raise FinishError('finish_preflight_changed')
            ack=self._post(credentials,finished,ordinal)
            observed=self._readback(credentials,expected,'finish_readback' if finished else 'finish_restore_readback')
            self.report['operations'].append(dict(finished=finished,acknowledgement_recognized=ack,desired_observed=observed))
            if not ack or not observed:raise FinishError('finish_write_unconfirmed')
        self.report['steps_verified']=True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--expected-plan')
    args=parser.parse_args(argv)
    if (args.apply and (not args.saved_session or not isinstance(args.expected_plan,str) or not re.fullmatch('[a-f0-9]{64}',args.expected_plan))
            or args.expected_plan and not args.apply):parser.error('--apply needs --saved-session and the exact --expected-plan')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),data_writes_attempted=0,
                authentication_posts_attempted=0,intent_state='none',roundtrip_verified=False,
                private_responses_saved=False,credentials_saved_to_files=False)
    probe=credentials=receipt=intents=None
    try:
        if args.saved_session:
            owner=SessionStore().load()['vid'];credentials=NativeSessionStore().load(owner)
            intents=FinishExperimentStore();pending=intents.pending();other_pending=ShelfExperimentStore().pending()
            report.update(pending_intent_present=pending,pending_membership_experiment=other_pending)
            if pending:report['intent_state']='pending'
            if args.apply and (pending or other_pending):raise FinishError('finish_experiment_unconfirmed')
            probe=FinishProbe();plan,_row=probe.prepare(credentials)
            report.update(same_owner_verified=True,planned_post_limit=2)
            if args.apply:
                if fingerprint(plan.bound)!=args.expected_plan:raise FinishError('finish_plan_changed')
                report['intent_state']='unknown';receipt=intents.begin(plan.bound);report['intent_state']='pending'
                probe.run(credentials,plan,confirmed=True)
                if probe.observe(credentials,'finish_independent_final')!=(plan.flags,plan.position):raise FinishError('finish_final_changed')
                if not probe.report['steps_verified'] or probe.report['data_writes_attempted']!=2:raise FinishError('finish_write_unconfirmed')
                intents.finish(receipt,restored_verified=True);receipt=None;report['intent_state']='cleared'
                report.update(result='OWNER_FINISH_ROUNDTRIP_VERIFIED',roundtrip_verified=True,independent_flags_and_position_restored=True)
            else:
                if probe.observe(credentials,'finish_preview_independent')!=(plan.flags,plan.position):raise FinishError('finish_preflight_changed')
                report.update(result='OWNER_FINISH_PREVIEW_VERIFIED',independent_flags_and_position_unchanged=True)
    except KeyboardInterrupt:report.update(result='UNVERIFIED',reason='finish_interrupted')
    except Exception as exc:
        report.update(result='UNVERIFIED',reason='finish_verification_failed')
        known={'finish_experiment_unconfirmed','finish_plan_changed','finish_preflight_changed','finish_final_changed',
               'finish_position_invalid','finish_position_changed','finish_unrelated_state_changed','finish_write_unconfirmed',
               'finish_target_unavailable','finish_intent_readback_failed','finish_intent_cleanup_unverified'}
        if str(exc) in known:report['detail']=str(exc)
    finally:
        if probe:
            report.update({k:v for k,v in probe.report.items() if k not in ('stages','checked_at')})
            report['stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in probe.report['stages']]
        if receipt is not None and probe and probe.report['data_writes_attempted']==0:
            try:intents.finish(receipt,not_dispatched=True);report['intent_state']='cleared'
            except Exception:report['intent_state']='pending'
        if credentials:credentials.clear()
        if probe:probe.plan=probe.dispatch=probe.credentials_digest=probe.original=None
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','OWNER_FINISH_PREVIEW_VERIFIED','OWNER_FINISH_ROUNDTRIP_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
