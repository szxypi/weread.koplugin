#!/usr/bin/env python3
"""One new private thought experiment, offline by default.

--saved-session is GET only. --prepare stores a bounded local intent. A
separately authorized --apply --expected-intent dispatches at most three POSTs:
create one private test, edit only that new record, delete only that new record.
Independent full reads decide the outcome; neither lost ACKs nor stored pending
phases permit replay. No existing thought is a write target.
Private responses, identifiers, source text and login credentials are never
printed or written to files. Saved development logins stay in Keychain.
"""
import argparse
from dataclasses import dataclass
from datetime import datetime,timezone
import json
import secrets
import re
import time
from urllib.parse import urlencode

from annotation_experiment_model import bind,context,digest,fingerprint,shelf_state,thoughts_state,marks_state,point,identifier,integer,note_text,expected_new,validate_plan,validate_context
from secure_native_session import NativeSessionStore
from secure_annotation_experiment import AnnotationExperimentStore
from secure_finish_experiment import FinishExperimentStore
from secure_shelf_experiment import ShelfExperimentStore
from secure_position_experiment import ExperimentStore as PositionExperimentStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE,NativeProbe,ProbeError
from verify_eink_renewal import validate_credentials


def query(identity):return BASE+'/review/list?'+urlencode(dict(bookId=identity,listType=11,listMode=0,mine=1,synckey=0,count=20))


@dataclass(frozen=True,repr=False)
class Plan:
    bound:dict
    context:dict
    baseline:dict


