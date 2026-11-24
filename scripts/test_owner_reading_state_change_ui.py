"""Offline boundaries for the one-shot native started-reading UI trial."""
from copy import deepcopy
import json
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from run_owner_reading_state_change_ui import FRAME, validate_input, validate_stage
from test_secure_native_session import credentials
from verify_owner_started_change_preview import decode_runner, preview


def shelf():
    return {'books': [{'bookId': '41', 'title': 'Synthetic', 'finishReading': 0, 'secret': 0}], 'archive': []}


def point():
    return {'book': {'bookId': '41', 'isStartReading': 0, 'startReadingTime': 0,
                     'chapterUid': 0, 'chapterIdx': 0, 'chapterOffset': 0, 'progress': 0, 'summary': '',
                     'readingTime': 0, 'recordReadingTime': 0, 'ttsTime': 0}}


def payload(armed=False):
    return dict(credentials=credentials(), book_id='41', shelf=shelf(), progress=point(), desired=True, armed=armed)


def stage(armed=False):
    return dict(result='PASS', phase='complete', gets=4, posts=int(armed), denied=0, files=4,
                preview_verified=True, credential_audit=True)


def envelope(armed=False):
    return dict(result='PASS', profile_removed=True, installed_bytes_match=True, stage=stage(armed))


class Boundaries(unittest.TestCase):
    def test_input_requires_explicit_arming_exact_fields_and_bounded_identity(self):
        validate_input(payload(), False)
        validate_input(payload(True), True)
        for change in ({'armed': True}, {'desired': 1}, {'book_id': '../41'}, {'shelf': {'books': [], 'archive': []}},
                       {'unexpected': 1}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_input(dict(payload(), **change), False)

    def test_stage_requires_exactly_one_post_when_armed_and_none_in_preview(self):
        for armed in (False, True):
            self.assertEqual(validate_stage(stage(armed), armed), stage(armed))
            for change in ({'posts': 1-int(armed)}, {'denied': 1}, {'preview_verified': False},
                           {'credential_audit': False}, {'gets': True}, {'files': 0}, {'extra': 1}):
                with self.subTest(armed=armed, change=change), self.assertRaises(ValueError):
                    validate_stage(dict(stage(armed), **change), armed)

    def test_only_exact_complete_clean_runner_is_accepted(self):
        raw = FRAME + json.dumps(envelope()).encode()
        self.assertEqual(decode_runner(raw, 0), envelope())
        for altered, code in ((raw, 1), (raw+raw, 0), (FRAME+json.dumps(dict(envelope(), profile_removed=False)).encode(), 0),
                              (FRAME+json.dumps(dict(envelope(), installed_bytes_match=False)).encode(), 0),
                              (FRAME+json.dumps(envelope(True)).encode(), 0)):
            with self.subTest(altered=altered, code=code), self.assertRaises(ValueError):
                decode_runner(altered, code)

    def test_preview_uses_read_only_and_checks_shelf_and_position_after_child(self):
        probe = Mock();probe.shelf.side_effect = [shelf(), shelf()];probe.progress.side_effect = [point(), point()]
        with patch('verify_owner_started_change_preview.subprocess.run', return_value=SimpleNamespace(
                returncode=0, stdout=FRAME+json.dumps(envelope()).encode())) as child:
            report = preview(credentials(), probe, ['isolated-native'], 'ordinary')
        self.assertEqual(report['result'], 'OWNER_NATIVE_PREVIEW_VERIFIED')
        self.assertEqual(report['account_data_writes'], 0)
        self.assertEqual(probe.shelf.call_count, 2);self.assertEqual(probe.progress.call_count, 2)
        self.assertIs(json.loads(child.call_args.kwargs['input'])['armed'], False)

    def test_changed_shelf_or_reading_position_fails_closed(self):
        for changed in ('shelf', 'progress'):
            different_shelf = deepcopy(shelf());different_shelf['books'][0]['secret'] = 1
            different_point = deepcopy(point());different_point['book']['readingTime'] = 3
            probe = Mock();probe.shelf.side_effect = [shelf(), different_shelf if changed == 'shelf' else shelf()]
            probe.progress.side_effect = [point(), different_point if changed == 'progress' else point()]
            with patch('verify_owner_started_change_preview.subprocess.run', return_value=SimpleNamespace(
                    returncode=0, stdout=FRAME+json.dumps(envelope()).encode())):
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    preview(credentials(), probe, ['isolated-native'], 'ordinary')


if __name__ == '__main__':
    unittest.main()
