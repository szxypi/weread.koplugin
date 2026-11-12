#!/usr/bin/env python3
"""Offline scope, authentication and source-comparison checks. No real login."""
from contextlib import redirect_stderr, redirect_stdout
from copy import copy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from fetch_weread_epub import make_content_params, reader_url_for
from mock_weread import shards
from verify_web_source_progress import (BASE, MAX_RESPONSE, PollTimeout, PreflightError,
                                        WebSourceProbe, identifier, main, position, source_check, versions)

BOOK, VID = '900001', '88008800'
CANARY = '绝不能进入报告的合成正文，只在内存核对一次。'
RAW = '<html><body><p>' + CANARY + '</p></body></html>'
OFFSET = RAW.index(CANARY)


class Response(io.BytesIO):
    status = 200


class Opener:
    def __init__(self, rows):
        self.rows, self.calls = list(rows), []

    def open(self, request, timeout):
        self.calls.append((request, timeout))
        row = self.rows.pop(0)
        if isinstance(row, Exception):
            raise row
        if not isinstance(row, bytes):
            row = json.dumps(row, ensure_ascii=False).encode()
        return Response(row)


def remote(**patches):
    return dict(bookId=BOOK, chapterUid=2, chapterOffset=OFFSET, progress=32, **patches)


def inspection_rows(*, later=None, catalog_version=7, later_version=7, reader_book=BOOK, reader_chapter=2):
    progress = remote()
    state = dict(reader=dict(bookInfo=dict(bookId=reader_book, bookVersion=7), psvts='private-signing-context',
                             currentChapter=dict(chapterUid=reader_chapter), progress=dict(book=progress)))
    html = ('<script>window.__INITIAL_STATE__=' + json.dumps(state, ensure_ascii=False) + ';(function(){})();</script>').encode()
    def catalog(version):
        return dict(data=[dict(bookId=BOOK, bookVersion=version, updated=[dict(chapterUid=2, wordCount=200, title='合成章节')])])
    return [dict(book=progress), html, catalog(catalog_version), *(part.encode() for part in shards(RAW)),
            catalog(later_version), dict(book=later or progress)]


def ready(rows=None):
    opener = Opener(inspection_rows() if rows is None else rows)
    probe = WebSourceProbe(opener)
    probe.vid, probe.authenticated = VID, True
    return probe, opener