class AnnotationProbe(NativeProbe):
    def __init__(self,opener=None,sleep=time.sleep):
        super().__init__(opener);self.identity=None;self.grant=None;self.plan=None;self.original=None;self.gets=0;self.sleep=sleep;self.dispatch=None;self.store=None;self.receipt=None;self.created_id=None;self.confirmed=False;self.last_request=0
        self.report.update(data_writes_attempted=0,authentication_posts_attempted=0,steps_verified=[],receipt_shapes=[])

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if self.plan is not None:self.current()
        if self.grant is None or digest(credentials)!=self.grant:raise ValueError('annotation_experiment_grant')
        allowed={BASE+'/shelf/sync',BASE+'/user/notebooks?count=100'}
        if self.identity:
            allowed.update({query(self.identity),BASE+'/book/bookmarklist?'+urlencode(dict(bookId=self.identity,synckey=0)),
                            BASE+'/book/info?'+urlencode(dict(bookId=self.identity)),BASE+'/book/getProgress?'+urlencode(dict(bookId=self.identity))})
        if body is None:
            if url not in allowed or self.gets>=80:raise ValueError('annotation_experiment_request')
            self.gets+=1
        else:
            if (not self.confirmed or self.dispatch is None or (stage,url,digest(body))!=self.dispatch[:3]
                    or self.store is None or not self.store.owns(self.receipt,self.dispatch[3])):raise ValueError('annotation_experiment_request')
            if (stage,url,digest(body))!=self.specification(self.dispatch[3])[:3]:raise ValueError('annotation_experiment_request')
            expected={'create_pending':0,'edit_pending':1,'delete_pending':2}[self.dispatch[3]]
            if self.report['data_writes_attempted']!=expected:raise ValueError('annotation_experiment_post_limit')
            self.report['data_writes_attempted']+=1
        delay=.35-(time.monotonic()-self.last_request)
        if delay>0:self.sleep(delay)
        self.last_request=time.monotonic()
        value=super().request(stage,url,body,credentials,timeout)
        if body is None and self.report['stages'][-1].get('status')!=200:raise ValueError('annotation_experiment_http')
        if self.plan is not None:self.current()
        return value

    def current(self):
        plan=self.plan
        if (plan is None or fingerprint(plan.bound)!=self.original or digest(plan.context)!=plan.bound['context_sha256']
                or any(digest(plan.baseline[key])!=plan.bound[key+'_sha256'] for key in ('thoughts','marks','position','shelf'))):raise ValueError('annotation_experiment_plan_changed')

    def observe(self,credentials,stage):
        identity=self.identity
        return dict(shelf=shelf_state(self.request(stage+'_shelf',BASE+'/shelf/sync',credentials=credentials)),
                    thoughts=thoughts_state(self.request(stage+'_thoughts',query(identity),credentials=credentials),identity,credentials['vid']),
                    marks=marks_state(self.request(stage+'_marks',BASE+'/book/bookmarklist?'+urlencode(dict(bookId=identity,synckey=0)),credentials=credentials),identity,credentials['vid']),
                    position=point(self.request(stage+'_position',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials),identity))

    def prepare(self,credentials,existing=None):
        if self.plan is not None:raise ValueError('annotation_experiment_consumed')
        validate_credentials(credentials)
        if existing is not None:
            validate_plan(existing)
            if existing['owner']!=credentials['vid']:raise ValueError('annotation_experiment_owner')
        self.grant=digest(credentials)
        shelf=self.request('preview_shelf',BASE+'/shelf/sync',credentials=credentials);flags=shelf_state(shelf)
        if existing:
            self.identity=existing['book_id']
            if existing['owner']!=credentials['vid'] or self.identity not in flags:raise ValueError('annotation_experiment_owner')
        else:
            notebooks=self.request('preview_notebooks',BASE+'/user/notebooks?count=100',credentials=credentials)
            rows=notebooks.get('books')
            if not isinstance(rows,list) or len(rows)>5000:raise ValueError('annotation_experiment_notebooks')
            choices=[]
            for row in rows:
                book=row.get('book',row) if isinstance(row,dict) else None
                identity=str(book.get('bookId')) if isinstance(book,dict) else None
                count=row.get('reviewCount') if isinstance(row,dict) else None
                if identity in flags and identifier(identity) and integer(count,18):
                    if row.get('bookId') is not None and str(row['bookId'])!=identity:raise ValueError('annotation_experiment_notebooks')
                    choices.append((count,identity))
            if not choices:raise ValueError('annotation_experiment_selection')
            self.identity=sorted(choices,key=lambda row:(-row[0],row[1]))[0][1]
        observed=self.observe(credentials,'preview_baseline')
        rawmarks=self.request('preview_context_marks',BASE+'/book/bookmarklist?'+urlencode(dict(bookId=self.identity,synckey=0)),credentials=credentials)
        info=self.request('preview_metadata',BASE+'/book/info?'+urlencode(dict(bookId=self.identity)),credentials=credentials)
        self.report['version_fields']={key:integer(info.get(key),2147483647) and info[key]>0 for key in ('version','bookVersion') if key in info}
        bookmark_id,ctx=context(rawmarks,info,self.identity,credentials['vid'],existing and existing['bookmark_id'])
        if marks_state(rawmarks,self.identity,credentials['vid'])!=observed['marks']:raise ValueError('annotation_experiment_context_changed')
        nonce=existing['nonce'] if existing else secrets.token_hex(16)
        if any(row['content'] in (note_text(nonce),note_text(nonce,True)) for row in observed['thoughts'].values()):raise ValueError('annotation_experiment_nonce_exists')
        bound=bind(credentials['vid'],self.identity,bookmark_id,nonce,ctx,observed)
        if existing is not None and bound!=existing:raise ValueError('annotation_experiment_plan_changed')
        if self.observe(credentials,'preview_independent')!=observed:raise ValueError('annotation_experiment_preflight_changed')
        self.plan=Plan(bound,ctx,observed);self.original=fingerprint(bound)
        self.report.update(shelf_books=len(observed['shelf']),existing_thoughts=len(observed['thoughts']),existing_marks=len(observed['marks']['updated']),
                           same_owner_verified=True,independent_preflight_unchanged=True,private_flag=1,planned_post_limit=3,
                           planned_operations=['create_private_test','edit_that_test','delete_that_test'],source_range_reused=True,
                           existing_records_are_not_write_targets=True)
        return self.plan

    def specification(self,pending):
        self.current();validate_context(self.plan.context,self.plan.bound['book_id'])
        if pending=='create_pending':
            stage,path,body='create_private_test','/review/add',dict(self.plan.context,content=note_text(self.plan.bound['nonce']))
        else:
            value,_receipt=self.store.read()
            if (value is None or value['created_id']!=self.created_id or self.created_id in self.plan.baseline['thoughts']
                    or value['plan']!=self.plan.bound):raise ValueError('annotation_experiment_existing_target')
            if pending=='edit_pending':stage,path,body='edit_private_test','/review/useredit',dict(reviewId=self.created_id,content=note_text(self.plan.bound['nonce'],True))
            elif pending=='delete_pending':stage,path,body='delete_private_test','/review/delete',dict(reviewId=self.created_id)
            else:raise ValueError('annotation_experiment_request')
        return stage,BASE+path,digest(body),body

    def post(self,credentials,pending):
        if self.confirmed is not True:raise ValueError('annotation_experiment_confirmation')
        self.current()
        stage,url,payload_digest,body=self.specification(pending)
        before={'create_pending':'prepared','edit_pending':'created','delete_pending':'edited'}[pending]
        self.receipt=self.store.advance(self.receipt,before,pending)
        self.dispatch=(stage,url,payload_digest,pending)
        response=None
        try:
            response=self.request(stage,url,body,credentials)
            self.report['receipt_shapes'].append(dict(stage=stage,known_fields=[key for key in ('reviewId','succ','success','status','errcode','errCode') if key in response],
                other_fields_count=len(set(response)-{'reviewId','succ','success','status','errcode','errCode'})))
        except ProbeError:
            self.report['receipt_shapes'].append(dict(stage=stage,unrecognized_or_lost=True))
        finally:self.dispatch=None
        return response

    def verify_observation(self,observed,stage,edited=False):
        baseline=self.plan.baseline
        if any(observed[key]!=baseline[key] for key in ('shelf','marks','position')):raise ValueError('annotation_experiment_unrelated_state')
        old,new=baseline['thoughts'],observed['thoughts']
        if stage=='deleted':
            if new==old:return True,None
            if set(new)-set(old) not in (set(),{self.created_id}):raise ValueError('annotation_experiment_unrelated_thoughts')
        else:
            if any(new.get(key)!=value for key,value in old.items()):raise ValueError('annotation_experiment_unrelated_thoughts')
            extra=set(new)-set(old)
            if len(extra)>1:raise ValueError('annotation_experiment_unrelated_thoughts')
            if not extra:return False,None
            identity=next(iter(extra))
            if self.created_id is not None and identity!=self.created_id:raise ValueError('annotation_experiment_target_changed')
            row=new[identity]
            if expected_new(row,self.plan.context,self.plan.bound['nonce'],edited):return True,row
            # A private test with its previous exact content may be waiting for
            # convergence. Any other target state requires manual reconciliation.
            if stage=='edited' and expected_new(row,self.plan.context,self.plan.bound['nonce'],False):return False,None
            raise ValueError('annotation_experiment_new_record_unverified')
        if any(new.get(key)!=value for key,value in old.items()):raise ValueError('annotation_experiment_unrelated_thoughts')
        return False,None

    def readback(self,credentials,stage,edited=False):
        for attempt in range(3):
            if attempt:self.sleep(.5*attempt)
            try:observed=self.observe(credentials,stage+'_readback')
            except ProbeError:continue
            success,row=self.verify_observation(observed,stage,edited)
            if success:return row
        raise ValueError('annotation_experiment_unconfirmed')

    def run(self,credentials,plan,store,receipt,*,confirmed=False):
        if confirmed is not True or plan is not self.plan or self.report['data_writes_attempted'] or not store.owns(receipt,'prepared'):
            raise ValueError('annotation_experiment_confirmation')
        value,_receipt=store.read()
        if value['plan']!=plan.bound:raise ValueError('annotation_experiment_plan_changed')
        self.store,self.receipt=store,receipt;self.current();self.confirmed=True
        if self.observe(credentials,'before_create')!=plan.baseline:raise ValueError('annotation_experiment_preflight_changed')
        self.post(credentials,'create_pending')
        row=self.readback(credentials,'created');self.created_id=row['reviewId']
        if self.created_id in plan.baseline['thoughts']:raise ValueError('annotation_experiment_existing_target')
        self.receipt=store.advance(self.receipt,'create_pending','created',created_id=self.created_id,record_sha256=digest(row))
        self.report['steps_verified'].append('created_private_test')
        # Re-read immediately before each subsequent write, using only the
        # independently identified new record. Existing record IDs never enter a POST.
        observed=self.observe(credentials,'before_edit');success,current=self.verify_observation(observed,'created')
        if not success or digest(current)!=digest(row):raise ValueError('annotation_experiment_target_changed')
        self.post(credentials,'edit_pending')
        row=self.readback(credentials,'edited',True)
        self.receipt=store.advance(self.receipt,'edit_pending','edited',created_id=self.created_id,record_sha256=digest(row))
        self.report['steps_verified'].append('edited_same_private_test')
        observed=self.observe(credentials,'before_delete');success,current=self.verify_observation(observed,'edited',True)
        if not success or digest(current)!=digest(row):raise ValueError('annotation_experiment_target_changed')
        self.post(credentials,'delete_pending')
        self.readback(credentials,'deleted');self.receipt=store.advance(self.receipt,'delete_pending','deleted')
        if self.observe(credentials,'independent_final')!=plan.baseline:raise ValueError('annotation_experiment_final_changed')
        self.receipt=store.advance(self.receipt,'deleted','verified');store.finish(self.receipt);self.receipt=None
        self.report['steps_verified'].append('deleted_and_original_state_verified')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    group=parser.add_mutually_exclusive_group();group.add_argument('--prepare',action='store_true');group.add_argument('--apply',action='store_true');group.add_argument('--check-pending',action='store_true');group.add_argument('--discard-prepared',action='store_true')
    parser.add_argument('--expected-intent');args=parser.parse_args(argv)
    if ((args.prepare or args.apply or args.check_pending or args.discard_prepared) and not args.saved_session
            or (args.apply or args.discard_prepared) and not (isinstance(args.expected_intent,str) and re.fullmatch('[a-f0-9]{64}',args.expected_intent))
            or args.expected_intent and not (args.apply or args.discard_prepared)):parser.error('explicit saved-session and exact expected-intent are required for apply/discard')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),data_writes_attempted=0,authentication_posts_attempted=0,
                private_values_saved_to_files=False,credentials_retained=True,intent_state='none')
    credentials=probe=store=receipt=None
    try:
        if args.saved_session:
            credentials=NativeSessionStore().load(SessionStore().load()['vid']);probe=AnnotationProbe()
            if args.prepare or args.apply or args.check_pending or args.discard_prepared:
                store=AnnotationExperimentStore();pending,receipt=store.read()
                if pending:
                    report['intent_state']=pending['phase']
                    if pending['plan']['owner']!=credentials['vid']:raise ValueError('annotation_experiment_owner')
            else:pending=None
            if args.discard_prepared:
                if pending is None or fingerprint(pending['plan'])!=args.expected_intent:raise ValueError('annotation_experiment_intent')
                store.finish(receipt,discard_prepared=True);report.update(result='ANNOTATION_PREPARED_INTENT_DISCARDED',intent_state='none')
            elif args.check_pending:
                if pending is None:raise ValueError('annotation_experiment_intent')
                probe.identity=pending['plan']['book_id'];probe.grant=digest(credentials)
                observed=probe.observe(credentials,'pending_read_only')
                nonce=pending['plan']['nonce'];matches=[row for row in observed['thoughts'].values() if row.get('content') in (note_text(nonce),note_text(nonce,True))]
                report.update(result='ANNOTATION_PENDING_STATE_READ',matching_test_records=len(matches),test_record_private=bool(matches) and all(row.get('isPrivate')==1 for row in matches),
                    original_position_unchanged=digest(observed['position'])==pending['plan']['position_sha256'],
                    original_thoughts_unchanged=digest(observed['thoughts'])==pending['plan']['thoughts_sha256'],
                    original_marks_unchanged=digest(observed['marks'])==pending['plan']['marks_sha256'],
                    original_shelf_flags_unchanged=digest(observed['shelf'])==pending['plan']['shelf_sha256'],
                    intent_fingerprint=fingerprint(pending['plan']))
            else:
                if args.prepare or args.apply:
                    if any(item.pending() for item in (FinishExperimentStore(),ShelfExperimentStore(),PositionExperimentStore())):raise ValueError('annotation_experiment_other_pending')
                if args.prepare and pending is not None:raise ValueError('annotation_experiment_intent')
                if args.apply and (pending is None or pending['phase']!='prepared' or fingerprint(pending['plan'])!=args.expected_intent):raise ValueError('annotation_experiment_intent')
                plan=probe.prepare(credentials,pending['plan'] if args.apply else None)
                if args.prepare:
                    receipt=store.prepare(plan.bound);report.update(result='ANNOTATION_EXPERIMENT_PREPARED',intent_state='prepared',intent_fingerprint=fingerprint(plan.bound))
                elif args.apply:
                    probe.run(credentials,plan,store,receipt,confirmed=True)
                    report.update(result='ANNOTATION_PRIVATE_CREATE_EDIT_DELETE_VERIFIED',intent_state='cleared',independent_original_state_restored=True)
                else:report['result']='ANNOTATION_EXPERIMENT_READ_ONLY_PREVIEW_VERIFIED'
    except KeyboardInterrupt:report.update(result='UNVERIFIED',reason='annotation_experiment_interrupted')
    except Exception as error:
        known={'version','mark_unavailable','metadata','plan','selection','notebooks','context_changed','preflight_changed','nonce_exists','plan_changed',
            'confirmation','unrelated_state','unrelated_thoughts','target_changed','new_record_unverified','unconfirmed','existing_target','final_changed','intent','other_pending','owner','context'}
        report.update(result='UNVERIFIED',reason=str(error) if str(error) in {'annotation_experiment_'+r for r in known} else 'annotation_experiment_failed')
    finally:
        if probe:
            report.update({key:value for key,value in probe.report.items() if key not in ('stages','checked_at')})
            report['stages']=[{key:value for key,value in row.items() if key in ('stage','status','error_code')} for row in probe.report['stages']]
            probe.plan=probe.grant=probe.dispatch=None
        if store:
            try:
                state,_receipt=store.read()
                if state is not None:report['intent_state']=state['phase']
            except Exception:report['intent_state']='unknown'
        if credentials:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0 if report['result']!='UNVERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
