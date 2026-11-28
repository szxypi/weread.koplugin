"""Independent, single-dispatch recovery after an uncertain fixture mark."""
from copy import deepcopy
from itertools import product

from personal_upload_trial import hash_value
from reading_status_fixture_trial import request
from verify_finish_roundtrip import acknowledged


def reconstruct(current, digest):
    """Find the unique saved baseline among bounded, explicitly observed fields."""
    if current['progress']['flag'] != 1:
        raise ValueError('reading_recovery/flag')
    found = {}
    for choices in product(('same', 'zero', 'missing'), repeat=3):
        candidate = deepcopy(current)
        candidate['progress']['flag'] = 0
        candidate['progress']['observed']['isStartReading'] = 0
        fields = ((candidate['native'], 'readUpdateTime'), (candidate['web'], 'readUpdateTime'),
                  (candidate['progress']['observed'], 'startReadingTime'))
        for (item, key), choice in zip(fields, choices):
            if choice == 'zero':
                item[key] = 0
            elif choice == 'missing':
                item.pop(key, None)
        key = hash_value(candidate)
        if key == digest:
            found[key] = candidate
    if len(found) != 1:
        raise ValueError('reading_recovery/baseline')
    return next(iter(found.values()))


def run(mark, restore, bound, current, pending, observe, send):
    report = dict(result='UNVERIFIED', phase='preflight', restore_posts=0,
                  restore_acknowledged=False, flag_restored=False, exact_baseline_restored=False)
    try:
        state = bound()
        record, _ = mark.read()
        if (current() is not True or pending() is not True or restore.read()[0] is not None
                or not record or record['phase'] != 'claimed'):
            raise ValueError('reading_recovery/scope')
        plan = record['plan']
        expected = dict(owner=state['plan']['owner'], target=state['target'], upload_attempt=state['attempt'],
                        upload_plan_hash=hash_value(state['plan']), grant_hash=state['plan']['grant_sha256'])
        if (plan['selection'] != expected or plan['record'] != {'kind': 'mark'}
                or plan['body'] != request(state['target'], False)):
            raise ValueError('reading_recovery/binding')
        before = observe(state)
        if before != observe(state):
            raise ValueError('reading_recovery/unstable')
        baseline = reconstruct(before, plan['baseline']['snapshot_hash'])
        if (bound() != state or current() is not True or pending() is not True
                or observe(state) != before or restore.read()[0] is not None):
            raise ValueError('reading_recovery/changed')
        restore_plan = dict(selection=expected, record={'kind': 'restore'}, body=request(state['target'], True),
                            baseline={'snapshot_hash': hash_value(before)})
        report['phase'] = 'restore_pending'
        # send permanently claims the restore before dispatch; exceptions are
        # followed only by readback, never another write.
        report['restore_posts'] = 1
        try:
            response = send(state, restore_plan)
        except Exception:
            response = None
        report['restore_acknowledged'] = acknowledged(response)
        first, second = observe(state), observe(state)
        if first != second or bound() != state or current() is not True:
            raise ValueError('reading_recovery/unstable')
        report['flag_restored'] = first['progress']['flag'] == 0
        report['exact_baseline_restored'] = first == baseline and hash_value(first) == plan['baseline']['snapshot_hash']
        report['phase'] = 'readback_complete'
        if report['flag_restored'] and report['exact_baseline_restored']:
            report['result'] = 'RESTORED' if report['restore_acknowledged'] else 'RESTORED_ACK_UNKNOWN'
    except Exception:
        pass
    return report