class WebSourceProgressTests(unittest.TestCase):
    def test_business_failure_keeps_numeric_code_without_private_message(self):
        web=WebSourceProbe(Opener([dict(errcode=-2012,errmsg='private account diagnostic')]))
        web.authenticated=True;web.book_id=BOOK
        with self.assertRaisesRegex(PreflightError,'api_rejected'):
            web.request('progress_before',BASE+'/web/book/getProgress?bookId='+BOOK)
        self.assertEqual(web.report['stages'],[dict(stage='progress_before',status=200,api_code=-2012)])
        self.assertNotIn('private account diagnostic',json.dumps(web.report))
    def test_default_command_never_networks_and_reports_partial_scope(self):
        probe = WebSourceProbe(Opener([]))
        with patch('verify_web_source_progress.WebSourceProbe', return_value=probe), redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]), 0)
        data = json.loads(out.getvalue())
        self.assertEqual(data['network_requests'], 0)
        self.assertEqual(data['stages'], [])
        self.assertEqual(data['result'], 'OFFLINE_ONLY')
        self.assertFalse(data['precision_wire_sync_enabled'])

    def test_explicit_book_and_interactive_flag_are_paired_before_network(self):
        for args in (['--interactive'], ['--book-id', BOOK], ['--interactive', '--book-id', 'bad-cookie-value'],
                     ['--save-session'], ['--saved-session'], ['--clear-saved-session', '--book-id', BOOK],
                     ['--official-parser'], ['--lua-command', 'local-probe']):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit), patch('verify_web_source_progress.WebSourceProbe') as constructor:
                main(args)
            constructor.assert_not_called()

    def test_identifiers_and_positions_reject_missing_foreign_or_inexact_values(self):
        for value in (None, True, 0, '0', -1, 1.5, '1/2', '9'*21):
            with self.assertRaises(PreflightError):
                identifier(value)
        for patch_value in (dict(bookId='other'), dict(chapterUid=False), dict(chapterOffset=True),
                            dict(chapterOffset=-1), dict(chapterOffset=1.5), dict(progress=float('nan')),
                            dict(progress=True), dict(progress=101)):
            data = remote();data.update(patch_value)
            with self.assertRaises(PreflightError):
                position(dict(book=data), BOOK)
        self.assertEqual(position(dict(data=dict(book=remote())), BOOK)['offset'], OFFSET)

    def test_all_account_write_routes_and_other_origins_are_blocked_before_transport(self):
        probe, opener = ready([])
        probe.book_id, probe.chapter = BOOK, '2'
        for url in (BASE+'/web/book/read', BASE+'/web/login/renewal', BASE+'/shelf/add', BASE+'/shelf/remove',
                    BASE+'/web/book/finish', 'https://i.weread.qq.com/book/read',
                    'https://weread.qq.com.evil.test/web/book/chapter/e_0',
                    'https://user@weread.qq.com/web/book/chapter/e_0', 'http://weread.qq.com/web/book/chapter/e_0',
                    BASE+':443/web/book/chapter/e_0', BASE+'/web/book/chapter/e_0#fragment'):
            with self.assertRaisesRegex(PreflightError, '^request_outside_scope$'):
                probe.request('e_0', url, {})
        self.assertEqual(opener.calls, [])

    def test_read_scope_binds_book_chapter_and_exact_read_payload(self):
        probe, opener = ready([])
        probe.book_id, probe.chapter = BOOK, '2'
        params = make_content_params(BOOK, '2', 'private-signing-context')
        for stage, url, body in (
            ('progress_before', BASE+'/web/book/getProgress?bookId=900002', None),
            ('catalog_before', BASE+'/web/book/chapterInfos', dict(bookIds=['900002'])),
            ('reader', reader_url_for(BOOK, '3'), None),
            ('e_0', BASE+'/web/book/chapter/e_0', dict(params, c='other')),
            ('e_0', BASE+'/web/book/chapter/e_0', dict(params, rt=1)),
            ('e_0', BASE+'/web/book/chapter/e_0', dict(params, sc=2)),
        ):
            with self.assertRaises(PreflightError):
                probe.request(stage, url, body)
        self.assertEqual(opener.calls, [])
        probe.guard('e_0', BASE+'/web/book/chapter/e_0', params)

    def test_transport_limits_and_error_messages_do_not_expose_response_or_query(self):
        for row in (b'x'*(MAX_RESPONSE+1), b'not JSON private-token', b'\xff',
                    dict(errcode=-1, errmsg='private-token'),
                    HTTPError(BASE+'?secret=private-token', 302, 'private-token', {}, io.BytesIO(b'private-token')),
                    URLError('private-token')):
            probe = WebSourceProbe(Opener([row]))
            with self.assertRaises(PreflightError) as error:
                probe.request('auth_uid', BASE+'/api/auth/getLoginUid')
            self.assertNotIn('private-token', str(error.exception))
            self.assertNotIn('private-token', json.dumps(probe.report))

    def test_valid_login_handles_timeout_and_otp_without_persisting_credentials(self):
        opener = Opener([b'page', dict(uid='temporary-login'), URLError(TimeoutError()),
                         dict(logicCode='NEED_OTP'), dict(succeed=True, webLoginVid=VID, accessToken='private-token', refreshToken='private-refresh'),
                         dict(vid=int(VID), name='private-name')])
        probe, urls = WebSourceProbe(opener), []
        probe.set_cookie('wr_skey', 'earlier-session')
        other = copy(next(iter(probe.cookies)))
        other.domain, other.domain_specified = 'weread.qq.com', False
        probe.cookies.set_cookie(other)
        probe.login(urls.append, lambda: '1234')
        self.assertTrue(probe.authenticated)
        self.assertEqual(len(urls), 1)
        self.assertIn('private-token', [cookie.value for cookie in probe.cookies])
        self.assertEqual(len([cookie for cookie in probe.cookies if cookie.name == 'wr_skey']), 1)
        self.assertEqual(opener.calls[-1][0].get_header('X-skey'), 'private-token')
        self.assertNotIn('private-token', json.dumps(probe.report))
        self.assertTrue(all(call[0].get_method() == 'GET' for call in opener.calls))
        probe.close()
        self.assertEqual(list(probe.cookies), [])
        self.assertIsNone(probe.vid)

    def test_wrong_login_account_and_bad_otp_never_enable_source_reads(self):
        for account in (dict(vid=900009), dict(name='private-name')):
            probe = WebSourceProbe(Opener([b'page', dict(uid='login'), dict(succeed=True, webLoginVid=VID, accessToken='token'), account]))
            with self.assertRaises(PreflightError):
                probe.login(lambda _url: None)
            self.assertFalse(probe.authenticated)
        probe = WebSourceProbe(Opener([b'page', dict(uid='login'), dict(logicCode='NEED_OTP')]))
        with self.assertRaisesRegex(PreflightError, '^otp_invalid$'):
            probe.login(lambda _url: None, lambda: 'not-four-digits')

    def test_source_requests_require_fresh_owner_login(self):
        probe = WebSourceProbe(Opener([]))
        with self.assertRaisesRegex(PreflightError, '^login_required$'):
            probe.inspect(BOOK)

    def test_full_offline_read_chain_compares_without_reporting_private_fields(self):
        probe, opener = ready()
        data = probe.inspect(BOOK)
        self.assertTrue(data['read_snapshot_consistent'])
        self.assertTrue(data['book_version_field_comparable'])
        self.assertTrue(data['book_version_field_equal'])
        self.assertTrue(data['offset_resolves_to_unique_visible_text'])
        self.assertEqual(data['result'], 'PARTIAL')
        self.assertFalse(data['server_coordinate_semantics_verified'])
        self.assertFalse(data['version_semantics_verified'])
        self.assertEqual([r.get_method() for r, _t in opener.calls], ['GET', 'GET', 'POST', 'POST', 'POST', 'POST', 'POST', 'GET'])
        rendered = json.dumps(data, ensure_ascii=False)
        for value in (BOOK, VID, CANARY, 'private-signing-context', '合成章节', 'chapterOffset'):
            self.assertNotIn(value, rendered)

    def test_cloud_change_during_source_read_is_not_a_verified_comparison(self):
        later=remote();later['chapterOffset'] += 1
        probe, _opener = ready(inspection_rows(later=later))
        data=probe.inspect(BOOK)
        self.assertFalse(data['read_snapshot_consistent'])
        self.assertFalse(data['cloud_position_stable'])

    def test_catalog_change_is_not_treated_as_a_stable_file_version(self):
        probe, _opener = ready(inspection_rows(later_version=8))
        data=probe.inspect(BOOK)
        self.assertFalse(data['read_snapshot_consistent'])
        self.assertFalse(data['catalog_stable'])
        self.assertFalse(data['version_semantics_verified'])
        self.assertTrue(data['version_fields_observed'])

    def test_stable_but_conflicting_reader_and_catalog_book_versions_are_not_consistent(self):
        probe, _opener = ready(inspection_rows(catalog_version=8, later_version=8))
        data=probe.inspect(BOOK)
        self.assertTrue(data['catalog_stable'])
        self.assertTrue(data['book_version_field_comparable'])
        self.assertFalse(data['book_version_field_equal'])
        self.assertFalse(data['read_snapshot_consistent'])
        self.assertFalse(data['version_semantics_verified'])

    def test_reader_book_and_chapter_must_match_selected_cloud_target(self):
        for change in (dict(reader_book='900002'), dict(reader_chapter=3)):
            probe, opener = ready(inspection_rows(**change))
            with self.assertRaisesRegex(PreflightError, '^reader_source_scope_mismatch$'):
                probe.inspect(BOOK)
            self.assertEqual(len(opener.calls), 2)

    def test_offsets_at_zero_whitespace_inside_emoji_or_duplicate_text_are_not_snapped(self):
        for raw, offset in ((RAW, 0), ('<html><body><p>  '+CANARY+'</p></body></html>', 15),
                            ('<html><body><p>😀'+CANARY+'</p></body></html>', 16),
                            ('<html><body><p>'+CANARY*4+'</p></body></html>', 15)):
            self.assertFalse(source_check(raw, dict(offset=offset))['offset_resolves_to_unique_visible_text'])

    def test_observed_versions_are_bounded_and_not_semantic_proof(self):
        self.assertEqual(versions(dict(bookVersion=7, book=dict(version='8'))), {'record.bookVersion': 7, 'book.version': 8})
        self.assertEqual(versions(dict(version=True, bookVersion='private-token', contentVersion=2**64)), {})

    def test_zero_chapter_placeholder_is_not_a_guessed_first_chapter(self):
        data=dict(bookId=BOOK,chapterUid=0,chapterOffset=0,progress=0)
        with self.assertRaisesRegex(PreflightError,'^position_has_no_chapter$'):position(data,BOOK)
        for patch_value in (dict(chapterOffset=1),dict(progress=1),dict(chapterUid=False)):
            value=dict(data,**patch_value)
            with self.assertRaises(PreflightError):position(value,BOOK)

    def test_shelf_selection_skips_unread_and_zero_placeholders(self):
        shelf=dict(books=[dict(bookId='900000'),dict(bookInfo=dict(bookId=BOOK)),dict(bookId='900002')])
        rows=[shelf,dict(bookId='900000',book=dict(chapterUid=0,chapterOffset=0,progress=0)),dict(book=remote())]
        probe,opener=ready(rows)
        self.assertEqual(probe.select_shelf_book(),BOOK)
        self.assertEqual(len(opener.calls),3)
        self.assertEqual(probe.report['selection_attempts'],2)

    def test_shelf_selection_is_bounded_and_deduplicated(self):
        books=[dict(bookId=str(900000+i)) for i in range(12)]
        rows=[dict(books=[*books,*books]),*(dict(book=dict(recordReadingTime=0)) for _i in range(8))]
        probe,opener=ready(rows)
        with self.assertRaisesRegex(PreflightError,'^no_position_in_bounded_shelf_sample$'):probe.select_shelf_book()
        self.assertEqual(len(opener.calls),9)
        self.assertEqual(probe.report['selection_attempts'],8)

    def test_shelf_selection_stops_on_wrong_book_instead_of_trying_another(self):
        probe,opener=ready([dict(books=[dict(bookId=BOOK),dict(bookId='900002')]),dict(book=remote(book_id='unused'))])
        opener.rows[1]={'bookId':'900003','book':remote()}
        with self.assertRaisesRegex(PreflightError,'^position_book_mismatch$'):probe.select_shelf_book()
        self.assertEqual(len(opener.calls),2)

    def test_shelf_scope_requires_login_and_cannot_be_used_for_writes(self):
        probe=WebSourceProbe(Opener([]))
        with self.assertRaises(PreflightError):probe.select_shelf_book()
        for url,body in ((BASE+'/web/shelf/sync',None),(BASE+'/web/shelf/sync',{}),(BASE+'/web/shelf/add',{})):
            with self.assertRaises(PreflightError):probe.request('shelf',url,body)

    def test_report_is_exclusive_and_has_restricted_permissions(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'report.json'
            with redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--output', str(path)]), 0)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            before=path.read_bytes()
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                main(['--output', str(path)])
            self.assertEqual(path.read_bytes(), before)

    def test_qr_and_credentials_are_cleaned_after_interactive_failure(self):
        probe=WebSourceProbe(Opener([b'page', dict(uid='temporary-login'), dict(logicCode='LOGIN_TIMEOUT')]))
        paths=[]
        def save(path):
            paths.append(path);path.write_bytes(b'synthetic QR')
        qr=SimpleNamespace(make=lambda _url: SimpleNamespace(save=save))
        with patch.dict('sys.modules', qrcode=qr), patch('verify_web_source_progress.WebSourceProbe', return_value=probe), \
             patch('verify_web_source_progress.webbrowser.open', return_value=True), redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(['--interactive', '--book-id', BOOK]), 1)
        self.assertEqual(len(paths), 1)
        self.assertFalse(paths[0].exists())
        self.assertEqual(list(probe.cookies), [])
        self.assertNotIn('temporary-login', out.getvalue())
        self.assertNotIn(BOOK, out.getvalue())


if __name__ == '__main__':
    unittest.main()
