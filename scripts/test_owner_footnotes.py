"""Offline privacy and scope checks. No real grants or book content."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch
import verify_owner_footnotes as probe
import run_owner_footnote_probe as native
import tempfile


class FootnoteProbeTests(unittest.TestCase):
    def test_default_is_offline_and_does_not_read_credentials(self):
        with patch.object(probe,'SessionStore') as store,patch.object(probe,'Probe') as web,patch.object(probe.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(probe.main([]),0)
        store.assert_not_called();web.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_lua_requires_explicit_saved_session(self):
        with redirect_stdout(io.StringIO()),patch('sys.stderr',io.StringIO()):
            with self.assertRaises(SystemExit):probe.main(['--lua-command','anything'])

    def test_catalog_projection_omits_private_unneeded_fields(self):
        value=probe.projected_catalog([dict(chapterUid=1,files=['Text/a.xhtml'],title='synthetic secret',extra='never emit')])
        self.assertEqual(value,[dict(chapterUid=1,files=['Text/a.xhtml'])])

    def test_duplicate_catalog_uid_is_rejected(self):
        with self.assertRaises(probe.PreflightError):probe.projected_catalog([dict(chapterUid=1),dict(chapterUid='1')])

    def test_bad_file_metadata_is_rejected(self):
        for value in ('not-list',[False],['x'*8193]):
            with self.subTest(value=type(value).__name__),self.assertRaises(probe.PreflightError):probe.projected_catalog([dict(chapterUid=1,files=value)])

    def test_shelf_deduplicates_and_bounds_ordinary_epub_only(self):
        shelf=dict(books=[dict(bookId='1'),dict(book=dict(bookId='1')),dict(bookId='2',format='pdf'),dict(bookId='3',type=1),dict(bookId='4'),dict(bookId='5')])
        self.assertEqual(probe.candidates(shelf,2),['1','4'])

    def test_note_rich_titles_are_prioritized_without_emitting_titles(self):
        self.assertEqual(probe.candidates(dict(books=[dict(bookId='1',title='普通合成书'),dict(bookId='2',title='注释合成书')]),1),['2'])

    def test_selects_current_note_and_readable_chapters_with_limit(self):
        chapters=[dict(chapterUid=1,title='封面',wordCount=1),dict(chapterUid=2,title='正文',wordCount=40),dict(chapterUid=3,title='注释',wordCount=40),dict(chapterUid=4,title='最近',wordCount=40)]
        self.assertEqual([row['chapterUid'] for row in probe.select_chapters(chapters,dict(chapter='4'),2)],[4,3])

    def test_book_offset_applies_after_deduplication_and_priority(self):
        shelf=dict(books=[dict(bookId='1'),dict(bookId='1'),dict(bookId='2',title='注释合成书'),dict(bookId='3'),dict(bookId='4',format='pdf')])
        self.assertEqual(probe.candidates(shelf,1),['2'])
        self.assertEqual(probe.candidates(shelf,2,1),['1','3'])
        self.assertEqual(probe.candidates(shelf,8,3),[])

    def test_successive_book_windows_do_not_repeat_candidates(self):
        shelf=dict(books=[dict(bookId=str(value)) for value in range(1,22)])
        windows=[probe.candidates(shelf,8,start) for start in (0,8,16)]
        self.assertEqual([len(values) for values in windows],[8,8,5])
        self.assertEqual(len(set(sum(windows,[]))),21)

    def test_chapter_offset_applies_to_current_notes_then_rest(self):
        chapters=[dict(chapterUid=1,title='封面',wordCount=1),dict(chapterUid=2,title='正文',wordCount=40),dict(chapterUid=3,title='注释',wordCount=40),dict(chapterUid=4,title='最近',wordCount=40)]
        self.assertEqual([v['chapterUid'] for v in probe.select_chapters(chapters,dict(chapter='4'),2,1)],[3,2])
        self.assertEqual(probe.select_chapters(chapters,dict(chapter='4'),4,3),[])

    def test_invalid_selection_bounds_fail_before_any_book_request(self):
        for maximum,offset in ((True,0),(0,0),(5,0),(1,True),(1,-1),(1,10000)):
            web=probe.Probe()
            with patch.object(web,'request') as request,self.assertRaises(probe.PreflightError):web.inspect_book('1',maximum,offset)
            request.assert_not_called()
        for maximum,offset in ((0,0),(9,0),(1,-1),(1,5000),(1,False)):
            with self.assertRaises(probe.PreflightError):probe.candidates(dict(books=[]),maximum,offset)

    def test_offset_cli_rejects_invalid_values_without_private_access(self):
        for flag,value in (('--book-offset','5000'),('--chapter-offset','10000'),('--book-offset','-1'),('--chapter-offset','1.5')):
            with patch.object(probe,'SessionStore') as store,patch('sys.stderr',io.StringIO()) as errors,self.assertRaises(SystemExit):probe.main([flag,value])
            store.assert_not_called();self.assertLess(len(errors.getvalue()),1500)

    def test_offset_offline_report_contains_only_selection_numbers(self):
        with patch.object(probe,'SessionStore') as store,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(probe.main(['--book-offset','8','--chapter-offset','4']),0)
        store.assert_not_called();report=json.loads(output.getvalue());self.assertEqual((report['book_offset'],report['chapter_offset']),(8,4))

    def test_saved_cli_forwards_offsets_and_empty_window_does_not_inspect(self):
        for offset,expected in ((8,'9'),(10,None)):
            with patch.object(probe.resource,'setrlimit'),patch.object(probe,'SessionStore') as store,patch.object(probe,'Probe') as factory,patch.object(probe,'save_refreshed_web_session',return_value=False),redirect_stdout(io.StringIO()) as output:
                store.return_value.load.return_value=dict(vid='900000',cookies={})
                web=factory.return_value;web.authenticated=True;web.calls=0;web.report={'stages':[]}
                web.request.return_value=dict(books=[dict(bookId=str(i)) for i in range(1,10)])
                web.inspect_book.return_value=({},dict(chapters=4))
                code=probe.main(['--saved-session','--max-books','1','--book-offset',str(offset),'--chapter-offset','7'])
            report=json.loads(output.getvalue())
            if expected:
                web.inspect_book.assert_called_once_with(expected,4,7)
                self.assertEqual((code,report['result'],report['books']),(0,'PASS',1))
            else:
                web.inspect_book.assert_not_called();self.assertEqual((code,report['result'],report['books']),(1,'NO_SAMPLE',0))

    def test_transport_failure_reports_only_fixed_reason_and_known_stage(self):
        for stage in ('reader','synthetic-private-stage'):
            with patch.object(probe.resource,'setrlimit'),patch.object(probe,'SessionStore') as store,patch.object(probe,'Probe') as factory,patch.object(probe,'save_refreshed_web_session',return_value=False),redirect_stdout(io.StringIO()) as output:
                store.return_value.load.return_value=dict(vid='900000',cookies={})
                web=factory.return_value;web.authenticated=True;web.calls=1;web.report={'stages':[dict(stage=stage)]}
                web.request.side_effect=probe.PreflightError('request_timed_out')
                self.assertEqual(probe.main(['--saved-session']),1)
            report=json.loads(output.getvalue());self.assertEqual(report['reason'],'request_timed_out')
            self.assertEqual(report.get('failure_stage'),'reader' if stage=='reader' else None)
            self.assertNotIn('synthetic-private',output.getvalue())

    def test_html_scan_counts_entities_comments_and_media(self):
        scan=probe.Scan();scan.feed('<p id="中"><a href="a.xhtml#&#20013;" epub:type="noteref">[1]</a></p><!-- <a href="bad"> --><svg/><math/><table></table>')
        self.assertEqual(scan.links,['a.xhtml#中']);self.assertEqual((scan.noterefs,scan.media),(1,3))
        scan.feed('<img class=qqreader-footnote alt=synthetic/>');self.assertEqual((scan.image_notes,scan.note_markers),(1,1))

    def result(self):
        value={key:0 for key in probe.COUNTS};value.update(result='PASS',catalog_chapters=2,sampled_chapters=1,links=1,cross_chapter_plans=1)
        return value,dict(chapters=[{},{}],samples=[{}])

    def test_lua_frame_has_only_counts(self):
        value,payload=self.result();raw=probe.FRAME+json.dumps(value).encode()
        self.assertEqual(probe.decode_result(raw,payload),value)

    def test_lua_frame_rejects_private_or_unknown_fields(self):
        value,payload=self.result();value['book_id']='900001'
        with self.assertRaises(probe.PreflightError):probe.decode_result(probe.FRAME+json.dumps(value).encode(),payload)

    def test_lua_frame_rejects_wrong_counts_and_boolean_numbers(self):
        for change in (dict(sampled_chapters=2),dict(links=2),dict(links=True),dict(anchors=-1)):
            value,payload=self.result();value.update(change)
            with self.subTest(change=change),self.assertRaises(probe.PreflightError):probe.decode_result(probe.FRAME+json.dumps(value).encode(),payload)

    def test_lua_frame_rejects_duplicate_or_oversized_output(self):
        value,payload=self.result()
        for raw in (probe.FRAME*2+json.dumps(value).encode(),b'x'*65537,b'not a frame'):
            with self.assertRaises(probe.PreflightError):probe.decode_result(raw,payload)

    def test_network_scope_rejects_account_writes_renewal_and_redirects(self):
        web=probe.Probe();web.vid='900000';web.authenticated=True;web.book_id='900001';web.chapter='1'
        for url in (probe.BASE+'/web/book/read',probe.BASE+'/web/login/renew',probe.BASE+'/web/shelf/add','https://example.org/web/book/chapterInfos'):
            with self.subTest(url=url),self.assertRaises(probe.PreflightError):web.guard('catalog_before',url,{'bookIds':['900001']})

    def test_request_budget_never_dispatches_after_limit(self):
        web=probe.Probe();web.calls=192
        with patch.object(probe.WebSourceProbe,'request') as request,self.assertRaises(probe.PreflightError):web.request('account','ignored')
        request.assert_not_called()

    def test_unexpected_private_exception_is_not_printed(self):
        with patch.object(probe.resource,'setrlimit'),patch.object(probe,'SessionStore',side_effect=RuntimeError('synthetic-private-body')),redirect_stdout(io.StringIO()) as output:
            self.assertEqual(probe.main(['--saved-session']),1)
        self.assertNotIn('synthetic-private-body',output.getvalue());self.assertEqual(json.loads(output.getvalue())['reason'],'probe_failed')


class NativeNoteTests(unittest.TestCase):
    def payload(self):
        return dict(chapters=[dict(chapterUid=1,files=[])],samples=[dict(uid='1',html='<p>synthetic private body</p>',expected_notes=['synthetic note'])])

    def value(self):
        value={key:0 for key in probe.COUNTS};value.update(result='PASS',catalog_chapters=1,sampled_chapters=1)
        return value

    def test_private_payload_rejects_credentials_and_unknown_metadata(self):
        value=self.payload();self.assertEqual(native.validate_payload(value),value)
        for key in ('cookies','vid','api_key','extra'):
            value=self.payload();value[key]='synthetic'
            with self.subTest(key=key),self.assertRaises(ValueError):native.validate_payload(value)

    def test_private_payload_rejects_foreign_duplicate_and_untyped_notes(self):
        for kind in ('foreign','duplicate','note_type','sample_extra'):
            value=self.payload()
            if kind=='foreign':value['samples'][0]['uid']='2'
            elif kind=='duplicate':value['samples']*=2
            elif kind=='note_type':value['samples'][0]['expected_notes']=[False]
            else:value['samples'][0]['cookies']='synthetic'
            with self.subTest(kind=kind),self.assertRaises(ValueError):native.validate_payload(value)

    def test_native_html_entities_and_unicode_spaces_preserve_visible_note(self):
        payload=self.payload();payload['samples'][0]['expected_notes']=['甲 乙 & 丙']
        value=self.value();value['_native_private']=[dict(sample_index=1,note_index=1,html='<head><style>ignore</style></head><p>甲&nbsp;乙 &amp; 丙</p>')]
        result=native.verify_native_text(value,payload)
        self.assertNotIn('_native_private',result);self.assertEqual(result['native_error_code'],0)
        self.assertEqual((result['native_actual_nbsp'],result['native_whitespace_normalizations']),(1,1))

    def test_native_discretionary_hyphen_is_formatting_but_visible_hyphen_is_content(self):
        for html,code in [('<p>synthetic no\xadte</p>',0),('<p>synthetic no-te</p>',5)]:
            value=self.value();value['_native_private']=[dict(sample_index=1,note_index=1,html=html)]
            self.assertEqual(native.verify_native_text(value,self.payload())['native_error_code'],code)

    def test_native_missing_text_remains_a_failure_and_never_returns_body(self):
        value=self.value();value['_native_private']=[dict(sample_index=1,note_index=1,html='<p>different synthetic private body</p>')]
        result=native.verify_native_text(value,self.payload())
        self.assertEqual(result['native_error_code'],5);self.assertNotIn('synthetic',json.dumps(result))

    def test_native_pair_scope_and_duplicates_are_rejected(self):
        for pairs in ([dict(sample_index=2,note_index=1,html='x')],[dict(sample_index=1,note_index=2,html='x')],
                      [dict(sample_index=1,note_index=1,html='x')]*2):
            value=self.value();value['_native_private']=pairs
            with self.subTest(pairs=len(pairs)),self.assertRaises(ValueError):native.verify_native_text(value,self.payload())

    def test_empty_lua_array_only_allowed_when_no_notes_expected(self):
        value=self.value();value['_native_private']={}
        payload=self.payload();payload['samples'][0]['expected_notes']=[]
        self.assertEqual(native.verify_native_text(value,payload)['native_error_code'],0)
        value=self.value();value['_native_private']={}
        with self.assertRaises(ValueError):native.verify_native_text(value,self.payload())

    def test_missing_native_popup_is_not_counted_as_success(self):
        value=self.value();value['_native_private']=[]
        self.assertEqual(native.verify_native_text(value,self.payload())['native_error_code'],96)

    def test_native_runner_exception_cleans_profile_and_hides_diagnostics(self):
        original=tempfile.TemporaryDirectory
        def temporary(*args,**kwargs):return original(prefix='synthetic-note-test-')
        with patch.object(native.sys,'platform','linux'),patch.object(native.Path,'read_text',return_value='none /dev/shm tmpfs rw 0 0'), \
                patch.object(native.tempfile,'TemporaryDirectory',side_effect=temporary),patch.object(native,'extract_candidate'), \
                patch.object(native,'check_installed'),patch.object(native,'run_child',side_effect=RuntimeError('synthetic private diagnostic')), \
                patch.object(native.sys,'stdin',io.TextIOWrapper(io.BytesIO(json.dumps(self.payload()).encode()))),redirect_stdout(io.StringIO()) as output:
            self.assertEqual(native.main(['--koreader','/runtime','--candidate','/candidate.zip']),1)
        report=json.loads(output.getvalue());self.assertTrue(report['profile_removed'])
        self.assertNotIn('synthetic private',output.getvalue())


if __name__=='__main__':unittest.main()
