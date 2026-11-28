"""Exact style-only changes to a newly created test highlight."""
from copy import deepcopy
from annotation_experiment_model import digest,valid_key
from highlight_trial_model import observe,PendingObservation,validate_plan as highlight_plan

PROTOCOL='source-highlight-two-styles-remove-v1'
NATIVE_PROTOCOL='native-source-highlight-two-styles-remove-v1'
PHASES=('create_pending','created','straight_pending','straight','wave_pending','wave','delete_pending','verified')


def validate_plan(value,*,native=False):
    if not isinstance(value,dict) or set(value)!={'protocol','highlight'} or value['protocol']!=(NATIVE_PROTOCOL if native else PROTOCOL):raise ValueError('mark_style/plan')
    highlight_plan(value['highlight']);return value


def bind(value,*,native=False):return validate_plan(dict(protocol=NATIVE_PROTOCOL if native else PROTOCOL,highlight=deepcopy(value)),native=native)


def style_body(row,style):
    if (not isinstance(row,dict) or not valid_key(row.get('bookmarkId')) or row.get('type')!=1
            or type(style) is not int or style not in (0,1,2)
            or type(row.get('colorStyle')) is not int or not 0<=row['colorStyle']<=5):raise ValueError('mark_style/body')
    return dict(bookmarkId=row['bookmarkId'],style=style,colorStyle=row['colorStyle'])


def observe_change(baseline,current,body,target,previous,style):
    if style!=previous['style'] and current['marks']['updated'].get(target['id'])==previous:
        observe(baseline,current,dict(body,style=previous['style']),target=target)
        raise PendingObservation('mark_style/not_visible')
    expected=dict(body,style=style)
    found=observe(baseline,current,expected)
    if found['id']!=target['id'] or found['id'] in baseline['marks']['updated']:raise ValueError('mark_style/target')
    row=current['marks']['updated'][found['id']]
    if row!=dict(previous,style=style):raise ValueError('mark_style/unrelated_field')
    return found,row


def target_valid(value):
    return (isinstance(value,dict) and set(value)=={'id','sha256'} and valid_key(value['id'])
            and isinstance(value['sha256'],str) and len(value['sha256'])==64
            and all(c in '0123456789abcdef' for c in value['sha256']))


def row_target(row):return dict(id=row['bookmarkId'],sha256=digest(row))
