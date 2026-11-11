"""One source-bound new highlight; original annotations are never targets."""
from annotation_experiment_model import digest,valid_key
from selection_trial_model import validate_plan as selection_plan

PROTOCOL='source-highlight-create-remove-v1'
NATIVE_PROTOCOL='native-source-highlight-create-remove-v1'


def validate_plan(value,*,native=False):
    if (not isinstance(value,dict) or set(value)!={'protocol','selection','request_sha256'}
            or value['protocol']!=(NATIVE_PROTOCOL if native else PROTOCOL)):raise ValueError('highlight_trial/plan')
    selection_plan(value['selection'])
    h=value['request_sha256']
    if not isinstance(h,str) or len(h)!=64 or any(c not in '0123456789abcdef' for c in h):raise ValueError('highlight_trial/plan')
    return value


def request(context):
    # Native chapterIdx is intentionally absent. Web catalog ordinals have
    # not been proven to be native chapter indices.
    return dict(bookId=context['bookId'],chapterUid=int(context['chapterUid']),bookVersion=context['bookVersion'],
                type=1,style=1,colorStyle=0,range=context['range'],markText=context['abstract'])


def bind(selection,body):
    return validate_plan(dict(protocol=PROTOCOL,selection=selection,request_sha256=digest(body)))


def bind_native(selection,body):
    value=bind(selection,body);value['protocol']=NATIVE_PROTOCOL
    return validate_plan(value,native=True)


class PendingObservation(ValueError):
    pass


def observe(baseline,current,body,*,deleted=False,target=None):
    """Protect full projected originals and match only one exact new mark."""
    if any(current[k]!=baseline[k] for k in ('shelf','position','thoughts')):raise ValueError('highlight_trial/unrelated_state')
    old,new=baseline['marks'],current['marks']
    if (any(new['updated'].get(k)!=v for k,v in old['updated'].items())
            or any(new['chapters'].get(k)!=v for k,v in old['chapters'].items())
            or not set(new['chapters']).difference(old['chapters'])<={str(body['chapterUid'])}):raise ValueError('highlight_trial/original_mark')
    added=set(new['updated'])-set(old['updated'])
    if not added:
        if deleted:return None
        raise PendingObservation('highlight_trial/not_visible')
    if len(added)!=1:raise ValueError('highlight_trial/extra_mark')
    key=next(iter(added));row=new['updated'][key]
    if (not valid_key(key) or row.get('bookmarkId')!=key
            or any(type(row.get(k)) is not int or row[k]!=body[k] for k in ('chapterUid','type','style','colorStyle'))
            or any(row.get(k)!=body[k] for k in ('range','markText'))):raise ValueError('highlight_trial/mark')
    found=dict(id=key,sha256=digest(row))
    if target is not None and found!=target:raise ValueError('highlight_trial/target_changed')
    if deleted:raise PendingObservation('highlight_trial/not_removed')
    return found
