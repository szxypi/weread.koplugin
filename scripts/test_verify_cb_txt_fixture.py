import contextlib
import io
import json
import unittest
from unittest.mock import patch

from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend, credentials
from verify_cb_txt_fixture import BODY, MARKER, Journal, Receipt, execute, main, read_source


class TxtFixtureTests(unittest.TestCase):
    def test_offline_does_not_read_keychain(self):
        with patch('verify_cb_txt_fixture.SessionStore', side_effect=AssertionError('opened')):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(main([]), 0)
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def run_case(self, *, guard=lambda: True, read=lambda _: True):
        journal = Journal(Backend()); receipt = Receipt(Backend()); probe = FakeProbe()
        class PriorGroup:
            def read(self): return {'target':'CB_previousfixture'}, 'stable-receipt'
        with patch('verify_cb_txt_fixture.GroupJournal', PriorGroup):
            result = execute(probe, journal, receipt, credentials(), lambda *_: True, read, guard,
                             apply=True, sleep=lambda _: None, now=lambda: 1000)
        return result, probe, journal, receipt

    def test_unique_fixture_import_removal_and_no_replay(self):
        result, probe, journal, receipt = self.run_case()
        self.assertEqual(result['result'], 'TXT_IMPORT_AND_SOURCE_VERIFIED')
        self.assertEqual(tuple(probe.attempts.values()), (1,1,1,1))
        self.assertEqual(journal.read()[0]['phase'], 'restored')
        self.assertIsNotNone(receipt.backend.load())
        with self.assertRaises(ValueError):
            execute(probe, journal, receipt, credentials(), lambda *_: True, lambda _: True, lambda: True, apply=True)
        self.assertEqual(tuple(probe.attempts.values()), (1,1,1,1))

    def test_uncertain_prior_group_retains_new_fixture_and_blocks_replay(self):
        calls=[]
        def guard():
            calls.append(True)
            return len(calls) == 1
        result, probe, journal, receipt = self.run_case(guard=guard)
        self.assertEqual(result['result'], 'UNVERIFIED')
        self.assertEqual(journal.read()[0]['phase'], 'imported')
        self.assertEqual(probe.attempts['cleanup'], 0)
        self.assertIsNotNone(receipt.backend.load())

    def test_fixture_matching_prior_target_is_never_removed(self):
        journal = Journal(Backend()); receipt = Receipt(Backend()); probe = FakeProbe()
        class PriorGroup:
            def read(self): return {'target':'CB_synthetic123'}, 'stable-receipt'
        with patch('verify_cb_txt_fixture.GroupJournal', PriorGroup):
            result = execute(probe, journal, receipt, credentials(), lambda *_: True, lambda _: True,
                             lambda: True, apply=True, sleep=lambda _: None, now=lambda: 1000)
        self.assertEqual(result['result'], 'UNVERIFIED')
        self.assertEqual(journal.read()[0]['phase'], 'imported')
        self.assertEqual(probe.attempts['cleanup'], 0)

    def test_prior_receipt_change_blocks_cleanup(self):
        journal = Journal(Backend()); receipt = Receipt(Backend()); probe = FakeProbe()
        class PriorGroup:
            calls=0
            def read(self):
                self.calls+=1
                return {'target':'CB_previousfixture'}, 'receipt-'+str(self.calls)
        with patch('verify_cb_txt_fixture.GroupJournal', PriorGroup):
            result = execute(probe, journal, receipt, credentials(), lambda *_: True, lambda _: True,
                             lambda: True, apply=True, sleep=lambda _: None, now=lambda: 1000)
        self.assertEqual(result['result'], 'UNVERIFIED')
        self.assertEqual(journal.read()[0]['phase'], 'imported')
        self.assertEqual(probe.attempts['cleanup'], 0)

    def test_read_is_scoped_to_new_book_and_only_reports_summary(self):
        class Web:
            def __init__(self): self.samples=[]; self.allowed=set(); self.closed=False
            def set_cookie(self,*_args): pass
            def verify_account(self): pass
            def inspect(self,target):
                self.asserted = self.allowed == {target}
                self.last_checks = dict(catalog_unchanged=True, versions_unchanged=True, position_unchanged=True)
                return dict(book_id=target,source_format='web_txt',source=BODY.decode())
            def close(self): self.closed=True
        web=Web(); summary={};saved=dict(vid='1',cookies={'wr_vid':'1'})
        with patch('verify_cb_txt_fixture.CbReadingProbe', return_value=web):
            self.assertTrue(read_source(saved, 'CB_synthetic123', summary, sleep=lambda _:None))
        self.assertTrue(web.asserted and web.closed)
        self.assertEqual(summary,dict(source_format='web_txt',fixture_text_found=True,source_baseline_unchanged=True))
        self.assertNotIn(MARKER, json.dumps(summary))
        with self.assertRaises(ValueError): read_source(saved, '42', {}, sleep=lambda _:None)


if __name__ == '__main__': unittest.main()
