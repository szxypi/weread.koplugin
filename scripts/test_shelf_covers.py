import contextlib
import io
import json
import subprocess
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from verify_shelf_covers import MAX_BYTES, FRAME, cover_url, download, decode_result, main


def native_result():
    return dict(result='PASS', phase='complete', anonymous_only=True, digest_matches=True,
                thumbnail_bounded=True, source_removed=True, worker_reaped=True, offline_reused=True,
                painted_cover=True, memory_profile=True, image_gets=1, screenshots=0, forbidden_requests=0)


class CoverTests(unittest.TestCase):
    def test_https_and_known_avatar_upgrade(self):
        self.assertEqual(cover_url('https://cdn.example/cover?a=1'), 'https://cdn.example/cover?a=1')
        self.assertEqual(cover_url('http://wx.qlogo.cn/avatar'), 'https://wx.qlogo.cn/avatar')
        for value in (None, '', 'file:///private', 'http://cdn.example/cover', 'https://user@cdn.example/x',
                      'https://cdn.example:443/x', 'https://[invalid/x', 'https://cdn.example/x\ny',
                      'https://cdn.example/x y', 'https://cdn.example/x#fragment', 'x' * 8193):
            self.assertIsNone(cover_url(value))

    def response(self, data, status=200):
        response = Mock(status=status)
        response.read.return_value = data
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        opener = Mock()
        opener.open.return_value = response
        return response, opener

    def test_anonymous_bounded_bitmap_get(self):
        response, opener = self.response(b'\xff\xd8\xff' + b'x' * 20)
        sample, kind = download('https://cdn.example/cover', opener)
        self.assertEqual(kind, 'image/jpeg')
        self.assertEqual(sample['bytes'], 23)
        self.assertEqual(len(sample['sha256']), 64)
        response.read.assert_called_once_with(MAX_BYTES + 1)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), 'GET')
        self.assertIsNone(request.data)
        self.assertFalse(any(key.lower() in ('cookie', 'authorization', 'accesstoken', 'vid') for key in request.headers))

    def test_rejected_bodies_close_response(self):
        for data, status in ((b'<html>verification</html>', 200), (b'\xff\xd8\xff', 200),
                             (b'\xff\xd8\xff' + b'x' * MAX_BYTES, 200), (b'\xff\xd8\xff' + b'x' * 20, 302)):
            response, opener = self.response(data, status)
            with self.assertRaises(ValueError):
                download('https://cdn.example/cover', opener)
            response.__exit__.assert_called_once()

    def test_redirect_http_error_is_closed(self):
        error = HTTPError('https://cdn.example/private', 302, 'private', {}, io.BytesIO(b'private'))
        opener = Mock()
        opener.open.side_effect = error
        with self.assertRaisesRegex(ValueError, '^cover_http_failed$'):
            download('https://cdn.example/cover', opener)
        self.assertTrue(error.closed)

    def test_invalid_url_never_opens_transport(self):
        opener = Mock()
        with self.assertRaises(ValueError):
            download('http://cdn.example/cover', opener)
        opener.open.assert_not_called()

    def test_result_frame_rejects_extra_private_fields_and_incomplete_success(self):
        expected = native_result()
        self.assertEqual(decode_result(b'log' + FRAME + json.dumps(expected).encode()), expected)
        bad = []
        for key, value in (('url', 'private'), ('screenshots', 1), ('memory_profile', False),
                           ('image_gets', True), ('phase', 'loading'), ('phase', []), ('forbidden_requests', 1)):
            record = expected.copy()
            record[key] = value
            bad.append(FRAME + json.dumps(record).encode())
        bad += [b'{}', FRAME + b'{}', FRAME * 2 + b'{}', b'x' * 65537]
        for raw in bad:
            with self.assertRaises(ValueError):
                decode_result(raw)

    def test_offline_does_not_open_keychain(self):
        with patch('verify_shelf_covers.SessionStore', side_effect=AssertionError('Keychain')):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(main([]), 0)
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def run_online(self, child):
        probe = Mock()
        probe.report = dict(stages=[dict(stage='shelf', status=200)])
        probe.request.return_value = dict(books=[dict(cover='https://cdn.example/cover', title='private-title')])
        saved = dict(vid='1', cookies={'wr_skey': 'XXX-synthetic'})
        order = []
        def preserve(*args):
            order.append('save')
            return True
        def launch(*args, **kwargs):
            order.append('child')
            self.assertEqual(set(json.loads(kwargs['input'])), {'url', 'bytes', 'sha256'})
            self.assertTrue(kwargs['capture_output'])
            return child
        with patch('verify_shelf_covers.SessionStore') as store, patch('verify_shelf_covers.WebSourceProbe', return_value=probe), \
                patch('verify_shelf_covers.save_refreshed_web_session', side_effect=preserve), \
                patch('verify_shelf_covers.download', return_value=(dict(url='https://cdn.example/cover', bytes=23, sha256='a' * 64), 'image/jpeg')), \
                patch('verify_shelf_covers.subprocess.run', side_effect=launch), contextlib.redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value = saved
            code = main(['--saved-session', '--lua-command', 'synthetic-probe'])
        probe.verify_account.assert_called_once()
        probe.close.assert_called_once()
        self.assertEqual(order, ['save', 'child'])
        self.assertNotIn('private-title', out.getvalue())
        self.assertNotIn('https://cdn.example', out.getvalue())
        return code, json.loads(out.getvalue())

    def test_session_rotation_saved_before_successful_native_probe(self):
        child = subprocess.CompletedProcess([], 0, FRAME + json.dumps(native_result()).encode(), b'')
        code, report = self.run_online(child)
        self.assertEqual((code, report['result']), (0, 'SHELF_COVER_READ_VERIFIED'))

    def test_failed_native_probe_keeps_rotation_and_suppresses_private_logs(self):
        child = subprocess.CompletedProcess([], 1, b'private-runtime-output', b'private-stderr')
        code, report = self.run_online(child)
        self.assertEqual((code, report['result']), (1, 'UNVERIFIED'))
        self.assertTrue(report['web_cookie_rotation_saved'])
        self.assertNotIn('private-', json.dumps(report))

    def test_repaint_warning_cannot_pass(self):
        child = subprocess.CompletedProcess([], 0, FRAME + json.dumps(native_result()).encode(), b'[WeRead] forceRePaint failed: private')
        code, report = self.run_online(child)
        self.assertEqual((code, report['result']), (1, 'UNVERIFIED'))


if __name__ == '__main__':
    unittest.main()
