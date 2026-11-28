import contextlib
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import verify_search_suggestions as subject


class SuggestionVerificationTest(unittest.TestCase):
    def test_projection_is_ordered_bounded_and_deduplicated(self):
        source = dict(keyword=subject.QUERY, records=[dict(word='a'), dict(word='a'), dict(word='b')],
                      list=[dict(word='c')], parts=['anything'])
        self.assertEqual(subject.project(source), ['a', 'b', 'c'])
        source['records'] = [dict(word=str(i)) for i in range(15)]
        self.assertEqual(len(subject.project(source)), 10)

    def test_malformed_responses_are_rejected(self):
        for source in ({}, dict(keyword='other', records=[], list=[], parts=[]),
                       dict(records=[dict(word='bad\nvalue')], list=[], parts=[]),
                       dict(records=[], list={}, parts=[]),
                       dict(records=[], list=[], parts=[], errcode=-1)):
            with self.subTest(source=source), self.assertRaises(ValueError):subject.project(source)

    def test_default_does_not_read_keychain_or_network(self):
        with patch.object(subject, 'SessionStore', side_effect=AssertionError('called')), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(subject.main([]), 0)

    def test_live_probe_reports_only_counts_and_checks_native_result(self):
        payload = dict(keyword=subject.QUERY, records=[dict(word='private suggestion')], list=[], parts=[])
        saved = {'vid': '123'};grant = {'vid': '123', 'accessToken': 'private credential'}
        probe = SimpleNamespace(request=lambda *_args, **_kwargs: payload)
        child = SimpleNamespace(returncode=0, stdout=subject.MARKER+json.dumps(dict(result='PASS', projection_matches=True,
            native_https_matches=True, count=1, requests=1)).encode()+b'\n')
        with patch.object(subject, 'SessionStore', return_value=SimpleNamespace(load=lambda: saved)), \
             patch.object(subject, 'NativeSessionStore', return_value=SimpleNamespace(load=lambda _owner: grant)), \
             patch.object(subject, 'NativeProbe', return_value=probe), \
             patch.object(subject.subprocess, 'run', return_value=child) as run, \
             contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(subject.main(['--saved-session', '--lua-command', 'fake-runtime']), 0)
        output=out.getvalue()
        self.assertNotIn('private suggestion', output);self.assertNotIn('private credential', output)
        self.assertTrue(json.loads(output)['python_lua_ordered_projection_matches'])
        self.assertIn(b'private credential', run.call_args.kwargs['input'])
        self.assertEqual(saved, {});self.assertEqual(grant, {})


if __name__ == '__main__':unittest.main()
