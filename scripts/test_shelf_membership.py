import contextlib
import io
import json
import subprocess
import unittest
from unittest.mock import Mock, patch

from verify_shelf_membership import main, project


class MembershipTests(unittest.TestCase):
    def test_positive_members_and_synthetic_absent_control(self):
        sample, expected = project(dict(books=[dict(bookId='42', title='private-title')], archive=[]))
        self.assertEqual(sample['books'], [dict(bookId='42')])
        self.assertEqual(expected, [True, False])
        self.assertNotIn('private-title', json.dumps(sample))

    def test_empty_complete_shelf_has_a_negative_control(self):
        sample, expected = project(dict(books=[], archive=[]))
        self.assertEqual(sample['books'], [])
        self.assertEqual(expected, [False])

    def test_duplicate_members_are_not_a_complete_snapshot(self):
        with self.assertRaises(ValueError):
            project(dict(books=[dict(bookId='42', title='one'), dict(bookId='42', title='two')]))

    def test_absent_control_never_collides_with_members(self):
        sample, expected = project(dict(books=[dict(bookId='membership-absent-control', title='one')]))
        self.assertEqual(expected, [True, False])
        self.assertNotEqual(sample['selected'][0], sample['selected'][1])

    def test_offline_never_opens_credentials(self):
        with patch('verify_shelf_membership.SessionStore', side_effect=AssertionError('Keychain')), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]), 0)
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def online(self, child):
        probe = Mock()
        probe.report = dict(stages=[dict(stage='shelf', status=200)])
        probe.request.return_value = dict(books=[dict(bookId='42', title='private-title')])
        order = []
        def save(*args):
            order.append('save')
            return True
        def run(*args, **kwargs):
            order.append('lua')
            self.assertEqual(set(json.loads(kwargs['input'])), {'books', 'selected'})
            self.assertNotIn('private-title', kwargs['input'].decode())
            return child
        with patch('verify_shelf_membership.SessionStore') as store, patch('verify_shelf_membership.WebSourceProbe', return_value=probe), \
                patch('verify_shelf_membership.save_refreshed_web_session', side_effect=save), \
                patch('verify_shelf_membership.subprocess.run', side_effect=run), contextlib.redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value = dict(vid='1', cookies={'wr_skey': 'XXX-synthetic'})
            code = main(['--saved-session', '--lua-command', 'synthetic'])
        probe.close.assert_called_once()
        self.assertEqual(order, ['save', 'lua'])
        self.assertNotIn('private-title', out.getvalue())
        return code, json.loads(out.getvalue())

    def test_real_projection_uses_strict_booleans(self):
        code, report = self.online(subprocess.CompletedProcess([], 0, b'\nWEREAD_MEMBERSHIP_RESULT=[true,false]', b''))
        self.assertEqual((code, report['result']), (0, 'SHELF_MEMBERSHIP_READ_VERIFIED'))

    def test_failure_preserves_rotation_without_exposing_logs(self):
        code, report = self.online(subprocess.CompletedProcess([], 1, b'private-output', b'private-error'))
        self.assertEqual((code, report['result']), (1, 'UNVERIFIED'))
        self.assertTrue(report['web_cookie_rotation_saved'])
        self.assertNotIn('private-', json.dumps(report))

    def test_integer_projection_is_rejected(self):
        code, report = self.online(subprocess.CompletedProcess([], 0, b'\nWEREAD_MEMBERSHIP_RESULT=[1,0]', b''))
        self.assertEqual((code, report['result']), (1, 'UNVERIFIED'))


if __name__ == '__main__':
    unittest.main()
