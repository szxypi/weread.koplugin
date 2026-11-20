"""Bound one fresh selection, three native note writes and one optional cleanup."""
import re
from annotation_experiment_model import canonical,digest,valid_key,validate_context,note_text,expected_new
from my_cloud_marks_model import identifier,integer
from owner_selection_preview import validate_reference

PROTOCOL='native-fresh-selection-three-notes-optional-new-mark-cleanup-v1'
HASHES={name+'_sha256' for name in ('context','selection','catalog','thoughts','marks','position','shelf','web_position')}
FIELDS={'protocol','owner','book_id','chapter_uid','nonce','review_count','mark_count'}|HASHES


class PendingObservation(ValueError):
    def __init__(self,mark):super().__init__('selection_trial/not_converged');self.mark=mark


def validate_plan(value):
    if (not isinstance(value,dict) or set(value)!=FIELDS or value['protocol']!=PROTOCOL
            or any(not identifier(value[k]) for k in ('owner','book_id','chapter_uid'))
            or not isinstance(value['nonce'],str) or not re.fullmatch('[a-f0-9]{32}',value['nonce'])
            or not integer(value['review_count'],18) or not integer(value['mark_count'],5000)
            or any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in HASHES)):
        raise ValueError('selection_trial/plan')
    return value


def fingerprint(value):return digest(validate_plan(value))


def bind(owner,payload,context,baseline,chapters,web_position,nonce):
    cfg=payload['selection_preview'];validate_reference(cfg['reference'],payload['book_id'],payload['chapter_uid'])
    validate_context(context,payload['book_id'])
    value=dict(protocol=PROTOCOL,owner=owner,book_id=payload['book_id'],chapter_uid=payload['chapter_uid'],nonce=nonce,
               review_count=len(baseline['thoughts']),mark_count=len(baseline['marks']['updated']),context_sha256=digest(context),
               selection_sha256=digest({k:cfg[k] for k in ('first','last','reference')}),catalog_sha256=digest(chapters),web_position_sha256=digest(web_position))
    for key in ('thoughts','marks','position','shelf'):value[key+'_sha256']=digest(baseline[key])
    return validate_plan(value)


def observe(baseline,current,context,nonce,stage,created_id=None,mark=None):
    """Only one exact new note and one exact associated highlight may differ."""
    if stage not in ('created','edited','deleted'):raise ValueError('selection_trial/stage')
    if any(current[k]!=baseline[k] for k in ('shelf','position')):raise ValueError('selection_trial/unrelated_state')
    old,new=baseline['thoughts'],current['thoughts']
    if any(new.get(k)!=v for k,v in old.items()):raise ValueError('selection_trial/original_thought')
    extra=set(new)-set(old);row=None;pending=False
    if stage=='deleted':
        if extra:
            if len(extra)!=1 or created_id not in extra:raise ValueError('selection_trial/note_not_deleted')
            previous=new[created_id]
            if not (expected_new(previous,context,nonce,False) or expected_new(previous,context,nonce,True)):raise ValueError('selection_trial/note_not_deleted')
            pending=True
    else:
        if not extra:pending=True
        else:
            if len(extra)!=1:raise ValueError('selection_trial/new_thought')
            key=next(iter(extra));row=new[key]
            if created_id is not None and key!=created_id:raise ValueError('selection_trial/new_thought')
            if not expected_new(row,context,nonce,stage=='edited'):
                if stage=='edited' and expected_new(row,context,nonce,False):pending=True
                else:raise ValueError('selection_trial/new_thought')
    original,marks=baseline['marks'],current['marks']
    if (any(marks['chapters'].get(k)!=v for k,v in original['chapters'].items())
            or not set(marks['chapters']).difference(original['chapters'])<={context['chapterUid']}
            or any(marks['updated'].get(k)!=v for k,v in original['updated'].items())):
        raise ValueError('selection_trial/original_mark')
    added=set(marks['updated'])-set(original['updated']);associated=None
    if len(added)>1:raise ValueError('selection_trial/unrelated_mark')
    if added:
        key=next(iter(added));item=marks['updated'][key]
        if (not valid_key(key) or item.get('type')!=1 or type(item.get('type')) is not int
                or str(item.get('chapterUid'))!=context['chapterUid'] or item.get('range')!=context['range']
                or item.get('markText')!=context['abstract']):raise ValueError('selection_trial/unrelated_mark')
        associated=dict(id=key,sha256=digest(item))
        if mark is not None and associated!=mark:raise ValueError('selection_trial/associated_mark_changed')
    if pending:raise PendingObservation(associated)
    return row,associated


def restored(baseline,current,context,nonce,created_id,mark):
    _row,remaining=observe(baseline,current,context,nonce,'deleted',created_id,mark)
    return remaining is None
