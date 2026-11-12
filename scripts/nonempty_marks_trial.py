"""A new color/style highlight while both original collections stay nonempty."""
from annotation_experiment_model import digest
from highlight_trial_model import validate_plan as highlight_plan

PROTOCOL='native-nonempty-highlight-color-style-remove-v1'
PHASES=('create_pending','created','color_pending','colored','style_pending','styled','delete_pending','verified')


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!={'protocol','highlight','chapter_marks'} or value['protocol']!=PROTOCOL:raise ValueError('nonempty_marks/plan')
    highlight_plan(value['highlight']);selection=value['highlight']['selection']
    if (not selection['mark_count'] or not selection['review_count'] or type(value['chapter_marks']) is not int
            or not 1<=value['chapter_marks']<=selection['mark_count']):raise ValueError('nonempty_marks/baseline')
    return value


def bind(highlight,baseline):
    highlight_plan(highlight);selection=highlight['selection']
    if any(digest(baseline[k])!=selection[k+'_sha256'] for k in ('marks','thoughts','shelf','position')):raise ValueError('nonempty_marks/changed')
    count=sum(type(row.get('type')) is int and row['type']==1 and str(row.get('chapterUid'))==selection['chapter_uid'] for row in baseline['marks']['updated'].values())
    return validate_plan(dict(protocol=PROTOCOL,highlight=highlight,chapter_marks=count))
