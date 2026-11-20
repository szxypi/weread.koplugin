"""A single new type-0 bookmark; never changes an original cloud mark."""
from copy import deepcopy
from annotation_experiment_model import digest,valid_key
from selection_trial_model import validate_plan as selection_plan
from highlight_trial_model import PendingObservation
from bookmark_point import project,point_range

PROTOCOL='source-point-bookmark-create-remove-v1'
NATIVE_PROTOCOL='native-source-point-bookmark-create-remove-v1'


def validate_plan(value,*,native=False):
    if (not isinstance(value,dict) or set(value)!={'protocol','selection','request_sha256'}
            or value['protocol']!=(NATIVE_PROTOCOL if native else PROTOCOL)
            or not isinstance(value['request_sha256'],str) or len(value['request_sha256'])!=64
            or any(c not in '0123456789abcdef' for c in value['request_sha256'])):raise ValueError('bookmark_trial/plan')
    selection_plan(value['selection']);return value


def request(context,raw,co):
    value=project(raw,co)
    return dict(bookId=context['bookId'],chapterUid=int(context['chapterUid']),bookVersion=context['bookVersion'],
                type=0,style=0,range=value['range'],markText=value['markText'])


def bind(selection,body,*,native=False):
    return validate_plan(dict(protocol=NATIVE_PROTOCOL if native else PROTOCOL,selection=deepcopy(selection),request_sha256=digest(body)),native=native)


def observe(baseline,current,body,*,deleted=False,target=None):
    if any(current[k]!=baseline[k] for k in ('shelf','position','thoughts')):raise ValueError('bookmark_trial/unrelated_state')
    old,new=baseline['marks'],current['marks']
    if (any(new['updated'].get(k)!=v for k,v in old['updated'].items())
            or any(new['chapters'].get(k)!=v for k,v in old['chapters'].items())
            or not set(new['chapters']).difference(old['chapters'])<={str(body['chapterUid'])}):raise ValueError('bookmark_trial/original_mark')
    added=set(new['updated'])-set(old['updated'])
    if not added:
        if deleted:return None
        raise PendingObservation('bookmark_trial/not_visible')
    if len(added)!=1:raise ValueError('bookmark_trial/extra_mark')
    key=next(iter(added));row=new['updated'][key]
    if (not valid_key(key) or row.get('bookmarkId')!=key or type(row.get('type')) is not int or row['type']!=0
            or type(row.get('chapterUid')) is not int or row['chapterUid']!=body['chapterUid'] or row.get('range')!=body['range']):raise ValueError('bookmark_trial/mark')
    point_range(row['range'])
    for name in ('style','colorStyle'):
        if name in row and (type(row[name]) is not int or row[name]!=0):raise ValueError('bookmark_trial/style')
    if row.get('markText') not in (None,'',body['markText']):raise ValueError('bookmark_trial/text')
    found=dict(id=key,sha256=digest(row))
    if target is not None and found!=target:raise ValueError('bookmark_trial/changed_target')
    if deleted:raise PendingObservation('bookmark_trial/not_removed')
    return found
