"""One first position after verified time-only reporting on a new CB fixture.

The caller binds its freshly imported fixture, exact source, request and
persistent single-use claim. No network or credential handling lives here.
"""
from copy import deepcopy

from cb_unstarted_time_fixture_flow import _counters
from verify_position_roundtrip import acknowledged


def _baseline(pair):
    if not isinstance(pair, dict) or set(pair) != {'native', 'web'}:
        raise ValueError('unstarted_position/channels')
    for value in pair.values():
        if (not isinstance(value, dict) or set(value) != {'state', 'presence', 'projection', 'counters'}
                or value['state'] != {'kind':'no_chapter', 'reason':'progress_no_chapter'}
                or _counters(value) != dict(readingTime=2, recordReadingTime=0, ttsTime=0)):
            raise ValueError('unstarted_position/baseline')
    return deepcopy(pair)


def _kind(pair, baseline, target):
    if not isinstance(pair, dict) or set(pair) != {'native', 'web'}:
        raise ValueError('unstarted_position/channels')
    kinds=[]
    for channel in ('native', 'web'):
        value=pair[channel]
        if not isinstance(value,dict) or _counters(value) != dict(readingTime=2, recordReadingTime=0, ttsTime=0):
            raise ValueError('unstarted_position/counters')
        if value==baseline[channel]:
            kinds.append('original');continue
        point=value.get('state')
        if (not isinstance(point,dict) or point.get('kind')!='located'
                or point.get('book_id')!=target['book'] or point.get('chapter_uid')!=target['chapter']
                or point.get('chapter_idx')!=target['index'] or point.get('chapter_offset')!=target['offset']
                or point.get('raw_percent')!=target['percent'] or point.get('summary_present') is not True
                or point.get('summary')!=target['summary']):
            raise ValueError('unstarted_position/target')
        kinds.append('target')
    return 'target' if kinds==['target','target'] else 'original' if kinds==['original','original'] else 'partial'


def run(target, read_pair, read_stats, prepare, reserve, bind, claim, authorized, send, *, sleep):
    result=dict(result='UNVERIFIED', attempted=0, acknowledged=False, target_verified=False,
                counters_preserved=False, statistics_preserved=False, cleanup_allowed=False, write_uncertain=False)
    try:
        if authorized(None) is not True: raise ValueError('unstarted_position/authority')
        baseline=_baseline(read_pair()); stats=deepcopy(read_stats())
        if _baseline(read_pair())!=baseline or read_stats()!=stats: raise ValueError('unstarted_position/unstable')
        payload=prepare(deepcopy(baseline),deepcopy(stats))
        if not isinstance(payload,dict): raise ValueError('unstarted_position/payload')
        if authorized(None) is not True or _baseline(read_pair())!=baseline or read_stats()!=stats:
            raise ValueError('unstarted_position/changed')
        reservation=reserve(deepcopy(baseline),deepcopy(stats),deepcopy(payload))
        bind(deepcopy(payload)); permit=claim(reservation)
        if (authorized(permit) is not True or _baseline(read_pair())!=baseline
                or read_stats()!=stats or authorized(permit) is not True):
            raise ValueError('unstarted_position/changed')
        result['attempted']=1;result['write_uncertain']=True
        if not acknowledged(send(deepcopy(payload),permit)): raise ValueError('unstarted_position/ack')
        result['acknowledged']=True;previous=None
        for index in range(6):
            if index:sleep(min(index*2,5))
            if authorized(permit) is not True: raise ValueError('unstarted_position/authority')
            pair=read_pair()
            if read_stats()!=stats: raise ValueError('unstarted_position/statistics')
            if _kind(pair,baseline,target)=='target':
                if previous==pair:
                    result.update(result='PASS',target_verified=True,counters_preserved=True,
                                  statistics_preserved=True,cleanup_allowed=True,write_uncertain=False)
                    break
                previous=deepcopy(pair)
            else:previous=None
    except Exception:
        pass
    return result
