"""Bounded first-position experiment for a separately owned synthetic book.

No network, storage or credentials live here. The caller supplies scoped reads,
durable claims and a sender bound to the freshly imported fixture. Unknown
effects prohibit both a second request and automatic fixture cleanup.
"""
from copy import deepcopy

from cb_fixture_position import LONG_SUMMARY
from verify_position_roundtrip import acknowledged


def _zero_counts(value):
    counts = value.get('counters')
    return isinstance(counts, dict) and all(
        isinstance(counts.get(key), dict) and counts[key].get('present') is True
        and type(counts[key].get('value')) is int and counts[key]['value'] == 0
        for key in ('readingTime', 'recordReadingTime', 'ttsTime'))


def _classify(sample, baseline, target):
    if not isinstance(sample, dict) or set(sample) != {'native', 'web'}:
        raise ValueError('cb_first/channels')
    native, web = sample['native'], sample['web']
    if not isinstance(native, dict) or not isinstance(web, dict) or not _zero_counts(native):
        raise ValueError('cb_first/counts')
    kinds = []
    for channel, value in (('native', native), ('web', web)):
        state = value.get('state')
        if not isinstance(state, dict): raise ValueError('cb_first/state')
        if state.get('kind') == 'no_chapter':
            if baseline is not None and value != baseline[channel]: raise ValueError('cb_first/baseline_changed')
            kinds.append('original'); continue
        if (state.get('kind') != 'located' or state.get('book_id') != target['book']
                or state.get('chapter_uid') != target['chapter'] or state.get('chapter_idx') != target['index']
                or state.get('chapter_offset') != target['first'] or state.get('raw_percent') != target['percent']
                or state.get('summary_present') is not True or state.get('summary') != LONG_SUMMARY):
            raise ValueError('cb_first/unexpected_position')
        kinds.append('target')
    return kinds


def _stable(read_pair, baseline, target, sleep):
    previous = None
    for index in range(4):
        if index: sleep(0.5)
        sample = read_pair()
        kinds = _classify(sample, baseline, target)
        if kinds[0] == kinds[1] and sample == previous:
            return kinds[0], deepcopy(sample)
        previous = deepcopy(sample)
    raise ValueError('cb_first/readback_unstable')


def run(target, read_pair, claim, authorized, send, *, sleep):
    """Verify one exact synthetic target, returning aggregate outcome only.

    Claims must survive process death and cannot be reused; send must enforce
    the exact stage and owned-fixture scope independently of this coordinator.
    No cleanup authority is returned without a fully confirmed target.
    """
    result = dict(result='UNVERIFIED', writes=0, enter_ack=False, position_ack=False,
                  target_readback=False, cleanup_allowed=False, entry_effect='unknown')
    try:
        kind, baseline = _stable(read_pair, None, target, sleep)
        if kind != 'original': raise ValueError('cb_first/not_unstarted')
        if not authorized(None): raise ValueError('cb_first/scope')
        receipt = claim('write_enter')
        if not authorized(receipt): raise ValueError('cb_first/scope')
        kind, _ = _stable(read_pair, baseline, target, sleep)
        if kind != 'original' or not authorized(receipt): raise ValueError('cb_first/baseline_changed')
        result['writes'] += 1
        if not acknowledged(send('enter', receipt)): raise ValueError('cb_first/ack')
        result['enter_ack'] = True
        kind, _ = _stable(read_pair, baseline, target, sleep)
        result['entry_effect'] = kind
        if kind == 'original':
            receipt = claim('write_same')
            if not authorized(receipt): raise ValueError('cb_first/scope')
            kind, _ = _stable(read_pair, baseline, target, sleep)
            if kind != 'original' or not authorized(receipt): raise ValueError('cb_first/baseline_changed')
            result['writes'] += 1
            if not acknowledged(send('same', receipt)): raise ValueError('cb_first/ack')
            result['position_ack'] = True
            kind, _ = _stable(read_pair, baseline, target, sleep)
        if kind != 'target' or not authorized(receipt): raise ValueError('cb_first/target')
        result.update(result='PASS', target_readback=True, cleanup_allowed=True)
    except Exception:
        pass
    return result
