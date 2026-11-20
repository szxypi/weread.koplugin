"""Coordinator for testing time-only reporting before a CB first position.

This module has no network or persistence. Its caller must bind a newly
imported fixture, independently validate the exact signed request, and use a
single-use durable claim. Inconclusive results never authorize fixture cleanup.
"""
from copy import deepcopy

from readtime_upload_model import confirmed

COUNTERS = ('readingTime', 'recordReadingTime', 'ttsTime')


def _counters(value):
    counters = value.get('counters') if isinstance(value, dict) else None
    if not isinstance(counters, dict) or set(counters) != set(COUNTERS):
        raise ValueError('unstarted_time/counters')
    result = {}
    for key in COUNTERS:
        item = counters[key]
        if (not isinstance(item, dict) or set(item) != {'present', 'value'} or item['present'] is not True
                or type(item['value']) is not int or not 0 <= item['value'] <= 9007199254740991):
            raise ValueError('unstarted_time/counters')
        result[key] = item['value']
    return result


def _baseline(pair):
    if not isinstance(pair, dict) or set(pair) != {'native', 'web'}:
        raise ValueError('unstarted_time/channels')
    for value in pair.values():
        if (not isinstance(value, dict) or set(value) != {'state', 'presence', 'projection', 'counters'}
                or value['state'] != {'kind': 'no_chapter', 'reason': 'progress_no_chapter'}
                or not isinstance(value['presence'], dict) or not isinstance(value['projection'], dict)
                or any(_counters(value).values())):
            raise ValueError('unstarted_time/baseline')
    return deepcopy(pair)


def _kind(pair, baseline):
    if not isinstance(pair, dict) or set(pair) != {'native', 'web'}:
        raise ValueError('unstarted_time/channels')
    values = []
    for channel in ('native', 'web'):
        value, old = pair[channel], baseline[channel]
        if (not isinstance(value, dict) or set(value) != set(old)
                or any(value[key] != old[key] for key in ('state', 'presence', 'projection'))):
            raise ValueError('unstarted_time/position_changed')
        count = _counters(value)
        if count['recordReadingTime'] != 0 or count['ttsTime'] != 0 or count['readingTime'] not in (0, 2):
            raise ValueError('unstarted_time/counters_changed')
        values.append(count['readingTime'])
    return 'target' if values == [2, 2] else 'original' if values == [0, 0] else 'partial'


def run(read_pair, read_stats, prepare, reserve, bind, claim, authorized, send, *, sleep):
    """Send at most one fixture-only two-second report and read back twice.

    prepare receives two stable baseline objects and returns an exact payload
    plus a list of acceptable post-write statistics. reserve must persist the
    private pre-dispatch evidence. bind and send must independently constrain
    the exact payload, fixture owner and live durable claim.
    """
    result = dict(result='UNVERIFIED', attempted=0, acknowledged=False,
                  no_chapter_and_counts_verified=False, statistics_verified=False,
                  cleanup_allowed=False, write_uncertain=False)
    try:
        if authorized(None) is not True: raise ValueError('unstarted_time/authority')
        original = _baseline(read_pair()); stats = deepcopy(read_stats())
        if _baseline(read_pair()) != original or read_stats() != stats:
            raise ValueError('unstarted_time/unstable')
        payload, targets = prepare(deepcopy(original), deepcopy(stats))
        if not isinstance(payload, dict) or not isinstance(targets, list) or not targets:
            raise ValueError('unstarted_time/plan')
        if authorized(None) is not True or _baseline(read_pair()) != original or read_stats() != stats:
            raise ValueError('unstarted_time/changed')
        reservation = reserve(deepcopy(original), deepcopy(stats), deepcopy(payload))
        bind(deepcopy(payload))
        permit = claim(reservation)
        if (authorized(permit) is not True or _baseline(read_pair()) != original
                or read_stats() != stats or authorized(permit) is not True):
            raise ValueError('unstarted_time/changed')
        result['attempted'] = 1; result['write_uncertain'] = True
        response = send(deepcopy(payload), permit)
        if not confirmed(response): raise ValueError('unstarted_time/ack')
        result['acknowledged'] = True
        previous = None
        for index in range(6):
            if index: sleep(min(index * 2, 5))
            if authorized(permit) is not True: raise ValueError('unstarted_time/authority')
            pair, observed_stats = read_pair(), read_stats()
            kind = _kind(pair, original)
            if observed_stats != stats and observed_stats not in targets:
                raise ValueError('unstarted_time/statistics_changed')
            if kind == 'target' and observed_stats in targets:
                current = (deepcopy(pair), deepcopy(observed_stats))
                if previous == current:
                    result.update(result='PASS', no_chapter_and_counts_verified=True,
                                  statistics_verified=True, cleanup_allowed=True, write_uncertain=False)
                    break
                previous = current
            else:
                previous = None
    except Exception:
        pass
    return result
