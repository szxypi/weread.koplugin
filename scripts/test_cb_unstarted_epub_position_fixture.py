"""Offline checks of the EPUB time-then-position flow."""
import unittest
from unittest.mock import patch
from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from test_cb_fixture_position import fixture
from test_cb_fixture_position_transport import MemoryBackend
from test_cb_unstarted_epub_time_fixture import EpubHarness
from test_cb_unstarted_position_fixture import Harness as PositionHarness
import verify_cb_unstarted_position_fixture as task


class Harness(EpubHarness):
    probe_factory = PositionHarness.probe_factory
    def __init__(self, mode='success'):
        super().__init__(); self.position_mode=mode; self.position_sent=0
        book, sample=fixture(); sample['source_raw_sha256']='b'*64
        self.target=book; self.sample=sample; self.position['bookId']=book
        self.position_intent=Intent(backend=MemoryBackend()); self.position_evidence=Evidence(backend=MemoryBackend())
    def position_after(self, context, report):
        return task.position_trial(context,report,self.position_intent,self.position_evidence,
                                   probe_factory=self.probe_factory,sleep=self.sleep,fixture='epub')
    def execute_both(self):
        with patch.object(task,'CbReadingProbe',side_effect=self.source_factory):
            return self.execute(after_time=self.position_after)


class EpubPositionTest(unittest.TestCase):
    def test_first_position_preserves_time(self):
        h=Harness(); result=h.execute_both()
        self.assertEqual(result['result'],'UNSTARTED_TIME_FIXTURE_VERIFIED',result)
        self.assertEqual(result['position_probe']['result'],'PASS')
        self.assertTrue(result['position_probe']['counters_preserved'] and h.cleaned)
        self.assertEqual((h.sent,h.position_sent),(1,1))
        self.assertEqual(h.execute_both()['result'],'UNVERIFIED')
    def test_unconfirmed_position_is_not_replayed_or_removed(self):
        for mode in ('lost','no_ack','bad_count'):
            h=Harness(mode); result=h.execute_both()
            self.assertEqual(result['result'],'UNVERIFIED',result)
            self.assertTrue(result['position_write_uncertain']); self.assertFalse(h.cleaned)
            self.assertEqual((h.sent,h.position_sent),(1,1))
            self.assertEqual(h.execute_both()['result'],'UNVERIFIED')


if __name__=='__main__': unittest.main()
