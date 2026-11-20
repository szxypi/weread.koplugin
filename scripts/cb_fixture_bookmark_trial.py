"""A source-bound point bookmark on one fresh self-authored CB fixture."""
from pathlib import Path
import tempfile

from annotation_experiment_model import digest
from bookmark_point import from_mark
from bookmark_trial_model import observe,request
from cb_fixture_highlight_trial import Intent as HighlightIntent,prepare as prepare_source,validate_plan as validate_highlight_plan
from my_mark_span import project as span_project
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain

SERVICE='org.codex.weread.cb-fixture-bookmark-intent-v1'
PROTOCOL='cb-synthetic-bookmark-create-remove-v1'


def validate_plan(value):
    if not isinstance(value,dict) or value.get('protocol')!=PROTOCOL:raise ValueError('cb_bookmark/plan')
    alternate=dict(value,protocol='cb-synthetic-highlight-create-remove-v1')
    validate_highlight_plan(alternate);return value


class Intent(HighlightIntent):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-cb-fixture-bookmark-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend,lock)
    def validate_plan(self,value):return validate_plan(value)


def prepare(owner,book,attempt,sample,version,baseline):
    if type(version) is not int or version<=0:raise ValueError('cb_bookmark/version')
    source,highlight=prepare_source(owner,book,attempt,sample,version,baseline)
    span=span_project(sample['source'],book,sample['chapter_uid'],dict(type=1,chapterUid=highlight['chapterUid'],
        range=highlight['range'],markText=highlight['markText']))
    context=dict(bookId=book,chapterUid=sample['chapter_uid'],bookVersion=version)
    body=request(context,sample['source'],span['first'])
    point=from_mark(sample['source'],book,sample['chapter_uid'],body)
    if point['chapter_offset']!=span['first']:raise ValueError('cb_bookmark/point')
    plan=validate_plan(dict(source,protocol=PROTOCOL,request_sha256=digest(body)))
    return plan,body


def execute(plan,body,baseline,intent,owned,read,send):
    validate_plan(plan)
    if (digest(body)!=plan['request_sha256'] or digest(baseline)!=plan['baseline_sha256'] or not owned()
            or intent.read()[0] is not None or read()!=baseline or read()!=baseline):raise ValueError('cb_bookmark/preflight')
    receipt=intent.reserve(plan)
    if not owned() or not intent.owns(receipt,'create_pending'):raise ValueError('cb_bookmark/ownership')
    send('create_pending',body,receipt)
    if not owned() or not intent.owns(receipt,'create_pending'):raise ValueError('cb_bookmark/ownership')
    created=read();target=observe(baseline,created,body)
    if not target:raise ValueError('cb_bookmark/unconfirmed')
    returned=created['marks']['updated'][target['id']]
    has_preview=isinstance(returned.get('markText'),str) and returned['markText']!=''
    receipt=intent.advance(receipt,'created',target=target)
    if not owned() or observe(baseline,read(),body,target=target)!=target:raise ValueError('cb_bookmark/changed')
    receipt=intent.advance(receipt,'delete_pending')
    if not owned() or not intent.owns(receipt,'delete_pending'):raise ValueError('cb_bookmark/ownership')
    send('delete_pending',{'bookmarkIds':[target['id']]},receipt)
    if not owned() or not intent.owns(receipt,'delete_pending'):raise ValueError('cb_bookmark/ownership')
    observe(baseline,read(),body,deleted=True,target=target)
    receipt=intent.advance(receipt,'verified');intent.finish(receipt)
    if intent.read()!=(None,None):raise ValueError('cb_bookmark/intent')
    return dict(result='PASS',writes=2,original_records_restored=True,server_preview_returned=has_preview)
