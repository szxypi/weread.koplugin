"""One fresh CB selection with three thought writes and optional mark cleanup.

No network. A durable reservation covers every possible write; independently
observed unexpected changes or interrupted dispatches stop without replay.
"""
from pathlib import Path
import re
import tempfile
import time

from annotation_experiment_model import digest,note_text
from cb_fixture_highlight_trial import prepare as prepare_source
from cb_fixture_thought_trial import thought_context
from secure_native_session import project_lock
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import ACCOUNT,MacKeychain
from selection_trial_model import observe,restored,PendingObservation

SERVICE='org.codex.weread.cb-fixture-selection-intent-v1'
PROTOCOL='cb-fixture-selection-private-thought-v1'
FIELDS={'protocol','owner_sha256','book_sha256','attempt','nonce','source_sha256','context_sha256','baseline_sha256','request_sha256'}


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!=FIELDS or value['protocol']!=PROTOCOL:raise ValueError('cb_selection/plan')
    for key in ('attempt','nonce'):
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{32}',value[key]):raise ValueError('cb_selection/plan')
    for key in FIELDS-{'protocol','attempt','nonce'}:
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key]):raise ValueError('cb_selection/plan')
    return value


class Intent(SelectionTrialStore):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-cb-fixture-selection-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend,lock)
    def validate_plan(self,value):return validate_plan(value)


def prepare(owner,book,attempt,sample,version,baseline,nonce):
    if type(version) is not int or version<=0:raise ValueError('cb_selection/version')
    source,highlight=prepare_source(owner,book,attempt,sample,version,baseline)
    context=thought_context(highlight);body=dict(context,content=note_text(nonce))
    plan=validate_plan(dict(protocol=PROTOCOL,owner_sha256=digest(owner),book_sha256=digest(book),attempt=attempt,
        nonce=nonce,source_sha256=source['source_sha256'],context_sha256=digest(context),
        baseline_sha256=digest(baseline),request_sha256=digest(body)))
    return plan,context,body


def execute(plan,context,body,baseline,intent,owned,read,send_thought,send_cleanup,*,sleep=time.sleep):
    validate_plan(plan)
    if (digest(context)!=plan['context_sha256'] or digest(body)!=plan['request_sha256']
            or digest(baseline)!=plan['baseline_sha256'] or body!=dict(context,content=note_text(plan['nonce']))
            or not owned() or intent.read()[0] is not None or read()!=baseline or read()!=baseline):
        raise ValueError('cb_selection/preflight')
    receipt=intent.prepare(plan);receipt=intent.claim(receipt)
    target=None;known_mark=None
    def check(stage):
        nonlocal known_mark
        for attempt in range(3):
            if attempt:sleep(attempt*.5)
            if not owned():raise ValueError('cb_selection/ownership')
            try:return observe(baseline,read(),context,plan['nonce'],stage,target,known_mark)
            except PendingObservation as pending:
                known_mark=pending.mark or known_mark
                if attempt==2:raise
    for step,stage in enumerate(('created','edited','deleted'),1):
        state,current=intent.read()
        if (not owned() or current!=receipt or state is None or state['phase']!='pending'
                or state['native_steps']!=step-1 or state['plan']!=plan):raise ValueError('cb_selection/intent')
        payload=body if step==1 else dict(reviewId=target,**({'content':note_text(plan['nonce'],True)} if step==2 else {}))
        send_thought(step,payload,receipt)
        row,mark=check(stage)
        if step==1:target=row['reviewId']
        known_mark=mark or known_mark
        receipt=intent.native_step(receipt,step,target,known_mark)
        # Confirm the observed target and all unrelated state again before the next action.
        checked,mark=check(stage)
        if stage!='deleted' and digest(checked)!=digest(row):raise ValueError('cb_selection/changed')
        known_mark=mark or known_mark
    state,current=intent.read()
    if current!=receipt or state['native_steps']!=3 or not owned():raise ValueError('cb_selection/intent')
    snapshot=read();_row,mark=observe(baseline,snapshot,context,plan['nonce'],'deleted',target,known_mark)
    cleanup=False
    if mark is not None:
        if mark!=state['mark']:raise ValueError('cb_selection/mark')
        receipt=intent.claim_cleanup(receipt)
        send_cleanup({'bookmarkIds':[mark['id']]},receipt);cleanup=True
        for attempt in range(3):
            if attempt:sleep(attempt*.5)
            if not owned():raise ValueError('cb_selection/ownership')
            try:
                if restored(baseline,read(),context,plan['nonce'],target,mark):break
            except PendingObservation:pass
        else:raise ValueError('cb_selection/cleanup_unconfirmed')
    elif not restored(baseline,snapshot,context,plan['nonce'],target,known_mark):
        raise ValueError('cb_selection/unconfirmed')
    receipt=intent.verified_cleanup(receipt)
    final=read()
    if not owned() or not restored(baseline,final,context,plan['nonce'],target,known_mark):raise ValueError('cb_selection/final')
    changed=final['marks']['chapters']!=baseline['marks']['chapters']
    receipt=intent.complete(receipt);intent.finish(receipt)
    if intent.read()!=(None,None):raise ValueError('cb_selection/intent')
    return dict(result='PASS',thought_writes=3,cleanup_writes=int(cleanup),associated_highlight_observed=known_mark is not None,
                derived_chapter_metadata_changed=changed,original_records_restored=True)
