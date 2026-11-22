import copy
import unittest
from unittest.mock import patch
from native_shelf_trial import bind
from verify_eink_login import BASE
from verify_owner_shelf_membership import members_digest
from verify_pin_preflight import PinProbe,prepare,progress_fingerprint


def shelf():return {'books':[{'bookId':'41','title':'Synthetic','secret':0,'finishReading':0}],'archive':[]}


class Probe:
    def __init__(self):
        self.target=None;self.counts={};self.progress_changed=False
        self.bound=bind({'owner':'123','book_id':'42','members_sha256':members_digest({'41':{}}),'grant_sha256':'a'*64},shelf())
    def prepare(self,_credentials):return self.bound
    def request(self,stage,_url,credentials=None):
        self.counts[stage]=self.counts.get(stage,0)+1
        if stage=='pin_progress':return {'position':self.counts[stage] if self.progress_changed else 1}
        return copy.deepcopy(shelf())


class Web:
    def request(self,*args):return copy.deepcopy(shelf())


class PreflightTests(unittest.TestCase):
    def test_only_server_clock_is_ignored(self):
        baseline={'timestamp':1,'progress':{'position':3},'future':1}
        self.assertEqual(progress_fingerprint(baseline),progress_fingerprint(dict(baseline,timestamp=2)))
        self.assertNotEqual(progress_fingerprint(baseline),progress_fingerprint(dict(baseline,future=2)))
        with self.assertRaises(ValueError):progress_fingerprint(dict(baseline,timestamp=True))

    def test_three_bound_shelves_and_two_observations(self):
        probe=Probe();report={'gateway_read_posts':0}
        with patch('verify_pin_preflight.gateway',side_effect=lambda _key:copy.deepcopy(shelf())):
            plans,progress,key=prepare(probe,Web(),{},'wrk-xxxxxxxxxxxxxxxx',report)
        self.assertEqual(set(plans),{'native','web','gateway'});self.assertEqual(len(progress),64);self.assertEqual(len(key),64)
        self.assertEqual(report['gateway_read_posts'],2);self.assertEqual(probe.counts['pin_progress'],2)

    def test_changed_progress_stops_before_second_shelf_round(self):
        probe=Probe();probe.progress_changed=True;report={'gateway_read_posts':0}
        with patch('verify_pin_preflight.gateway',side_effect=lambda _key:copy.deepcopy(shelf())):
            with self.assertRaises(ValueError):prepare(probe,Web(),{},'wrk-xxxxxxxxxxxxxxxx',report)
        self.assertEqual(report['gateway_read_posts'],1)

    def test_mismatched_gateway_does_not_prepare(self):
        probe=Probe();report={'gateway_read_posts':0}
        with patch('verify_pin_preflight.gateway',return_value={'books':[],'archive':[]}):
            with self.assertRaises(ValueError):prepare(probe,Web(),{},'wrk-xxxxxxxxxxxxxxxx',report)
        self.assertEqual(report['gateway_read_posts'],1)

    def test_request_guard_rejects_wrong_book_or_write(self):
        probe=PinProbe();probe.target='42'
        probe.guard('pin_progress',BASE+'/book/getProgress?bookId=42',None)
        for url,body in ((BASE+'/book/getProgress?bookId=41',None),(BASE+'/book/getProgress?bookId=42',{})):
            with self.assertRaises(Exception):probe.guard('pin_progress',url,body)


if __name__=='__main__':unittest.main()
