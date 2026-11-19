"""A private thought on one newly created, source-bound CB fixture highlight.

No network client. Durable, separate highlight and thought intents gate five
ordered writes; every original snapshot is compared before the next step.
"""
import re
from pathlib import Path
import tempfile
import time

from annotation_experiment_model import digest, expected_new, note_text
from cb_fixture_highlight_trial import prepare as prepare_highlight
from highlight_trial_model import PendingObservation, observe as observe_highlight
from secure_annotation_experiment import AnnotationExperimentStore
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain

SERVICE='org.codex.weread.cb-fixture-thought-intent-v1'
PROTOCOL='cb-fixture-private-thought-v1'
FIELDS={'protocol','owner_sha256','book_sha256','attempt','nonce','context_sha256','baseline_sha256','seed_sha256','request_sha256'}


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!=FIELDS or value['protocol']!=PROTOCOL:raise ValueError('cb_thought/plan')
    for key in ('attempt','nonce'):
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{32}',value[key]):raise ValueError('cb_thought/plan')
    for key in FIELDS-{'protocol','attempt','nonce'}:
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key]):raise ValueError('cb_thought/plan')
    return value


class ThoughtIntent(AnnotationExperimentStore):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-cb-fixture-thought-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend,lock)
    def validate_plan(self,value):return validate_plan(value)


def thought_context(body):
    if (not isinstance(body,dict) or set(body)!={'bookId','chapterUid','bookVersion','type','style','colorStyle','range','markText'}
            or body['type']!=1 or body['style']!=1 or body['colorStyle']!=0):raise ValueError('cb_thought/context')
    return dict(bookId=body['bookId'],chapterUid=str(body['chapterUid']),bookVersion=body['bookVersion'],
                type=1,range=body['range'],abstract=body['markText'],isPrivate=1)


def observe_thought(baseline,current,context,nonce,stage,created_id=None):
    if stage not in ('created','edited','deleted') or any(current[k]!=baseline[k] for k in ('shelf','marks','position')):
        raise ValueError('cb_thought/unrelated')
    old,new=baseline['thoughts'],current['thoughts']
    if any(new.get(key)!=value for key,value in old.items()):raise ValueError('cb_thought/original')
    added=set(new)-set(old)
    if stage=='deleted':
        if not added:return None
        if added!={created_id}:raise ValueError('cb_thought/target')
        raise PendingObservation('cb_thought/not_deleted')
    if not added:raise PendingObservation('cb_thought/not_visible')
    if len(added)!=1:raise ValueError('cb_thought/target')
    key=next(iter(added));row=new[key]
    if (created_id is not None and key!=created_id or row.get('reviewId')!=key
            or not expected_new(row,context,nonce,stage=='edited')):
        raise ValueError('cb_thought/target')
    return row


def execute(owner,book,attempt,sample,version,baseline,seed_intent,thought_intent,owned,read,send_seed,send_thought,
            *,nonce,sleep=time.sleep):
    seed_plan,seed_body=prepare_highlight(owner,book,attempt,sample,version,baseline)
    if (seed_intent.read()[0] is not None or thought_intent.read()[0] is not None or not owned()
            or read()!=baseline or read()!=baseline):raise ValueError('cb_thought/preflight')
    seed_receipt=seed_intent.reserve(seed_plan)
    if not owned() or not seed_intent.owns(seed_receipt,'create_pending'):raise ValueError('cb_thought/ownership')
    send_seed('create_pending',seed_body,seed_receipt)
    if not owned():raise ValueError('cb_thought/ownership')
    seed=observe_highlight(baseline,read(),seed_body)
    if not seed:raise ValueError('cb_thought/seed')
    seed_receipt=seed_intent.advance(seed_receipt,'created',target=seed)
    seed_snapshot=read()
    if not owned() or observe_highlight(baseline,seed_snapshot,seed_body,target=seed)!=seed:
        raise ValueError('cb_thought/seed')
    context=thought_context(seed_body);create=dict(context,content=note_text(nonce))
    plan=validate_plan(dict(protocol=PROTOCOL,owner_sha256=digest(owner),book_sha256=digest(book),attempt=attempt,nonce=nonce,
        context_sha256=digest(context),baseline_sha256=digest(seed_snapshot),seed_sha256=digest(seed),request_sha256=digest(create)))
    receipt=thought_intent.prepare(plan)
    def check(stage,created=None):
        for attempt_number in range(3):
            if attempt_number:sleep(.5*attempt_number)
            if not owned():raise ValueError('cb_thought/ownership')
            try:return observe_thought(seed_snapshot,read(),context,nonce,stage,created)
            except PendingObservation:
                if attempt_number==2:raise
    def dispatch(previous,pending,body):
        nonlocal receipt
        if not owned() or not thought_intent.owns(receipt,previous):raise ValueError('cb_thought/ownership')
        receipt=thought_intent.advance(receipt,previous,pending)
        send_thought(pending,body,receipt)
    dispatch('prepared','create_pending',create)
    row=check('created');created=row['reviewId']
    receipt=thought_intent.advance(receipt,'create_pending','created',created_id=created,record_sha256=digest(row))
    if digest(check('created',created))!=digest(row):raise ValueError('cb_thought/changed')
    dispatch('created','edit_pending',dict(reviewId=created,content=note_text(nonce,True)))
    row=check('edited',created)
    receipt=thought_intent.advance(receipt,'edit_pending','edited',created_id=created,record_sha256=digest(row))
    if digest(check('edited',created))!=digest(row):raise ValueError('cb_thought/changed')
    dispatch('edited','delete_pending',dict(reviewId=created))
    check('deleted',created);receipt=thought_intent.advance(receipt,'delete_pending','deleted')
    if not owned() or read()!=seed_snapshot:raise ValueError('cb_thought/final')
    receipt=thought_intent.advance(receipt,'deleted','verified');thought_intent.finish(receipt)
    if thought_intent.read()!=(None,None):raise ValueError('cb_thought/intent')
    if observe_highlight(baseline,read(),seed_body,target=seed)!=seed or not owned():raise ValueError('cb_thought/seed')
    seed_receipt=seed_intent.advance(seed_receipt,'delete_pending')
    if not seed_intent.owns(seed_receipt,'delete_pending') or not owned():raise ValueError('cb_thought/ownership')
    send_seed('delete_pending',{'bookmarkIds':[seed['id']]},seed_receipt)
    observe_highlight(baseline,read(),seed_body,deleted=True,target=seed)
    seed_receipt=seed_intent.advance(seed_receipt,'verified');seed_intent.finish(seed_receipt)
    if seed_intent.read()!=(None,None) or read()!=baseline:raise ValueError('cb_thought/final')
    return dict(result='PASS',seed_writes=2,thought_writes=3,original_records_restored=True)
