"""Synthetic tests for a time-only fixture before its first chapter."""
from copy import deepcopy
import unittest

from cb_unstarted_time_fixture_flow import run


def observation(seconds=0):
    return dict(state=dict(kind='no_chapter',reason='progress_no_chapter'),
                presence=dict(uid=True,offset=True,index=False,summary=False),
                projection=dict(chapter_uid=0,chapter_idx=0,chapter_offset=0,raw_percent=0,summary=''),
                counters={key:dict(present=True,value=seconds if key=='readingTime' else 0)
                          for key in ('readingTime','recordReadingTime','ttsTime')})


class Harness:
    def __init__(self, mode='success'):
        self.mode=mode;self.pair={'native':observation(),'web':observation()};self.stats={'seconds':0}
        self.sent=0;self.claimed=False;self.pair_reads=0;self.stats_reads=0;self.reserved=False
    def read_pair(self):
        self.pair_reads+=1
        if self.mode=='baseline_changed' and self.pair_reads==2:self.pair['native']['projection']['summary']='changed'
        return deepcopy(self.pair)
    def read_stats(self):
        self.stats_reads+=1
        if self.mode=='stats_changed' and self.stats_reads==3:self.stats['seconds']=9
        return deepcopy(self.stats)
    def prepare(self,pair,stats):
        assert pair==self.pair and stats==self.stats
        return {'fixture':'synthetic','seconds':2}, [{'seconds':2}]
    def reserve(self,pair,stats,payload):
        assert not self.reserved and payload['seconds']==2
        self.reserved=True;return object()
    def bind(self,payload):self.payload=payload
    def claim(self,reservation):
        assert self.reserved and reservation and not self.claimed
        self.claimed=True;return 'single-use'
    def authorized(self,permit):return (not self.claimed if permit is None else self.claimed and permit=='single-use')
    def send(self,payload,permit):
        assert payload==self.payload and self.authorized(permit) and self.sent==0
        self.sent+=1;self.pair={'native':observation(2),'web':observation(2)};self.stats={'seconds':2}
        if self.mode=='position_changed':self.pair['web']['state']={'kind':'located'}
        if self.mode=='counter_changed':self.pair['native']['counters']['ttsTime']['value']=1
        if self.mode=='lost':raise TimeoutError()
        return {} if self.mode=='no_ack' else {'succ':1}
    def run(self):return run(self.read_pair,self.read_stats,self.prepare,self.reserve,self.bind,self.claim,
                              self.authorized,self.send,sleep=lambda _:None)


class UnstartedTimeFixtureTest(unittest.TestCase):
    def test_success_is_one_request_and_two_readbacks(self):
        h=Harness();result=h.run()
        self.assertEqual(h.sent,1);self.assertTrue(result['no_chapter_and_counts_verified'])
        self.assertTrue(result['statistics_verified']);self.assertTrue(result['cleanup_allowed'])
        self.assertFalse(result['write_uncertain']);self.assertEqual(h.run()['attempted'],0)

    def test_unconfirmed_result_never_allows_cleanup_or_replay(self):
        for mode in ('lost','no_ack','position_changed','counter_changed'):
            h=Harness(mode);result=h.run()
            self.assertEqual(h.sent,1);self.assertTrue(result['write_uncertain'])
            self.assertFalse(result['cleanup_allowed']);self.assertEqual(h.run()['attempted'],0)

    def test_pre_dispatch_changes_stop_without_send(self):
        for mode in ('baseline_changed','stats_changed'):
            h=Harness(mode);result=h.run()
            self.assertEqual(h.sent,0);self.assertFalse(result['cleanup_allowed'])

    def test_missing_or_nonzero_baseline_counts_refused(self):
        for value in (None,1,True):
            h=Harness();h.pair['web']['counters']['readingTime']['value']=value
            self.assertEqual(h.run()['attempted'],0);self.assertEqual(h.sent,0)
        h=Harness();h.pair['native']['counters']['readingTime']['present']=False
        self.assertEqual(h.run()['attempted'],0)

    def test_unstable_or_partial_postread_is_not_success(self):
        h=Harness();normal=h.send
        def partial(payload,permit):
            result=normal(payload,permit);h.pair['web']=observation();return result
        h.send=partial;result=h.run()
        self.assertEqual(h.sent,1);self.assertFalse(result['cleanup_allowed']);self.assertTrue(result['write_uncertain'])


if __name__=='__main__':unittest.main()
