"""TXT cloud-point read planning, exact boundaries and no upload authority."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch
import txt_cloud_position as model
import verify_txt_cloud_position as task

RAW='\ufeff标题\r\n'+'这是独立的合成纯文本，保留字面<tag>与&amp;和表情😀。\r\n'+'后续合成文字必须能够唯一定位。'


def fixture(offset=None):
    offset=len(RAW[:RAW.index('独立')].encode('utf-16-le'))//2 if offset is None else offset
    progress=dict(book=dict(bookId='41',chapterUid=2,chapterIdx=3,chapterOffset=offset,progress=12,summary='独立的合成'))
    context=dict(book_id='41',psvts='synthetic',progress=deepcopy(progress))
    return progress,context,[dict(chapterUid=2,chapterIdx=3)]


class TxtCloudTests(unittest.TestCase):
    def test_exact_original_width_and_restorable_adjacent_point(self):
        progress,context,chapters=fixture();value=model.prepare(RAW,progress,context,chapters,'41')
        self.assertTrue(value['source_summary_matches']);self.assertTrue(value['original_summary_preserved'])
        self.assertEqual(value['target']['chapter_offset'],value['baseline']['chapter_offset']+1)
        self.assertEqual(value['basis'],'raw_txt_utf16');self.assertFalse(value['upload_verified']);self.assertFalse(value['cloud_coordinate_semantics_verified'])
    def test_literal_markup_is_not_stripped_or_entity_decoded(self):
        offset=len(RAW[:RAW.index('<tag>')].encode('utf-16-le'))//2
        progress,context,chapters=fixture(offset);value=model.prepare(RAW,progress,context,chapters,'41')
        self.assertEqual(value['baseline']['summary'],'独立的合成')
        self.assertTrue(value['target']['summary'].startswith('tag>与&amp;'))
        self.assertFalse(value['source_summary_matches']);self.assertTrue(value['original_summary_preserved'])
    def test_surrogate_middle_and_whitespace_are_not_source_points(self):
        for co in (len(RAW[:RAW.index('😀')].encode('utf-16-le'))//2+1,3,-1):
            progress,context,chapters=fixture(co)
            with self.subTest(co=co),self.assertRaises(ValueError):model.prepare(RAW,progress,context,chapters,'41')
    def test_adjacent_utf16_surrogate_does_not_become_one_unit_target(self):
        progress,context,chapters=fixture(len(RAW[:RAW.index('😀')].encode('utf-16-le'))//2)
        value=model.prepare(RAW,progress,context,chapters,'41');self.assertIsNone(value['target'])
    def test_reader_progress_or_catalog_identity_mismatch_is_rejected(self):
        for kind in ('reader','index','foreign','unstarted'):
            progress,context,chapters=fixture()
            if kind=='reader':context['progress']['book']['chapterOffset']+=1
            elif kind=='index':chapters[0]['chapterIdx']=4
            elif kind=='foreign':context['book_id']='42'
            else:progress['book']['chapterUid']=0;context['progress']=deepcopy(progress)
            with self.subTest(kind=kind),self.assertRaises(ValueError):model.prepare(RAW,progress,context,chapters,'41')
    def test_ambiguous_context_and_invalid_raw_text_are_refused(self):
        with self.assertRaises(ValueError):model.anchor(model.PlainSource('合成'*400),200)
        progress,context,chapters=fixture()
        with self.assertRaises(model.CoordinateError):model.prepare('bad\0text',progress,context,chapters,'41')
    def test_percent_is_preserved_and_not_derived_from_offset(self):
        progress,context,chapters=fixture();progress['book']['progress']=12.345;context['progress']=deepcopy(progress)
        value=model.prepare(RAW,progress,context,chapters,'41');self.assertEqual(value['baseline']['raw_percent'],12.345)
        self.assertEqual(value['target']['raw_percent'],12.345)
    def test_unstarted_candidate_is_skipped_before_content_request(self):
        web=task.Probe();web.book_id='41'
        with patch.object(web,'request',return_value=dict(book=dict(bookId='41',chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0))) as request:
            with self.assertRaises(task.UnstartedTxt):web.choose_chapter([dict(chapterUid=2,wordCount=300)])
        self.assertEqual(request.call_count,1)

    def test_bounded_empty_search_is_reported_without_claiming_cloud_support(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'Probe') as factory,patch.object(task,'save_refreshed_web_session'),redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='900000',cookies={})
            web=factory.return_value;web.authenticated=True;web.find_sample.return_value=False;web.catalog_count=16;web.unstarted_txt=1
            web.format_counts=dict(txt=1,epub=15);web.report={'stages':[]}
            self.assertEqual(task.main(['--saved-session']),0)
        report=json.loads(out.getvalue());self.assertEqual(report['result'],'NO_RESTORABLE_TXT_IN_BOUNDED_SAMPLE')
        self.assertFalse(report['cloud_coordinate_semantics_verified']);self.assertFalse(report['upload_enabled']);web.inspect_plan.assert_not_called()

    def test_existing_guard_still_rejects_progress_writes_and_renewal(self):
        web=task.Probe();web.vid='900000';web.authenticated=True;web.book_id='41'
        for route in ('/web/book/read','/web/login/renewal','/web/shelf/add'):
            with self.assertRaises(task.PreflightError):web.guard('write',task.BASE+route,{})
        web.close()

    def test_long_cloud_summary_cannot_be_declared_restorable_by_old_wire(self):
        progress,context,chapters=fixture();progress['book']['summary']='独立的合成'+'长'*30;context['progress']=deepcopy(progress)
        value=model.prepare(RAW,progress,context,chapters,'41')
        self.assertFalse(value['original_summary_preserved']);self.assertFalse(value['existing_wire_preflight_compatible'])
        self.assertEqual(value['source_summary_scalars'],35);self.assertTrue(value['source_has_bom'])
        self.assertEqual(value['source_nonbmp_scalars'],1)

    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'Probe') as web,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();web.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_private_exception_is_never_emitted(self):
        with patch.object(task,'SessionStore',side_effect=ValueError('synthetic private source')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main(['--saved-session']),1)
        self.assertNotIn('synthetic private',out.getvalue())


if __name__=='__main__':unittest.main()
