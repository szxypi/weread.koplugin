#!/usr/bin/env python3
"""Read a pending finish experiment; restoring needs a new specific approval.

Default offline. --saved-session reads only. --restore-once --expected-intent
is one separately approved restoration attempt of that exact pending record.
No finish toggle, automatic retry, login renewal or unrelated write is allowed.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import re
import time
from urllib.parse import urlencode

from secure_finish_experiment import FinishExperimentStore,Receipt
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE,NativeProbe,ProbeError
from verify_finish_roundtrip import FinishError,acknowledged,digest,point,shelf_flags


def observation(flags,position,bound):
    identity=bound['book_id'];present=identity in flags;normalized=dict(flags)
    if present:normalized[identity]=bound['before']
    return dict(target_present=present,observed_finished=flags.get(identity),
                original_flags_restored=present and digest(flags)==bound['shelf_flags_sha256'],
                unrelated_flags_and_members_unchanged=present and digest(normalized)==bound['shelf_flags_sha256'],
                position_unchanged=digest(position)==bound['position_sha256'])


def receipt_shape(value,identity):
    fields={'succ','success','errcode','errCode','status','bookId','book_id','finishReading','finished',
            'isCancel','finishInfo','finishedDate','finishedBookIndex','readingBookIndex'}
    status=value.get('status')
    return dict(known_fields=sorted(set(value)&fields),other_fields_count=len(set(value)-fields),
                status_enum=str(status) if type(status) is int and 0<=status<=15 else 'other',
                returned_book_id='bookId' in value or 'book_id' in value,
                returned_book_id_matches=str(value.get('bookId',value.get('book_id')))==identity)


class ResolveProbe(NativeProbe):
    def __init__(self,credentials,bound,opener=None,sleep=time.sleep):
        super().__init__(opener);self.bound=bound;self.grant_digest=digest(credentials);self.sleep=sleep
        self.lease=None;self.report.update(data_writes_attempted=0,authentication_posts_attempted=0,acknowledgement_recognized=False)

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if credentials['vid']!=self.bound['owner'] or digest(credentials)!=self.grant_digest:raise FinishError('finish_grant_changed')
        allowed=body is None and url in (BASE+'/shelf/sync',BASE+'/book/getProgress?'+urlencode(dict(bookId=self.bound['book_id'])))
        if body is not None:
            expected=dict(bookId=self.bound['book_id'],auto=0,finishInfo=0,isCancel=1,status=4)
            allowed=(stage=='finish_restore_once' and url==BASE+'/book/markstatus' and body==expected
                     and all(type(body[key]) is type(item) for key,item in expected.items())
                     and self.report['data_writes_attempted']==0 and self.lease is not None and self.lease())
            if allowed:self.report['data_writes_attempted']=1
        if not allowed:raise FinishError('finish_request_blocked')
        value=super().request(stage,url,body,credentials,timeout)
        if self.report['stages'][-1].get('status')!=200:raise FinishError('finish_http_unverified')
        if any(key in value and not (value[key] is None or type(value[key]) is int and value[key]==0)
               for key in ('errcode','errCode')):raise FinishError('finish_api_rejected')
        if 'succ' in value and not (value['succ'] is True or type(value['succ']) is int and value['succ']==1):raise FinishError('finish_api_rejected')
        if 'success' in value and value['success'] is not True:raise FinishError('finish_api_rejected')
        return value

    def inspect(self,credentials,stage):
        flags,_rows=shelf_flags(self.request(stage+'_shelf',BASE+'/shelf/sync',credentials=credentials))
        position=point(self.request(stage+'_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=self.bound['book_id'])),credentials=credentials),self.bound['book_id'])
        return observation(flags,position,self.bound)

    def restore(self,credentials,store,receipt):
        before=self.inspect(credentials,'finish_restore_preflight')
        if not before['unrelated_flags_and_members_unchanged'] or not before['position_unchanged']:raise FinishError('finish_preflight_changed')
        if before['original_flags_restored']:return receipt,before
        if before['observed_finished'] is not True:raise FinishError('finish_status_unknown')
        latest=store.begin_restore(receipt);self.lease=lambda:store.owns(latest)
        body=dict(bookId=self.bound['book_id'],auto=0,finishInfo=0,isCancel=1,status=4)
        try:
            value=self.request('finish_restore_once',BASE+'/book/markstatus',body,credentials)
            self.report['acknowledgement_recognized']=acknowledged(value)
            self.report['receipt_shape']=receipt_shape(value,self.bound['book_id'])
        except (ProbeError,FinishError):pass
        for attempt in range(3):
            if attempt:self.sleep(.5*attempt)
            try:current=self.inspect(credentials,'finish_restore_readback')
            except (ProbeError,FinishError):continue
            if not current['unrelated_flags_and_members_unchanged'] or not current['position_unchanged']:raise FinishError('finish_final_changed')
            if current['original_flags_restored']:
                final=self.inspect(credentials,'finish_restore_independent_final')
                if not final['original_flags_restored'] or not final['position_unchanged']:raise FinishError('finish_final_changed')
                return latest,final
        raise FinishError('finish_restore_unconfirmed')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--restore-once',action='store_true');parser.add_argument('--expected-intent')
    args=parser.parse_args(argv)
    if (args.restore_once and (not args.saved_session or not isinstance(args.expected_intent,str) or not re.fullmatch('[a-f0-9]{64}',args.expected_intent))
            or args.expected_intent and not args.restore_once):parser.error('restoration needs saved-session and exact expected-intent')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),data_writes_attempted=0,
                authentication_posts_attempted=0,intent_state='none',private_responses_saved=False)
    credentials=probe=None
    try:
        if args.saved_session:
            store=FinishExperimentStore();value,raw=store._load()
            if value is None:raise FinishError('finish_no_pending')
            report.update(intent_state='pending',pending_intent_fingerprint=hashlib.sha256(raw).hexdigest(),
                          restore_attempt_already_pending='restore' in value)
            owner=SessionStore().load()['vid'];assert owner==value['plan']['owner']
            credentials=NativeSessionStore().load(owner);probe=ResolveProbe(credentials,value['plan'])
            receipt=Receipt(raw)
            if args.restore_once:
                if hashlib.sha256(raw).hexdigest()!=args.expected_intent:raise FinishError('finish_intent_replaced')
                receipt,current=probe.restore(credentials,store,receipt)
                store.finish(receipt,restored_verified=True);report['intent_state']='cleared'
                report['result']='COMPLETION_FLAG_RESTORED_BY_INDEPENDENT_READ'
            else:
                current=probe.inspect(credentials,'finish_pending_check');report['result']='PENDING_COMPLETION_STATE_READ'
            report.update(current)
    except KeyboardInterrupt:report.update(result='UNVERIFIED',reason='finish_resolution_interrupted')
    except Exception:report.update(result='UNVERIFIED',reason='finish_resolution_unverified')
    finally:
        if probe:
            report.update({k:v for k,v in probe.report.items() if k not in ('checked_at','stages')})
            report['stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in probe.report['stages']]
        if credentials:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','PENDING_COMPLETION_STATE_READ','COMPLETION_FLAG_RESTORED_BY_INDEPENDENT_READ') else 1


if __name__=='__main__':raise SystemExit(main())
