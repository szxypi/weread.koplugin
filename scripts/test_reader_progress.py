"""Reader response boundaries. All accounts and responses here are synthetic."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
from types import SimpleNamespace
import subprocess
import unittest
from unittest.mock import MagicMock, patch

from verify_reader_progress import FRAME, ProgressError, main, outcome, project


class ReaderProgressTests(unittest.TestCase):
    def test_default_never_opens_credentials_network_or_processes(self):
        with patch('verify_reader_progress.SessionStore') as store, patch('verify_reader_progress.WebSourceProbe') as web, \
                patch('verify_reader_progress.subprocess.run') as child, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]), 0)
        store.assert_not_called(); web.assert_not_called(); child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_model_command_requires_explicit_session(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main(['--lua-command', 'synthetic'])

    def test_same_book_and_wrappers_are_preserved(self):
        value=project(dict(data=dict(book=dict(bookId='900001', progress=25.4, chapterUid=2,
                    chapterIdx=1, chapterOffset=0, updateTime=123, summary='synthetic'))), '900001')
        self.assertEqual(value['percent'], 25.4)
        self.assertEqual(value['chapter_uid'], 2)
        self.assertTrue(value['has_chapter_offset'])
        self.assertEqual(value['updated_at'], 123)

    def test_foreign_ancestors_and_contradictory_ids_cannot_hide_a_position(self):
        for value in (dict(bookId='900002', data=dict(progress=25)),
                      dict(bookId='900001', book_id='900002', book=dict(progress=25)),
                      dict(book=dict(bookId=True, progress=25))):
            self.assertEqual(outcome(value, '900001'), dict(ok=False, reason='progress_book_mismatch'))

    def test_ambiguous_candidates_are_not_selected_by_iteration_order(self):
        for values in ([dict(progress=25), dict(progress=26)], [dict(progress=26), dict(progress=25)]):
            self.assertEqual(outcome(dict(data=values), '900001')['reason'], 'progress_ambiguous')

    def test_foreign_siblings_do_not_hide_the_unique_requested_book(self):
        value=project(dict(data=[dict(bookId='900002',progress=90),dict(bookId='900001',progress=25)]),'900001')
        self.assertEqual(value['percent'], 25)

    def test_invalid_percent_is_rejected_without_clamping(self):
        for value in (-1, 101, True, None, 'bad', 'NaN', 'inf', float('nan'), float('inf'), 10**1000, '0x10', '1_0', '١'):
            with self.subTest(value=value), self.assertRaises(ProgressError):
                project(dict(book=dict(progress=value)), '900001')

    def test_invalid_metadata_is_not_defaulted_to_zero(self):
        for key in ('chapterOffset', 'chapterIdx', 'updateTime'):
            for value in (-1, .5, None, True, {}, 'bad', float('inf')):
                with self.subTest(key=key,value=value), self.assertRaises(ProgressError):
                    project(dict(book=dict(progress=25, **{key:value})), '900001')

    def test_aliases_must_agree_and_legacy_numbers_remain_supported(self):
        value=project(dict(book=dict(readingProgress='25.4',chapterPos='0',chapterId='2',update_time='123')),'900001')
        self.assertTrue(value['has_chapter_offset'])
        self.assertEqual(value['chapter_uid'], '2')
        for change in (dict(progress=25, readingProgress=26),dict(progress=25,chapterUid=2,chapterId=3),
                       dict(progress=25,chapterOffset=10,offset=11)):
            with self.assertRaises(ProgressError): project(change,'900001')

    def test_service_failure_cannot_reuse_attached_position(self):
        for fields in (dict(errCode=-1),dict(errcode=False),dict(errCode=None),dict(succ=False)):
            self.assertEqual(outcome(dict(fields,book=dict(progress=25)),'900001')['reason'],'progress_rejected')

    def test_unread_book_has_no_invented_position(self):
        self.assertEqual(outcome(dict(recordReadingTime=0),'900001'),dict(ok=False,reason='progress_not_found'))
        value=project(dict(book=dict(progress=0,chapterUid=0,chapterOffset=0)),'900001')
        self.assertEqual(value['chapter_uid'],0)

    def test_summary_and_traversal_limits(self):
        for summary in ({},'nul\0text','字'*6000):
            with self.assertRaises(ProgressError): project(dict(book=dict(progress=25,summary=summary)),'900001')
        cyclic={};cyclic['data']=cyclic
        for value in (cyclic,dict(data=[{} for _i in range(513)])):
            with self.assertRaises(ProgressError):project(value,'900001')

    def online(self, child_result=None):
        raw=dict(book=dict(bookId='99009900',progress=25.4,chapterUid=2,summary='private-summary-sentinel'))
        web=MagicMock();web.report=dict(stages=[])
        web.request.side_effect=[dict(books=[dict(bookId='99009900')]),raw]
        response=child_result or SimpleNamespace(returncode=0,stdout=FRAME+json.dumps([outcome(raw,'99009900')]).encode())
        with patch('verify_reader_progress.SessionStore') as store, patch('verify_reader_progress.WebSourceProbe',return_value=web), \
                patch('verify_reader_progress.save_refreshed_web_session',return_value=False), \
                patch('verify_reader_progress.subprocess.run',**({'side_effect':response} if isinstance(response,Exception)
                                                               else {'return_value':response})), redirect_stdout(io.StringIO()) as output:
            store.return_value.load.return_value=dict(vid='88008800',cookies=dict(wr_skey='private-cookie-sentinel'))
            code=main(['--saved-session','--sample','1','--lua-command','synthetic'])
        public=output.getvalue()
        for private in ('99009900','88008800','private-summary-sentinel','private-cookie-sentinel'):
            self.assertNotIn(private,public)
        web.close.assert_called_once()
        return code,json.loads(public)

    def test_owner_model_comparison_is_private(self):
        code,public=self.online()
        self.assertEqual(code,0);self.assertTrue(public['lua_projection_matches'])

    def test_invalid_model_and_timeouts_are_sanitized(self):
        for response in (SimpleNamespace(returncode=1,stdout=b'private-cookie-sentinel'),
                         SimpleNamespace(returncode=0,stdout=FRAME+b'[]'),
                         subprocess.TimeoutExpired('private-cookie-sentinel',60)):
            code,public=self.online(response)
            self.assertEqual(code,1);self.assertEqual(public['reason'],'reader_progress_unverified')


if __name__=='__main__':
    unittest.main()
