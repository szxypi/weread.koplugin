"""Synthetic full CB_ read scope, completeness and privacy checks."""
from contextlib import redirect_stdout, redirect_stderr
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from fetch_weread_epub import make_content_params, reader_url_for
from mock_weread import shards
from test_cb_reading import FIRST, SECOND, HTML, catalog, point, reader
from test_web_source_progress import Opener
import verify_cb_full_reading as cb


def responses(identity=FIRST):
    parts = [part.encode() for part in shards(HTML)]
    return [dict(books=[dict(bookId=identity)]), catalog(identity), point(identity),
            reader(identity, 1), *parts, b'', reader(identity, 2), *parts, b'', catalog(identity), point(identity)]


def ready(values=None):
    progress = []
    web = cb.CbFullReadingProbe(interval=0, progress=progress.append)
    web.vid = '900000'; web.authenticated = True
    web.set_cookie('wr_vid', '900000'); web.set_cookie('wr_skey', 'private-cookie')
    opener = Opener(responses() if values is None else values); web.opener = opener
    return web, opener, progress


class CbFullReadingTests(unittest.TestCase):
    def test_default_never_opens_credentials_network_or_progress_file(self):
        with patch.object(cb, 'SessionStore') as store, patch.object(cb, 'CbFullReadingProbe') as probe, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cb.main([]), 0)
        store.assert_not_called(); probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')
        for args in (['--book-index', '2'], ['--progress-file', '/synthetic/progress.json']):
            with patch.object(cb, 'SessionStore') as store, redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): cb.main(args)
            store.assert_not_called()

    def test_all_chapters_are_read_in_order_without_exporting_source(self):
        web, opener, progress = ready(); value = web.prepare()
        self.assertEqual([row['chapter_uid'] for row in value['full_manifest']], ['1', '2'])
        self.assertEqual(value['chapter_uid'], '2'); self.assertEqual(len(opener.calls), 15)
        self.assertEqual(web.completed, 2); self.assertEqual(web.summary['source_bytes'], 2 * len(HTML.encode()))
        self.assertTrue(all(web.last_checks.values())); self.assertEqual(progress[-1], dict(phase='content', completed=2, total=2))
        for private in (FIRST, 'Private title', 'private-cookie', HTML): self.assertNotIn(private, json.dumps(progress))
        self.assertNotIn('source', value); self.assertNotIn('psvts', value)

    def test_per_chapter_quotas_are_distinct_but_each_address_is_single_use(self):
        web, _opener, _progress = ready([]); web.allowed = {FIRST}; web.book_id = FIRST
        web.allowed_chapters = {'1', '2'}; web.psvts = 'synthetic-session'
        for uid in ('1', '2'):
            web.chapter = uid
            web.guard('reader', reader_url_for(FIRST, uid), None)
            params = make_content_params(FIRST, uid, web.psvts)
            web.guard('e_0', cb.BASE + '/web/book/chapter/e_0', params)
            with self.assertRaises(Exception): web.guard('e_0', cb.BASE + '/web/book/chapter/e_0', params)
        web.chapter = '3'
        with self.assertRaises(cb.CbFullError): web.guard('reader', reader_url_for(FIRST, '3'), None)
        for stage, path in [('write', '/web/book/read'), ('trial', '/web/book/freeTrial'), ('auth', '/web/login/renewal'),
                            ('membership', '/web/shelf/add')]:
            with self.assertRaises(Exception): web.guard(stage, cb.BASE + path, {})

    def test_chapter_failure_stops_instead_of_skipping_or_repeating(self):
        values = responses(); values[8] = reader(SECOND, 2)
        web, opener, _progress = ready(values)
        with self.assertRaises(Exception): web.prepare()
        self.assertEqual(web.completed, 1); self.assertEqual(len(opener.calls), 9); self.assertEqual(web.samples, [])

    def test_catalog_and_position_must_remain_unchanged(self):
        for index in (13, 14):
            values = responses()
            if index == 13: values[index][0]['bookVersion'] += 1
            else: values[index]['book']['chapterOffset'] += 1
            web, opener, _progress = ready(values)
            with self.assertRaises(cb.CbFullError): web.prepare()
            self.assertEqual(web.completed, 2); self.assertEqual(len(opener.calls), 15)
            self.assertFalse(all(web.last_checks.values()))

    def test_catalog_size_is_bound_before_any_reader_or_content_request(self):
        values = responses()
        values[1][0]['updated'] = [dict(chapterUid=n, chapterIdx=n, title='Chapter', wordCount=300) for n in range(1, 130)]
        web, opener, _progress = ready(values)
        with self.assertRaises(cb.CbFullError): web.prepare()
        self.assertEqual(len(opener.calls), 2)
        for interval in (True, -1, 6, float('nan')):
            with self.assertRaises(cb.CbFullError): cb.CbFullReadingProbe(interval=interval)

    def test_total_source_limit_never_discards_an_earlier_chapter(self):
        web, opener, _progress = ready(); web.MAX_TOTAL_BYTES = len(HTML.encode()) + 1
        with self.assertRaises(cb.CbFullError): web.prepare()
        self.assertEqual(web.completed, 1); self.assertEqual(len(web.manifest), 1); self.assertEqual(len(opener.calls), 12)

    def test_explicit_ordinal_selects_one_bound_book_and_rejects_an_absent_ordinal(self):
        values = responses(SECOND); values[0] = dict(books=[dict(bookId=SECOND), dict(bookId=FIRST)])
        web, _opener, _progress = ready(values)
        self.assertEqual(web.prepare(2)['book_id'], SECOND)
        web, opener, _progress = ready([values[0]])
        with self.assertRaises(cb.CbFullError): web.prepare(3)
        self.assertEqual(len(opener.calls), 1)

    def test_no_real_txt_or_other_format_is_silently_declared_epub(self):
        values = responses(); values[4] = dict(bookId=FIRST, chapterUid=1)
        web, opener, _progress = ready(values)
        with self.assertRaises(cb.CbFullError): web.prepare()
        self.assertEqual(len(opener.calls), 5)

    def test_cli_outputs_fixed_status_counts_and_preserves_credentials(self):
        web, _opener, _progress = ready()
        saved = dict(vid='900000', cookies=dict(wr_vid='900000', wr_skey='private-cookie'))
        with patch.object(cb, 'SessionStore') as store, patch.object(cb, 'CbFullReadingProbe', return_value=web), \
             patch.object(web, 'verify_account'), patch.object(cb, 'save_refreshed_web_session', return_value=False), redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value = saved
            self.assertEqual(cb.main(['--saved-session']), 0)
        result = json.loads(out.getvalue()); self.assertEqual(result['result'], 'CB_FULL_CHAPTER_PROTOCOL_VERIFIED')
        self.assertEqual(result['chapters'], 2); self.assertEqual(result['account_data_posts'], 0)
        for private in (FIRST, HTML, 'private-cookie', '900000'): self.assertNotIn(private, out.getvalue())
        self.assertEqual(saved, {}); self.assertEqual(web.manifest, []); store.return_value.delete.assert_not_called()

    def test_native_full_scope_is_explicit_and_keeps_the_ordinary_limit(self):
        from test_owner_reading import stage
        from verify_owner_reading import validate_stage
        value=stage(full=True);value['source_match_reason']='none'
        value['cb_handoff']=dict.fromkeys(('full_to_single','single_to_full','different_files','same_source','position_preserved','cloud_unverified'),True)
        value['requests'][2]=57;value['requests'][4]=57*3
        self.assertEqual(validate_stage(value,'live',full_chapters=57,cb_reading=True,cb_full_book=True),value)
        for options in ({},{'cb_reading':True},{'cb_full_book':True},{'cb_reading':True,'cb_full_book':'true'}):
            with self.assertRaises(ValueError):validate_stage(value,'live',full_chapters=57,**options)
        for chapters in (1,129,True):
            with self.assertRaises(ValueError):validate_stage(value,'live',full_chapters=chapters,cb_reading=True,cb_full_book=True)

    def test_each_handoff_proof_is_required_and_private_additions_are_rejected(self):
        from test_owner_reading import stage
        from verify_owner_reading import validate_stage
        value=stage(full=True);value['source_match_reason']='none'
        fields=('full_to_single','single_to_full','different_files','same_source','position_preserved','cloud_unverified')
        value['cb_handoff']=dict.fromkeys(fields,True)
        for key in fields:
            changed=deepcopy(value);changed['cb_handoff'][key]=False
            with self.assertRaises(ValueError):validate_stage(changed,'live',full_chapters=2,cb_reading=True,cb_full_book=True)
        value['cb_handoff']['private_source']='private'
        with self.assertRaises(ValueError):validate_stage(value,'live',full_chapters=2,cb_reading=True,cb_full_book=True)

    def test_full_summary_does_not_implicitly_raise_the_numeric_book_limit(self):
        from verify_owner_reading import FULL_FLAGS,validate_full_book
        value=dict(chapters=57,source_image_references=0,local_image_references=0,packaged_images=0,body_image_references=0,
                   converted_footnote_images=0,unexplained_image_references=0,source_text_runs_verified=57,unexplained_text_runs=0,
                   **dict.fromkeys(FULL_FLAGS,True))
        self.assertEqual(validate_full_book(value,57,cb_full_book=True),value)
        with self.assertRaises(ValueError):validate_full_book(value,57)

    def test_full_runner_cannot_combine_with_write_or_annotation_modes(self):
        from run_owner_reading_probe import main
        for mode in ('--progress-roundtrip','--progress-preview','--source-upload-preview','--annotations','--annotation-recovery','--cb-reading'):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(['--koreader','/synthetic','--candidate','/synthetic.zip','--cb-full-book',mode])

    def test_full_host_binds_private_manifest_and_independent_position(self):
        from test_owner_reading import stage,frame,COOKIES
        from test_cb_reading import ready as single_ready
        from verify_owner_reading import FULL_FLAGS
        import verify_cb_native_reading as host
        for wrong_images,diagnostic in ((False,False),(True,False),(False,True)):
            web,_opener,_progress=ready()
            after,after_opener=single_ready([point()])
            stages=[stage(full=True),stage('reopen',full=True)]
            handoff=dict.fromkeys(('full_to_single','single_to_full','different_files','same_source','position_preserved','cloud_unverified'),True)
            for row in stages:row.update(shelf_books=1,source_match_reason='none',cb_handoff=handoff.copy(),native_images_decoded=0)
            summary=dict(chapters=2,source_image_references=int(wrong_images),local_image_references=int(wrong_images),packaged_images=int(wrong_images),
                         body_image_references=int(wrong_images),converted_footnote_images=0,unexplained_image_references=0,
                         source_text_runs_verified=2,unexplained_text_runs=0,**dict.fromkeys(FULL_FLAGS,True))
            if wrong_images:
                for row in stages:row['native_images_decoded']=1
            value=dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,stages=stages,runner_error='none',full_book=summary),cookies=COOKIES.copy())
            saved=dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='private-cookie'))
            fresh=deepcopy(saved)
            with patch.object(host,'SessionStore') as store,patch.object(host,'CbFullReadingProbe',return_value=web), \
                 patch.object(host,'CbReadingProbe',return_value=after),patch.object(web,'verify_account'),patch.object(after,'verify_account'), \
                 patch.object(host,'save_refreshed_web_session',return_value=False),patch.object(host.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=frame(value))) as run,redirect_stdout(io.StringIO()) as out:
                store.return_value.load.side_effect=[saved,fresh]
                code=host.main(['--saved-session','--book-index','1','--full-book',
                                *(['--diagnostic-read-pacing'] if diagnostic else []),'--lua-command','synthetic'])
            report=json.loads(out.getvalue())
            self.assertEqual(code,int(wrong_images));self.assertEqual(len(after_opener.calls),0 if wrong_images else 1)
            self.assertEqual(report['account_data_posts'],0);self.assertEqual(saved,{});self.assertEqual(fresh,{})
            payload=json.loads(run.call_args.kwargs['input'])
            self.assertTrue(payload['cb_full_book']);self.assertEqual(len(payload['full_manifest']),2)
            if diagnostic:
                self.assertTrue(payload['diagnostic_read_pacing']);self.assertTrue(report['diagnostic_only'])
                self.assertFalse(report['full_book_verified']);self.assertEqual(report['result'],'CB_PACED_DIAGNOSTIC_VERIFIED')
            else:self.assertNotIn('diagnostic_read_pacing',payload)
            for private in (FIRST,HTML,'private-cookie','900000'):self.assertNotIn(private,out.getvalue())
            store.return_value.delete.assert_not_called()

    def test_diagnostic_pacing_requires_explicit_saved_full_scope_before_opening_credentials(self):
        import verify_cb_native_reading as host
        from run_owner_reading_probe import main
        for args in (['--diagnostic-read-pacing'],['--saved-session','--book-index','1','--diagnostic-read-pacing','--lua-command','synthetic']):
            with patch.object(host,'SessionStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):host.main(args)
            store.assert_not_called()
        for mode in ([],['--cb-reading'],['--progress-roundtrip'],['--annotations']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(['--koreader','/synthetic','--candidate','/synthetic.zip','--diagnostic-read-pacing',*mode])


if __name__ == '__main__':
    unittest.main()
