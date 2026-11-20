"""Offline tests for isolated EPUB time and version guards."""
from copy import deepcopy
import unittest
from unittest.mock import patch

from personal_upload_trial import hash_value
from secure_shelf_experiment import canonical
from synthetic_upload_epub import TEXT, build
from test_cb_unstarted_time_fixture import Harness
import verify_cb_unstarted_time_fixture as task
import verify_cb_unstarted_epub_time_fixture as epub


class EpubHarness(Harness):
    def __init__(self, mode='success'):
        super().__init__(mode)
        self.sample.update(source_format='web_xhtml', source=TEXT)
    def api_factory(self, grant, target, authority):
        api = super().api_factory(grant, target, authority)
        def bind(payload, summary):
            assert summary == '' and payload['books'][0]['bookId'] == target
            assert payload['books'][0]['bookVersion'] == 42 and api.version == 42
            api.expected = deepcopy(payload)
        api.bind = bind
        return api
    def inspector(self, _saved, _grant, target, _current, summary, *, expected_source):
        assert target == self.target and expected_source == 'b'*64
        summary.update(version=42, web_and_native_positive_match=self.mode != 'wrong_version')
        return True
    def uploader(self, _probe, journal, grant, grant_check, source, *, apply, cleanup_gate, **kwargs):
        assert kwargs['fixture_extension'] == 'epub' and kwargs['fixture_builder']() == build() and grant_check(grant)
        if not apply: return {'result':'READ_ONLY_PREVIEW','phase':'preview'}
        self.uploads += 1
        plan = {'owner':self.owner}; journal.state = dict(phase='imported',target=self.target,attempt='a'*32,plan=plan)
        self.receipt.backend.data = canonical(dict(schema=1,owner=self.owner,attempt='a'*32,target=self.target,plan_sha256=hash_value(plan)))
        assert source(self.target)
        allowed = cleanup_gate(journal,journal.receipt,plan,self.target)
        if allowed: self.cleaned=True; journal.state['phase']='restored'
        return dict(result='EPUB_IMPORT_AND_SOURCE_VERIFIED' if allowed else 'UNVERIFIED',phase='restored' if allowed else 'imported',
                    cos_put_attempts=1,notify_posts=1,cleanup_posts=int(allowed))
    def execute(self, apply=True, after_time=None):
        original = task.run
        def run(*args, **kwargs): return original(*args, **kwargs, fixture='epub')
        with patch.object(task, 'run', side_effect=run): return super().execute(apply, after_time)


class EpubTimeTest(unittest.TestCase):
    def test_success_and_one_shot(self):
        h=EpubHarness(); result=h.execute()
        self.assertEqual(result['result'], 'UNSTARTED_TIME_FIXTURE_VERIFIED', result)
        self.assertTrue(h.cleaned); self.assertEqual(h.sent, 1)
        self.assertEqual(h.execute()['result'], 'UNVERIFIED'); self.assertEqual(h.sent, 1)
    def test_wrong_version_prevents_write(self):
        h=EpubHarness('wrong_version'); result=h.execute()
        self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(h.sent, 0); self.assertTrue(h.cleaned)
    def test_ambiguous_write_retains_fixture(self):
        h=EpubHarness('lost'); result=h.execute()
        self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(h.sent, 1)
        self.assertTrue(result['time_write_uncertain']); self.assertFalse(h.cleaned)
    def test_batch_binds_observed_version(self):
        h=EpubHarness(); grant=h.grant
        payload=epub.positive_batch(grant,h.target,1700007200,1700007202,'guest','config',42,12,34,'+08:00')
        probe=epub.EpubBatchProbe(grant,h.target,lambda:True); probe.version=43
        with self.assertRaises(ValueError): probe.bind(payload, '')
        probe.version=42; probe.bind(payload, '')
        with self.assertRaises(ValueError): probe.bind(payload, '')


if __name__ == '__main__': unittest.main()
