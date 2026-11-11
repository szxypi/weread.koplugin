"""Official reader palette and exact changes to one fresh test mark at a time."""
from annotation_experiment_model import digest,valid_key
from highlight_trial_model import request,observe,PendingObservation,validate_plan as highlight_plan
from mark_style_trial_model import target_valid

PROTOCOL='source-highlight-complete-color-palette-v1'
STEPS=(('create',1),('color',2),('color',3),('color',4),('color',5),('color',0),('color',1),('delete',None),
       ('create',2),('delete',None),('create',3),('delete',None),('create',4),('delete',None),('create',5),('delete',None))
LABELS=('Default color','Pink','Purple','Blue','Green','Yellow')


def valid_color(value):return type(value) is int and 0<=value<=5


def create_body(context,style=1,color=0):
    if type(style) is not int or style not in (0,1,2) or not valid_color(color):raise ValueError('mark_color/value')
    return dict(request(context),style=style,colorStyle=color)


def color_body(row,color):
    if (not isinstance(row,dict) or type(row.get('type')) is not int or row['type']!=1 or not valid_key(row.get('bookmarkId'))
            or type(row.get('style')) is not int or row['style'] not in (0,1,2)
            or not valid_color(row.get('colorStyle')) or not valid_color(color) or row['colorStyle']==color):
        raise ValueError('mark_color/body')
    return dict(bookmarkId=row['bookmarkId'],style=row['style'],colorStyle=color)


def sha(value):return isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value)


def validate_plan(value):
    if (not isinstance(value,dict) or set(value)!={'protocol','highlight','creation_hashes'} or value['protocol']!=PROTOCOL
            or not isinstance(value['creation_hashes'],list) or len(value['creation_hashes'])!=6
            or not all(sha(v) for v in value['creation_hashes']) or len(set(value['creation_hashes']))!=6):raise ValueError('mark_color/plan')
    highlight_plan(value['highlight'])
    if value['creation_hashes'][0]!=value['highlight']['request_sha256']:raise ValueError('mark_color/baseline_body')
    return value


def bind(highlight,context):
    return validate_plan(dict(protocol=PROTOCOL,highlight=highlight,creation_hashes=[digest(create_body(context,color=c)) for c in range(6)]))


def dispatch_hash(plan,step,target):
    validate_plan(plan)
    if type(step) is not int or not 0<=step<len(STEPS):raise ValueError('mark_color/step')
    operation,color=STEPS[step]
    if operation=='create':
        if target is not None:raise ValueError('mark_color/target')
        return plan['creation_hashes'][color]
    if not target_valid(target):raise ValueError('mark_color/target')
    body=dict(bookmarkIds=[target['id']]) if operation=='delete' else dict(bookmarkId=target['id'],style=1,colorStyle=color)
    return digest(body)


def observe_color(baseline,current,body,target,previous,color):
    if current['marks']['updated'].get(target['id'])==previous:
        observe(baseline,current,dict(body,colorStyle=previous['colorStyle']),target=target)
        raise PendingObservation('mark_color/not_visible')
    found=observe(baseline,current,dict(body,colorStyle=color))
    row=current['marks']['updated'][found['id']]
    if found['id']!=target['id'] or row!=dict(previous,colorStyle=color):raise ValueError('mark_color/unrelated_field')
    return found,row


def restored_projection(plan,current,target=None):
    """Prove original hashes, optionally omitting one exact new test mark.

    Before deletion only, a derived descriptor for that new mark's chapter
    may be omitted if doing so reproduces the full original marks hash.
    After deletion every original descriptor must match exactly.
    """
    selection=validate_plan(plan)['highlight']['selection']
    if any(digest(current[k])!=selection[k+'_sha256'] for k in ('shelf','position','thoughts')):return False
    marks=current['marks'];row=None
    if target is not None:
        if not target_valid(target):return False
        row=marks['updated'].get(target['id'])
        if row is None or digest(row)!=target['sha256'] or str(row.get('chapterUid'))!=selection['chapter_uid']:return False
        marks=dict(marks,updated={k:v for k,v in marks['updated'].items() if k!=target['id']})
    if len(marks['updated'])!=selection['mark_count']:return False
    if digest(marks)==selection['marks_sha256']:return True
    return target is not None and digest(dict(marks,chapters={k:v for k,v in marks['chapters'].items()
        if k!=selection['chapter_uid']}))==selection['marks_sha256']
