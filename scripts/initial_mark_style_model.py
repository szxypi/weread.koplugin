"""Bind an independently tested initial style to a fresh highlight plan."""
from copy import deepcopy
from highlight_trial_model import request,validate_plan as highlight_plan,bind as highlight_bind

PROTOCOL='source-highlight-initial-style-create-remove-v1'


def create_body(context,style):
    if type(style) is not int or style not in (0,1,2):raise ValueError('initial_style/value')
    return dict(request(context),style=style)


def validate_plan(value):
    if (not isinstance(value,dict) or set(value)!={'protocol','style','highlight'}
            or value['protocol']!=PROTOCOL or type(value['style']) is not int or value['style'] not in (0,1,2)):
        raise ValueError('initial_style/plan')
    highlight_plan(value['highlight']);return value


def bind(selection,context,style):
    return validate_plan(dict(protocol=PROTOCOL,style=style,highlight=highlight_bind(deepcopy(selection),create_body(context,style))))
