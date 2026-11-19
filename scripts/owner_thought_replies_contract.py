"""Validate a private native-reader reply check without exposing its data."""
import json
from owner_annotation_contract import decode as decode_annotations
from verify_owner_reading import FRAME


def decode(raw, owner, *, mode=None, full_chapters=1):
    if not isinstance(raw, bytes) or len(raw) > 2*1024*1024 or raw.count(FRAME) != 1:
        raise ValueError('reply_frame')
    envelope = json.loads(raw.split(FRAME)[1])
    report = envelope['report']
    stages = [report] if mode else report['stages']
    checks = []
    for index, stage in enumerate(stages):
        selected_mode = mode or ('live', 'reopen')[index]
        check = stage['annotations'].pop('reply_check')
        if (not isinstance(check, dict) or set(check) != {'compared', 'parent_closed', 'position_unchanged', 'requests', 'denied_progress'}
                or any(type(check[k]) is not bool for k in ('compared', 'parent_closed', 'position_unchanged'))
                or type(check['requests']) is not int or not 0 <= check['requests'] <= 1
                or type(check['denied_progress']) is not int or not 0 <= check['denied_progress'] <= 255):
            raise ValueError('reply_report')
        if selected_mode == 'reopen' and (check['requests'] or check['denied_progress']
                or any(check[k] for k in ('compared', 'parent_closed', 'position_unchanged'))):
            raise ValueError('reply_offline')
        if selected_mode == 'live' and stage.get('result') == 'PASS' and (check['requests'] != 1 or check['denied_progress']
                or not all(check[k] for k in ('compared', 'parent_closed', 'position_unchanged'))):
            raise ValueError('reply_incomplete')
        checks.append(check)
    checked = decode_annotations(FRAME + json.dumps(envelope).encode(), owner, mode=mode, full_chapters=full_chapters)
    target = [checked['report']] if mode else checked['report']['stages']
    for stage, check in zip(target, checks): stage['annotations']['reply_check'] = check
    return checked
