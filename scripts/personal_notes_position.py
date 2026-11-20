"""Compare validated read-position replies, excluding only the response clock.

Actual native replies changed the root timestamp while every position/state
field stayed equal. Nested timestamps and all other metadata remain checked.
"""
from my_cloud_marks_model import integer
from verify_eink_readtime import validate_position


def unchanged(before,after,identity):
    states=[]
    for raw in (before,after):
        validate_position(raw,identity)
        state=dict(raw)
        if 'timestamp' in state:
            if not integer(state['timestamp'],2**53-1):raise ValueError('personal_notes_position_clock')
            del state['timestamp']
        states.append(state)
    return ('timestamp' in before)==('timestamp' in after) and states[0]==states[1]


def response_clock_matches(raw,started,finished):
    value=raw.get('timestamp')
    if 'timestamp' not in raw:return True
    if not integer(value,2**53-1):return False
    seconds=value/1000 if value>10**11 else value
    return started-5<=seconds<=finished+5
