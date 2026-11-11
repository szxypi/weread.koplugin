"""Source-range navigation model; synthetic input and no real network."""
from contextlib import redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
import unittest
from unittest.mock import patch

from my_mark_target import project
from verify_my_mark_target import TargetMarksProbe,main,NATIVE
from test_eink_login import Opener
from test_secure_native_session import credentials
from run_my_mark_navigation_ui import validate as validate_ui,public_report,FLAGS,COUNTS


def row(raw,quote,start=None):
    source=raw.removeprefix('\ufeff');start=source.index(quote) if start is None else start
    return dict(type=1,chapterUid=2,markText=quote,range=f'{start}-{start+len(quote)}')


class TargetTests(unittest.TestCase):
    def test_plain_and_bom_coordinates_bind_original_bytes(self):
        for bom,expected in [('',15),('\ufeff',16)]:
            raw=bom+'<html><body><p>Unique selected text content.</p></body></html>'
            value=project(raw,'41','2',row(raw,'Unique selected text'))
            self.assertEqual(value,dict(book_id='41',chapter_uid='2',chapter_offset=expected,
                raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),raw_bytes=len(raw.encode()),basis='filtered_xhtml_utf16',upload_verified=False))

    def test_scalar_ranges_are_not_utf16_progress_offsets(self):
        raw='<html><body><p>😀 Unique selected text content.</p></body></html>'
        mark=row(raw,'Unique selected text');self.assertEqual(mark['range'],'17-37')
        self.assertEqual(project(raw,'41','2',mark)['chapter_offset'],18)

    def test_ignored_markup_uses_filtered_run_coordinates(self):
        raw='<html><body><p>prefix<a href="https://example.invalid/">Unique selected text</a> tail</p></body></html>'
        mark=row(raw,'Unique selected text');self.assertGreater(int(mark['range'].split('-')[0]),21)
        self.assertEqual(project(raw,'41','2',mark)['chapter_offset'],21)

    def test_entities_and_markup_in_the_selection_are_checked_as_visible_text(self):
        raw='<html><body><p>Unique &amp; selected <b>text</b> content.</p></body></html>'
        start=raw.index('Unique');end=raw.index('</b>')+4
        mark=dict(type=1,chapterUid=2,markText='Unique & selected text',range=f'{start}-{end}')
        self.assertEqual(project(raw,'41','2',mark)['chapter_offset'],15)
        mark['range']=f'{start+8}-{end}'
        with self.assertRaisesRegex(ValueError,'quote_changed'):project(raw,'41','2',mark)

    def test_short_repeated_quote_resolves_only_with_unique_surroundings(self):
        raw='<html><body><p>First context before YES after first instance.</p><p>Second context before YES after second instance.</p></body></html>'
        start=raw.index('YES',raw.index('Second'))
        value=project(raw,'41','2',row(raw,'YES',start))
        self.assertEqual(value['chapter_offset'],start)

    def test_repeated_context_is_never_assigned_to_the_first_match(self):
        block='<p>'+('identical long context '*20)+'YES'+(' identical suffix'*20)+'</p>'
        raw='<html><body>'+block+block+'</body></html>'
        with self.assertRaisesRegex(ValueError,'unmatched|ambiguous'):project(raw,'41','2',row(raw,'YES',raw.rindex('YES')))

    def test_modified_source_quote_or_range_cannot_produce_a_target(self):
        raw='<html><body><p>Unique selected text content.</p></body></html>';original=row(raw,'Unique selected text')
        for mode in ['text','range','outside','reversed','missing']:
            mark=deepcopy(original)
            if mode=='text':mark['markText']='Changed selected text'
            elif mode=='range':mark['range']='16-35'
            elif mode=='outside':mark['range']='1-99999'
            elif mode=='reversed':mark['range']='35-15'
            else:mark.pop('range')
            with self.subTest(mode=mode),self.assertRaises(ValueError):project(raw,'41','2',mark)

    def test_ownership_book_chapter_type_and_quote_validation(self):
        raw='<html><body><p>Unique selected text content.</p></body></html>';original=row(raw,'Unique selected text')
        for field,value in [('bookId','99'),('chapterUid',3),('chapterUid',True),('type',0),('type',True),('markText',''),('markText','\x00'),('markText','x'*131073),('range',True)]:
            mark=dict(original);mark[field]=value
            with self.subTest(field=field,value=type(value).__name__),self.assertRaises(ValueError):project(raw,'41','2',mark)

    def test_scripts_and_nonvisible_ranges_cannot_be_used(self):
        raw='<html><body><script>Secret selected script text</script><p>Unique visible body text</p></body></html>'
        with self.assertRaisesRegex(ValueError,'quote_changed'):project(raw,'41','2',row(raw,'Secret selected script text'))

    def test_only_edge_whitespace_may_differ_from_the_saved_quote(self):
        raw='<html><body><p>\n  Unique selected text \t\n</p></body></html>'
        start=raw.index('\n');end=raw.index('</p>')
        mark=dict(type=1,chapterUid=2,markText='Unique selected text',range=f'{start}-{end}')
        self.assertEqual(project(raw,'41','2',mark)['chapter_offset'],18)
        mark['markText']='Unique  selected text'
        with self.assertRaisesRegex(ValueError,'quote_changed'):project(raw,'41','2',mark)

    def test_head_and_comment_text_cannot_redirect_to_an_identical_body_quote(self):
        raw='<html><head><title>Unique selected text</title></head><body><!--Unique selected text--><p>Unique selected text</p></body></html>'
        for start in (raw.index('Unique'),raw.index('Unique',raw.index('<body>'))):
            with self.assertRaisesRegex(ValueError,'quote_changed'):project(raw,'41','2',row(raw,'Unique selected text',start))

    def test_long_selected_text_uses_a_bounded_prefix_for_location(self):
        quote='Unique start of a long selected passage. '+('Other long text '*6000)
        raw='<html><body><p>'+quote+'</p></body></html>'
        self.assertEqual(project(raw,'41','2',row(raw,quote))['chapter_offset'],15)

    def test_final_native_requests_are_fixed_gets_and_ordered(self):
        opener=Opener([{},{}]);probe=TargetMarksProbe(opener);probe.identity='41';probe.calls=5
        for stage,path in [('final_marks','/book/bookmarklist?bookId=41&synckey=0'),('final_position','/book/getProgress?bookId=41')]:
            with self.assertRaises(ValueError):probe.request(stage,NATIVE+path,body={'unsafe':True},credentials=credentials())
            probe.request(stage,NATIVE+path,credentials=credentials())
            with self.assertRaises(ValueError):probe.request(stage,NATIVE+path,credentials=credentials())
        self.assertEqual(len(opener.requests),2);self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))

    def test_default_never_accesses_credentials_or_network(self):
        out=io.StringIO()
        with patch('verify_my_mark_target.SessionStore',side_effect=AssertionError('must stay offline')),redirect_stdout(out):self.assertEqual(main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_native_ui_requires_all_targets_and_no_network_in_both_processes(self):
        value=dict.fromkeys(FLAGS,True);value.update(dict.fromkeys(COUNTS,0))
        value.update(result='PASS',mode='live',phase='complete',located=52,buttons=52,source_files=6)
        self.assertEqual(validate_ui(value,'live',52,5),value)
        for key,changed in [('requests',1),('screenshots',1),('located',51),('buttons',51),('source_files',5),('exact_targets',False),('mode','reopen'),('failed_line',9)]:
            with self.subTest(key=key),self.assertRaises(ValueError):validate_ui(dict(value,**{key:changed}),'live',52,5)
        with self.assertRaises(ValueError):validate_ui(dict(value,private='must not pass'),'live',52,5)

    def test_private_or_malformed_ui_output_never_enters_public_report(self):
        private='Private account and book text'
        output=public_report(dict(result=private,private=private,installed_files=True,stages=[dict(phase=private,mode=private,quote=private,requests=4,located=private,exact_targets=False)]))
        self.assertNotIn(private,json.dumps(output));self.assertEqual(output,dict(stages=[dict(requests=4,exact_targets=False)]))
        self.assertEqual(public_report(None),{})


if __name__=='__main__':unittest.main()
