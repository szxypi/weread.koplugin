from copy import deepcopy
import unittest

from cb_unstarted_position_fixture_flow import run
from test_cb_unstarted_time_fixture_flow import observation

TARGET=dict(book='CB_Test',chapter='2',index=1,offset=12,percent=1,summary='synthetic first position')


def located():
    value=observation(2)
    value['state']=dict(kind='located',book_id=TARGET['book'],chapter_uid=TARGET['chapter'],chapter_idx=TARGET['index'],
                        chapter_offset=TARGET['offset'],raw_percent=TARGET['percent'],summary=TARGET['summary'],summary_present=True)
    value['presence']['summary']=True
    value['projection'].update(chapter_uid=2,chapter_idx=1,chapter_offset=12,raw_percent=1,summary=TARGET['summary'])
    return value


class Harness:
    def __init__(self,mode='success'):
        self.mode=mode;self.pair={'native':observation(2),'web':observation(2)};self.stats={'seconds':2}
        self.sent=0;self.claimed=False;self.reserved=False;self.reads=0
    def read_pair(self):
        self.reads+=1
        if self.mode=='baseline_changed' and self.reads==2:self.pair['native']['counters']['readingTime']['value']=3
        return deepcopy(self.pair)
    def read_stats(self):return deepcopy(self.stats)
    def prepare(self,_pair,_stats):return {'fixture':'synthetic','elapsed':0}
    def reserve(self,*_):assert not self.reserved;self.reserved=True;return object()
    def bind(self,payload):self.payload=payload
    def claim(self,reservation):assert reservation and not self.claimed;self.claimed=True;return 'once'
    def authorized(self,permit):return not self.claimed if permit is None else self.claimed and permit=='once'
    def send(self,payload,permit):
        assert payload==self.payload and self.authorized(permit) and self.sent==0
        self.sent+=1;self.pair={'native':located(),'web':located()}
        if self.mode=='counter_changed':self.pair['native']['counters']['readingTime']['value']=0
        if self.mode=='position_changed':self.pair['web']['state']['chapter_offset']+=1
        if self.mode=='statistics_changed':self.stats={'seconds':3}
        if self.mode=='lost':raise TimeoutError()
        return {} if self.mode=='no_ack' else {'succ':1}
    def run(self):return run(TARGET,self.read_pair,self.read_stats,self.prepare,self.reserve,self.bind,self.claim,
                              self.authorized,self.send,sleep=lambda _:None)


class FirstPositionFixtureTest(unittest.TestCase):
    def test_one_write_and_complete_independent_readbacks(self):
        h=Harness();result=h.run();self.assertEqual(result['result'],'PASS')
        self.assertEqual(h.sent,1);self.assertTrue(result['cleanup_allowed'] and result['counters_preserved'])
        self.assertEqual(h.run()['attempted'],0);self.assertEqual(h.sent,1)

    def test_unknown_or_changed_result_never_cleans_or_replays(self):
        for mode in ('lost','no_ack','counter_changed','position_changed','statistics_changed'):
            h=Harness(mode);result=h.run();self.assertEqual(h.sent,1)
            self.assertTrue(result['write_uncertain']);self.assertFalse(result['cleanup_allowed'])
            self.assertEqual(h.run()['attempted'],0)

    def test_invalid_baselines_stop_before_dispatch(self):
        h=Harness('baseline_changed');self.assertEqual(h.run()['attempted'],0)
        h=Harness();h.pair['web']['counters']['readingTime']['value']=0
        self.assertEqual(h.run()['attempted'],0);self.assertEqual(h.sent,0)


if __name__=='__main__':unittest.main()
