"""Unavailable coordinates and explicit catalog indices; synthetic data only."""
from copy import deepcopy
import unittest
from source_remote_position import resolve,outcome

BOOK='900001'
CAT=[dict(chapterUid=22,chapterIdx=7),dict(chapterUid=33,chapterIdx=10)]
def raw(**fields):return dict(book=dict(bookId=BOOK,progress=0,chapterUid=22,chapterOffset=0,summary='Synthetic',**fields))

class SourceRemoteTests(unittest.TestCase):
    def test_response_index_stays_in_original_raw_units(self):
        p=resolve(raw(chapterIdx=7),BOOK,CAT);self.assertEqual((p['chapter_idx'],p['chapter_index_source'],p['percent']),(7,'response',0))
    def test_missing_index_uses_explicit_catalog_index_not_array_order(self):
        for rows in (CAT,list(reversed(CAT))):
            p=resolve(raw(),BOOK,rows);self.assertEqual((p['chapter_idx'],p['chapter_index_source'],p['has_chapter_index']),(7,'catalog',True))
    def test_no_chapter_marker_is_not_a_position_or_catalog_ordinal(self):
        for fields in ({},{'chapterIdx':0},{'summary':''},{'chapterIdx':'0','summary':''}):
            v=dict(progress=0,chapterUid=0,chapterOffset=0,**fields)
            self.assertEqual(outcome(v,BOOK,CAT),dict(ok=False,reason='progress_no_chapter'))
    def test_partial_and_contradictory_zero_states_are_incomplete(self):
        for fields in ({'progress':1},{'chapterOffset':1},{'chapterIdx':7},{'summary':'nonempty'}):
            v=dict(progress=0,chapterUid=0,chapterOffset=0);v.update(fields)
            self.assertEqual(outcome(v,BOOK,CAT)['reason'],'progress_source_incomplete')
        self.assertEqual(outcome(dict(progress=0,chapterUid=0),BOOK,CAT)['reason'],'progress_source_incomplete')
    def test_present_zero_index_cannot_be_replaced_with_a_catalog_index(self):
        self.assertEqual(outcome(raw(chapterIdx=0),BOOK,CAT)['reason'],'progress_source_incomplete')
    def test_zero_offset_is_valid_but_absent_offset_is_not(self):
        self.assertTrue(outcome(raw(),BOOK,CAT)['ok']);v=raw();v['book'].pop('chapterOffset')
        self.assertEqual(outcome(v,BOOK,CAT)['reason'],'progress_source_incomplete')
    def test_duplicate_uid_or_index_and_absent_indices_are_not_inferred(self):
        for rows in ([CAT[0],CAT[0]],[CAT[0],dict(chapterUid=33,chapterIdx=7)],
                     [dict(chapterUid=22),CAT[1]],[],[dict(chapterUid=44,chapterIdx=7)]):
            self.assertEqual(outcome(raw(),BOOK,rows)['reason'],'progress_source_incomplete')
    def test_catalog_numeric_types_aliases_and_boundaries_are_strict(self):
        for change in ({'chapterIdx':True},{'chapterIdx':-1},{'chapterIdx':1.5},{'chapterIdx':'7'},
                       {'chapterIdx':float('nan')},{'chapterIdx':float('inf')},{'chapterIdx':1000001},
                       {'chapterIndex':8},{'chapterUid':0},{'chapterUid':True},{'chapterId':33}):
            rows=deepcopy(CAT);rows[0].update(change)
            self.assertEqual(outcome(raw(),BOOK,rows)['reason'],'progress_source_incomplete')
    def test_unrelated_missing_index_does_not_replace_the_selected_explicit_index(self):
        rows=[CAT[0],dict(chapterUid=33)]
        self.assertEqual(resolve(raw(),BOOK,rows)['chapter_idx'],7)
    def test_explicit_catalog_zero_and_numeric_aliases_are_preserved(self):
        rows=[dict(chapterUid='22',chapterId=22,chapterIdx=0,chapterIndex=0)]
        self.assertEqual(resolve(raw(),BOOK,rows)['chapter_idx'],0)
    def test_foreign_ancestor_rejection_and_multiple_points_still_apply(self):
        self.assertEqual(outcome(dict(bookId='900002',data=raw()),BOOK,CAT)['reason'],'progress_book_mismatch')
        self.assertEqual(outcome(dict(data=[raw(),raw()]),BOOK,CAT)['reason'],'progress_ambiguous')
    def test_missing_web_index_fixture_preserves_native_response_and_server_state(self):
        from run_missing_index_reader import MissingIndexServer
        server=MissingIndexServer()
        try:
            status,web=server.route('GET','https://weread.qq.com/web/book/getProgress?bookId=900001',{})[:2]
            self.assertEqual(status,200);self.assertNotIn('chapterIdx',web['book'])
            status,native=server.route('GET','https://i.weread.qq.com/book/getProgress?bookId=900001',{})[:2]
            self.assertEqual(status,200);self.assertEqual(native['book']['chapterIdx'],2)
            self.assertEqual(server.progress['900001']['chapterIdx'],2);self.assertEqual(server.native_posts,0)
        finally:server.server_close()
    def test_public_report_blocks_literals_and_unicode_escape_forms(self):
        from source_remote_position import public_report
        for secret in ('private-token-sentinel','这是不能写入诊断结果的原文片段'):
            for value in (secret,__import__('json').dumps(secret,ensure_ascii=True)[1:-1]):
                result=public_report(dict(result='PASS',unexpected=value),{secret})
                self.assertEqual(result['result'],'UNVERIFIED');self.assertNotIn(value,str(result))
        self.assertEqual(public_report(dict(result='PASS'),{'private-token-sentinel'}),dict(result='PASS'))
    def test_resolution_does_not_mutate_raw_or_catalog(self):
        value=raw();rows=deepcopy(CAT);before=deepcopy((value,rows));resolve(value,BOOK,rows)
        self.assertEqual((value,rows),before)

if __name__=='__main__':unittest.main()
