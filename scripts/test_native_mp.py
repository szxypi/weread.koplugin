"""Synthetic transport and stores only; no network, Keychain or account writes."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit

import verify_native_mp as mp


CREDENTIALS = dict(vid='88008800', accessToken='synthetic-access',
                   refreshToken='synthetic-refresh', deviceId='synthetic-device')
ACCOUNT = 'MP_WXS_900001'
SHELF = dict(books=[dict(bookId='900002'), dict(bookId=ACCOUNT), dict(bookId='MP_WXS_900003')])


class Response:
    status = 200

    def __init__(self, value, *, raw=False):
        self.body = io.BytesIO(value if raw else json.dumps(value).encode())
        self.closed = False
        self.limits = []

    def read(self, limit):
        self.limits.append(limit)
        return self.body.read(limit)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.closed = True
        self.body.close()


class Opener:
    def __init__(self, *values):
        self.values = list(values)
        self.requests = []
        self.responses = []

    def open(self, request, **_kwargs):
        self.requests.append(request)
        value = self.values.pop(0)
        if isinstance(value, Exception):
            raise value
        response = value if isinstance(value, Response) else Response(value)
        self.responses.append(response)
        return response


def http_error(body, code=499):
    return HTTPError('https://private.invalid/private-url', code, 'private-message',
                     {'private-header': 'private-value'}, io.BytesIO(body))


class NativeMPTests(unittest.TestCase):
    def test_default_never_constructs_network_or_stores(self):
        with patch.object(mp, 'NativeMPProbe') as native, patch.object(mp, 'WebSourceProbe') as web, \
                patch.object(mp, 'SessionStore') as store, patch.object(mp, 'NativeSessionStore') as grant, \
                redirect_stdout(io.StringIO()) as out:
            self.assertEqual(mp.main([]), 0)
        for item in (native, web, store, grant):
            item.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def test_scope_consumes_exact_url_once_and_rejects_writes(self):
        opener = Opener(SHELF)
        probe = mp.NativeMPProbe(opener)
        for stage, url, body in (
                ('mp_shelf', mp.BASE + '/shelf/sync', {}),
                ('mp_shelf', mp.BASE + '/shelf/sync?extra=1', None),
                ('mp_shelf', 'http://i.weread.qq.com/shelf/sync', None),
                ('mp_shelf', 'https://private.invalid/shelf/sync', None),
                ('native_mp_catalog', mp.BASE + '/mp/chapters?bookId=' + ACCOUNT, None),
                ('renew', mp.BASE + '/login', None),
                ('read', mp.BASE + '/mp/read', None)):
            with self.assertRaisesRegex(ValueError, '^native_mp_scope$'):
                probe.request(stage, url, body, CREDENTIALS)
        self.assertEqual(opener.requests, [])
        probe.request('mp_shelf', mp.BASE + '/shelf/sync', credentials=CREDENTIALS)
        with self.assertRaises(ValueError):
            probe.request('mp_shelf', mp.BASE + '/shelf/sync', credentials=CREDENTIALS)
        self.assertEqual(len(opener.requests), 1)

    def test_first_page_and_offset_page_never_mix_synckey(self):
        rows = [dict(reviewId='private-review-' + str(i), title='private-title') for i in range(mp.COUNT)]
        opener = Opener(SHELF, dict(data=rows, synckey=987654321, hasMore=1), dict(data=[]))
        probe = mp.NativeMPProbe(opener)
        result = probe.inspect(CREDENTIALS, 2)
        self.assertTrue(result['shelf_verified'])
        self.assertTrue(result['catalog_response_verified'])
        self.assertEqual(result['shelf_accounts'], 2)
        self.assertEqual([row['returned_rows'] for row in result['pages']], [20, 0])
        queries = [parse_qs(urlsplit(request.full_url).query) for request in opener.requests[1:]]
        self.assertEqual(queries, [dict(bookId=[ACCOUNT], count=['20'], synckey=['0']),
                                   dict(bookId=[ACCOUNT], count=['20'], offset=['20'])])
        for request in opener.requests:
            self.assertEqual(request.get_method(), 'GET')
            self.assertIsNone(request.data)
            self.assertEqual(request.get_header('Accesstoken'), CREDENTIALS['accessToken'])
            self.assertEqual(request.get_header('User-agent'), mp.HEADERS['User-Agent'])
            self.assertIsNone(request.get_header('Cookie'))
            self.assertIsNone(request.get_header('Authorization'))
        self.assertTrue(all(response.closed for response in opener.responses))
        with self.assertRaises(ValueError):
            probe.inspect(CREDENTIALS, 2)
        self.assertEqual(len(opener.requests), 3)

    def test_empty_or_short_page_stops_at_one_catalog_request(self):
        for rows in ([], [dict(reviewId='private-review')]):
            with self.subTest(rows=len(rows)):
                opener = Opener(SHELF, dict(data=rows, hasMore=1, synckey=999))
                result = mp.NativeMPProbe(opener).inspect(CREDENTIALS, 2)
                self.assertEqual(len(result['pages']), 1)
                self.assertEqual(len(opener.requests), 2)

    def test_page_budget_rejected_before_network(self):
        for pages in (0, 3, True, 1.0, '2'):
            opener = Opener()
            with self.assertRaises(ValueError):
                mp.NativeMPProbe(opener).inspect(CREDENTIALS, pages)
            self.assertFalse(opener.requests)

    def test_invalid_or_missing_subscriptions_stops_before_catalog(self):
        for shelf in ({}, dict(books={}), dict(books=[{}] * 5001),
                      dict(books=[dict(bookId='MP_WXS_0'), dict(bookId='MP_WXS_1&extra=1')])):
            opener = Opener(shelf)
            with self.assertRaises(ValueError):
                mp.NativeMPProbe(opener).inspect(CREDENTIALS, 2)
            self.assertEqual(len(opener.requests), 1)

    def test_http_challenge_reports_code_without_body_or_retry(self):
        exc = http_error(b'{"errCode":-2041,"errMsg":"private-message","private-key":"private-value"}')
        opener = Opener(SHELF, exc)
        probe = mp.NativeMPProbe(opener)
        with self.assertRaisesRegex(mp.ProbeError, '^native_mp_http_rejected$'):
            probe.inspect(CREDENTIALS, 2)
        stage = probe.report['stages'][-1]
        self.assertEqual(stage['status'], 499)
        self.assertEqual(stage['error_code'], -2041)
        self.assertTrue(stage['error_response_bounded'])
        self.assertTrue(exc.fp.closed)
        self.assertEqual(mp.failure_reason(probe.report['stages']), 'native_mp_human_verification_required')
        self.assertEqual(len(opener.requests), 2)
        public = json.dumps([probe.report, probe.summary])
        self.assertNotIn('private-', public)
        self.assertNotIn(ACCOUNT, public)
        self.assertTrue(probe.summary['shelf_verified'])
        self.assertFalse(probe.summary['catalog_response_verified'])

    def test_200_business_challenge_stops_without_reauthentication(self):
        opener = Opener(SHELF, dict(errcode=-2041, errmsg='private-message'))
        probe = mp.NativeMPProbe(opener)
        with self.assertRaises(mp.ProbeError):
            probe.inspect(CREDENTIALS, 2)
        self.assertEqual(probe.report['stages'][-1], dict(stage='native_mp_catalog', status=200, error_code=-2041))
        self.assertEqual(len(opener.requests), 2)

    def test_authentication_and_rate_limits_have_distinct_fixed_reasons(self):
        for code, status, reason in ((-2012, 200, 'authentication_rejected'),
                                     (None, 401, 'authentication_rejected'),
                                     (-2014, 200, 'read_limited'), (None, 429, 'read_limited')):
            error = http_error(b'private-message', status) if status != 200 else dict(errCode=code)
            opener = Opener(error)
            probe = mp.NativeMPProbe(opener)
            with self.assertRaises(mp.ProbeError):
                probe.inspect(CREDENTIALS, 2)
            self.assertEqual(mp.failure_reason(probe.report['stages']), 'native_mp_' + reason)
            self.assertEqual(len(opener.requests), 1)
            self.assertFalse(probe.summary['shelf_verified'])

    def test_error_code_rejects_private_values_booleans_and_conflicts(self):
        for value in (dict(errCode=True), dict(errCode='private-message'), dict(errCode=None),
                      dict(errCode=2**100), dict(errCode=-2041, errcode=0)):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    mp.error_code(value)
                probe = mp.NativeMPProbe(Opener(value))
                with self.assertRaises(mp.ProbeError):
                    probe.inspect(CREDENTIALS, 1)
                self.assertNotIn('error_code', probe.report['stages'][0])
                exc = http_error(json.dumps(value).encode())
                opener = mp.ErrorObservation(Opener(exc))
                with self.assertRaises(HTTPError):
                    opener.open(Mock())
                self.assertNotIn('error_code', opener.last)
                self.assertTrue(exc.fp.closed)
        self.assertEqual(mp.error_code(dict(errCode=-2041, errcode=-2041)), -2041)

    def test_error_body_is_bounded_and_success_clears_previous_observation(self):
        for raw in (b'x' * (mp.ERROR_LIMIT + 1), b'private-message', b'[]', b'\xff'):
            exc = http_error(raw)
            opener = mp.ErrorObservation(Opener(exc, {}))
            with self.assertRaises(HTTPError):
                opener.open(Mock())
            self.assertNotIn('error_code', opener.last)
            self.assertLessEqual(opener.last['error_response_bytes'], mp.ERROR_LIMIT + 1)
            self.assertTrue(exc.fp.closed)
            with opener.open(Mock()):
                self.assertIsNone(opener.last)

    def test_success_body_limit_and_bad_json_close_response(self):
        for raw in (b'x' * (mp.RESPONSE_LIMIT + 1), b'private-message', b'[]', b'\xff'):
            response = Response(raw, raw=True)
            probe = mp.NativeMPProbe(Opener(response))
            with self.assertRaises(mp.ProbeError):
                probe.inspect(CREDENTIALS, 1)
            self.assertEqual(response.limits, [mp.RESPONSE_LIMIT + 1])
            self.assertTrue(response.closed)
            self.assertNotIn('private-', json.dumps(probe.report))

    def test_invalid_catalog_never_marks_response_verified(self):
        for value in ({}, dict(data={}), dict(data=[None]), dict(data=[{}] * (mp.COUNT + 1))):
            probe = mp.NativeMPProbe(Opener(SHELF, value))
            with self.assertRaises(ValueError):
                probe.inspect(CREDENTIALS, 2)
            self.assertFalse(probe.summary['catalog_response_verified'])
            self.assertEqual(probe.summary['pages'], [])

    def test_public_shape_only_contains_static_field_names_and_types(self):
        value = dict(data=[dict(reviewId='private-review', title='private-title', mpInfo={'private': 'body'},
                                **{'private-key': 'private-value'})], **{'private-root': 'private-value'})
        probe = mp.NativeMPProbe(Opener(SHELF, value))
        result = probe.inspect(CREDENTIALS, 1)
        public = json.dumps([result, probe.report])
        self.assertNotIn('private', public)
        self.assertNotIn(ACCOUNT, public)
        self.assertNotIn(CREDENTIALS['vid'], public)
        self.assertEqual(result['pages'][0]['row_fields'], dict(mpInfo=['dict'], reviewId=['str'], title=['str']))

    def test_failed_body_read_still_closes_http_error_and_stops(self):
        class BrokenBody(io.BytesIO):
            def read(self, *_args):
                raise OSError('private-body-read-error')
        body = BrokenBody()
        exc = HTTPError('https://private.invalid', 499, 'private-message', {}, body)
        opener = Opener(SHELF, exc)
        probe = mp.NativeMPProbe(opener)
        with self.assertRaisesRegex(mp.ProbeError, '^native_mp_response_unavailable$'):
            probe.inspect(CREDENTIALS, 2)
        self.assertTrue(body.closed)
        self.assertEqual(len(opener.requests), 2)


class NativeMPMainTests(unittest.TestCase):
    def run_main(self, *responses, web_error=False):
        probe = mp.NativeMPProbe(Opener(*responses))
        web = Mock()
        web.report = dict(stages=[dict(stage='web_account', status=200)])
        if web_error:
            web.verify_account.side_effect = ValueError('private-owner-error')
        saved = dict(vid=CREDENTIALS['vid'], cookies={'wr_vid': CREDENTIALS['vid'], 'wr_skey': 'synthetic-cookie'})
        credentials = CREDENTIALS.copy()
        store, native = Mock(), Mock()
        store.load.return_value, native.load.return_value = saved, credentials
        with patch.object(mp, 'NativeMPProbe', return_value=probe), \
                patch.object(mp, 'WebSourceProbe', return_value=web), \
                patch.object(mp, 'SessionStore', return_value=store), \
                patch.object(mp, 'NativeSessionStore', return_value=native) as native_factory, \
                patch.object(mp, 'save_refreshed_web_session', return_value=True) as rotate, \
                redirect_stdout(io.StringIO()) as out:
            exit_code = mp.main(['--saved-session', '--pages', '2'])
        self.assertEqual(saved, {})
        web.close.assert_called_once_with()
        store.delete.assert_not_called()
        native.delete.assert_not_called()
        native.begin_renewal.assert_not_called()
        native.save.assert_not_called()
        self.assertNotIn('private-', out.getvalue())
        self.assertNotIn(CREDENTIALS['vid'], out.getvalue())
        if not web_error:
            self.assertEqual(credentials, {})
            native.load.assert_called_once_with(CREDENTIALS['vid'])
            rotate.assert_called_once()
        else:
            native_factory.assert_not_called()
            rotate.assert_not_called()
        return exit_code, json.loads(out.getvalue()), probe

    def test_owner_verified_before_native_store_or_request(self):
        code, report, probe = self.run_main(web_error=True)
        self.assertEqual(code, 1)
        self.assertEqual(report['result'], 'UNVERIFIED')
        self.assertFalse(probe.report['stages'])

    def test_native_failure_keeps_verified_web_rotation_and_grants(self):
        code, report, probe = self.run_main(SHELF, http_error(b'{"errCode":-2041}'))
        self.assertEqual(code, 1)
        self.assertTrue(report['web_cookie_rotation_saved'])
        self.assertEqual(report['reason'], 'native_mp_human_verification_required')
        self.assertTrue(report['shelf_verified'])
        self.assertFalse(report['catalog_response_verified'])
        self.assertEqual(len(probe.opener.opener.requests), 2)
        self.assertEqual(report['account_data_writes'], 0)
        self.assertEqual(report['authentication_posts'], 0)

    def test_success_only_claims_sampled_response_not_complete_catalog(self):
        code, report, _probe = self.run_main(SHELF, dict(data=[]))
        self.assertEqual(code, 0)
        self.assertEqual(report['result'], 'NATIVE_MP_CATALOG_RESPONSE_VERIFIED')
        self.assertTrue(report['owner_verified'])
        self.assertTrue(report['catalog_response_verified'])
        self.assertEqual(report['sampled_accounts'], 1)
        self.assertNotIn('complete', report)


if __name__ == '__main__':
    unittest.main()
