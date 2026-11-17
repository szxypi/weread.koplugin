import unittest
from unittest.mock import patch
import test_translation_generation as fixtures
from translation_source import structural_title,chapter_title,admit_source
from translation_generation import bind
from verify_translation_generation import inspect


class SourceTest(unittest.TestCase):
    def prose(self):return '<html><body><p>'+'Original English prose continues clearly. '*40+'</p></body></html>'
    def test_known_structural_titles_are_not_prose_candidates(self):
        for value,kind in (('版权信息','copyright'),('版 权 信 息','copyright'),('COPYRIGHT PAGE','copyright'),
                ('Table of Contents','contents'),('目 录','contents'),('Cover','cover'),('扉页','title_page')):
            self.assertEqual(structural_title(value),kind)
    def test_actual_preface_and_normal_chapter_are_not_rejected_by_title(self):
        for value in (None,'Preface','Introduction','Chapter One','前言'):
            self.assertIsNone(structural_title(value))
        self.assertTrue(admit_source(self.prose(),'Preface')['english_prose_sample'])
    def test_unknown_title_never_coerces_arbitrary_values(self):
        for value in (True,{},123,'a\0b','x'*4097):
            with self.assertRaises(ValueError):structural_title(value)
    def test_rights_text_can_exceed_length_minimum_without_being_english_prose(self):
        source='<body><p>'+'版权所有，保留所有权利。'*20+'Publisher 2026.</p></body>'
        with self.assertRaisesRegex(ValueError,'not_english_prose'):admit_source(source)
        with self.assertRaisesRegex(ValueError,'structural_source'):admit_source(self.prose(),'Copyright')
    def test_script_title_translation_or_long_single_token_cannot_fake_original_words(self):
        for source in ('<body><p>'+'A'*400+'</p></body>','<head><title>'+('English prose '*80)+'</title></head><body><p>Short</p></body>',
                '<body><script>'+('English prose '*80)+'</script><p>Short</p></body>',
                '<body><p class="wr-translation">'+('Translated prose '*80)+'</p></body>'):
            with self.assertRaises(ValueError):admit_source(source)
    def test_long_link_directory_is_not_a_missing_prose_chapter(self):
        source='<body><h1>Index</h1>'+''.join('<p><a href="x">Chapter number '+str(i)+'</a></p>' for i in range(1,61))+'</body>'
        with self.assertRaisesRegex(ValueError,'structural_source'):admit_source(source)
        admit_source(self.prose().replace('</p>','<a href="x">One link</a></p>'))
    def test_native_title_lookup_requires_matching_book_and_uid(self):
        sample=dict(book_id='900001',source=dict(data=[dict(bookId='900002',updated=[dict(chapterUid=1,title='Wrong')]),
            dict(bookId='900001',updated=[dict(chapterUid='1',title='Copyright')])]))
        self.assertEqual(chapter_title(sample,1),'Copyright');self.assertIsNone(chapter_title(sample,2))
    def test_direct_plan_binding_also_rejects_structural_title(self):
        f=fixtures.PlanTest();f.setUp()
        with self.assertRaisesRegex(ValueError,'structural_source'):bind('900000',f.grant,f.member,f.catalog,f.chapter,f.source,f.baseline,chapter_title='Copyright')
    def test_inspection_skips_structural_metadata_before_body_or_baseline_reads(self):
        f=fixtures.InspectionTest();f.setUp();f.api.samples[0]['source']=f.raw;f.raw['data'][0]['updated'][0]['title']='版权信息';report={}
        with patch('verify_translation_generation.snapshot') as baseline:
            with self.assertRaisesRegex(ValueError,'no_missing_sample'):inspect(f.api,f.web,f.grant,report)
        f.web.inspect_content.assert_not_called();baseline.assert_not_called();self.assertEqual(report['structural_chapters_skipped'],1)
    def test_metadata_wordcount_alone_does_not_override_actual_nonprose_body(self):
        f=fixtures.InspectionTest();f.setUp();f.web.content_sample['source']='<p>'+'版权信息和出版说明。'*30+'</p>';report={}
        with patch('verify_translation_generation.snapshot') as baseline:
            with self.assertRaisesRegex(ValueError,'no_missing_sample'):inspect(f.api,f.web,f.grant,report)
        baseline.assert_not_called();self.assertEqual(report['nonprose_sources_skipped'],1)
    def test_fresh_catalog_title_is_checked_again_before_returning_plan(self):
        f=fixtures.InspectionTest();f.setUp();f.raw['data'][0]['updated'][0]['title']='Copyright'
        with patch('verify_translation_generation.snapshot',return_value=f.baseline):
            with self.assertRaisesRegex(ValueError,'structural_source'):inspect(f.api,f.web,f.grant,{})


if __name__=='__main__':unittest.main()
