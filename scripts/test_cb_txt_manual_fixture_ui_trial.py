import copy
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cb_cloud_position import observed
from cb_existing_position_intent import Intent
from cb_txt_initial_fixture_plan import plan
from cb_txt_unicode_fixture_plan import CONTEXT, EMOJI
from test_cb_fixture_position import fixture
from test_cb_fixture_position_transport import MemoryBackend
from txt_coordinates import PlainSource
from verify_cb_txt_fixture import MARKER
import verify_cb_txt_manual_fixture_ui_trial as task


class Harness:
    def __init__(self, fail=None):
        book, sample = fixture(); sample.update(source_format='web_txt', source=MARKER + '\nA second synthetic line.', source_raw_sha256='f' * 64)
        self.sample, self.plan = sample, plan(book, sample)
        self.model = PlainSource(sample['source']); self.fail = fail; self.calls = []
        self.current = dict(bookId=book, chapterUid=self.plan['chapter'], chapterIdx=self.plan['index'],
                            chapterOffset=self.plan['first'], progress=17,
                            summary=self.model.excerpt(self.plan['first'])['text'],
                            readingTime=0, recordReadingTime=0, ttsTime=0)
        self.intent = Intent(backend=MemoryBackend()); self.report = dict(position_writes_known=1, position_writes_uncertain=False)
        self.context = dict(sample=sample, plan=self.plan, chapters=sample['chapters'], pair=self.pair,
                            authority=lambda: True, shelf_current=lambda: True,
                            cookies=lambda: {'wr_vid': '900000', 'wr_skey': 'synthetic'}, owner='900000',
                            attempt='a' * 32, source_hash=sample['source_raw_sha256'], target=book,
                            initial_observed=self.project(), attest=lambda: ['first'], command=['first'])
    def pair(self):
        raw = {'book': copy.deepcopy(self.current)}
        return copy.deepcopy(raw), copy.deepcopy(raw)
    def project(self):
        n, w = self.pair()
        return {channel: observed(raw, self.plan['book'], self.sample['chapters'], channel)
                for channel, raw in (('native', n), ('web', w))}
    def runner(self, _command, payload, width, _height, _dpi):
        self.calls.append((payload['armed'], width))
        if self.fail == 'dry' and not payload['armed']: raise ValueError('dry')
        if payload['armed']:
            self.current.update(chapterOffset=payload['next_offset'], summary=payload['expected_summary'])
            if self.fail == 'armed': raise ValueError('unknown')
        return True
    def execute(self):
        return task.manual_trial(self.context, self.report, self.intent, ['manual'], runner=self.runner, attest=lambda: ['manual'])


class TxtManualUiTrialTest(unittest.TestCase):
    def test_two_scoped_native_choices_and_independent_readbacks(self):
        h = Harness()
        self.assertTrue(h.execute())
        self.assertEqual(h.calls, [(False, 600), (True, 600), (False, 1264), (True, 1264)])
        self.assertEqual(h.report['position_writes_known'], 5)
        self.assertFalse(h.report['position_writes_uncertain'])
        self.assertEqual(len(h.report['manual_stages']), 2)
        self.assertEqual(h.current['chapterOffset'], h.plan['first'])

    def test_two_utf16_units_require_one_non_bmp_scalar(self):
        h=Harness();h.sample['source']+='\n'+CONTEXT;h.model=PlainSource(h.sample['source'])
        position=h.sample['source'].index(EMOJI)
        first=h.model.starts[position];h.plan.update(first=first,following=h.model.ends[position])
        h.current.update(chapterOffset=first,summary=h.model.excerpt(first)['text'])
        h.context['initial_observed']=h.project()
        def runner(command,payload,width,height,dpi):
            self.assertIs(payload.get('unicode_boundary'),True)
            return h.runner(command,payload,width,height,dpi)
        self.assertTrue(task.manual_trial(h.context,h.report,h.intent,['manual'],runner=runner,attest=lambda:['manual']))
        self.assertEqual(h.current['chapterOffset'],first)
        invalid=Harness();invalid.plan['following']=invalid.plan['first']+2
        self.assertFalse(invalid.execute());self.assertEqual(invalid.calls,[])
        self.assertIsNone(invalid.intent.backend.load())

    def test_unknown_result_is_not_replayed(self):
        for failure, uncertain in (('dry', False), ('armed', True)):
            h = Harness(failure)
            with self.assertRaises(ValueError): h.execute()
            self.assertEqual(h.report['position_writes_uncertain'], uncertain)
            self.assertEqual(len(h.calls), 1 if failure == 'dry' else 2)
            self.assertIsNotNone(h.intent.backend.load())
            with self.assertRaises(Exception): h.execute()

    def test_changed_count_or_shelf_blocks_first_send(self):
        h = Harness(); h.current['readingTime'] = 1
        with self.assertRaises(ValueError): h.execute()
        self.assertEqual(h.calls, [])
        h = Harness(); h.context['shelf_current'] = lambda: False
        self.assertFalse(h.execute()); self.assertEqual(h.calls, [])

    def test_remote_difference_after_dry_blocks_write(self):
        h = Harness()
        def runner(command, payload, width, height, dpi):
            result = h.runner(command, payload, width, height, dpi)
            if not payload['armed']: h.current['chapterOffset'] += 1
            return result
        with self.assertRaises(ValueError):
            task.manual_trial(h.context, h.report, h.intent, ['manual'], runner=runner, attest=lambda: ['manual'])
        self.assertEqual(h.calls, [(False, 600)]); self.assertFalse(h.report['position_writes_uncertain'])

    def test_runner_accepts_only_exact_result_and_pipes_payload(self):
        payload = dict(armed=False, source='synthetic private content')
        expected = dict(result='DRY_RUN', profile_removed=True, installed_bytes_match=True, native_choice=True,
                        write_blocked=True, writes=0, denied=1, credentials_not_persisted=True)
        with patch.object(task.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(expected).encode())) as child:
            self.assertTrue(task.run_manual(['runner'], payload, 600, 800, 167))
        self.assertNotIn(payload['source'], ' '.join(child.call_args.args[0]))
        self.assertEqual(json.loads(child.call_args.kwargs['input']), payload)
        expected['writes'] = 1
        with patch.object(task.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(expected).encode())):
            with self.assertRaises(ValueError): task.run_manual(['runner'], payload, 600, 800, 167)

    def test_offline_and_consumed_scope_do_not_start_trial(self):
        with patch.object(task, 'SessionStore') as store, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]), 0)
        store.assert_not_called(); self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')
        h = Harness(); h.intent.backend.save(b'consumed')
        result = task.execute({}, None, None, {}, None, None, None, h.intent, [], [],
                              first=lambda *_args, **_kwargs: self.fail('unexpected trial'))
        self.assertEqual(result['account_data_writes_known'], 0)


if __name__ == '__main__': unittest.main()
