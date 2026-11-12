"""CB_ readonly projection/source checks never grant numeric-book writes."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import io,json,unittest
from unittest.mock import patch
from cb_cloud_position import state,observed,mapping
from verify_source_coordinates import FilteredSource
import verify_cb_cloud_position as task

BOOK='CB_SyntheticOnly';CAT=[dict(chapterUid=17,chapterIdx=4)]
RAW='<html><body><p>Alpha unique opening words of this synthetic test paragraph continue here.</p></body></html>'


def progress(**changes):
    p=dict(bookId=BOOK,chapterUid=17,chapterIdx=4,chapterOffset=15,progress=12,summary='Alpha unique opening words');p.update(changes);return p


class CbCloudPositionTests(unittest.TestCase):
    def test_default_is_offline_and_does_not_load_sessions_or_readers(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'NativeSessionStore') as grant,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();grant.assert_not_called();child.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
    def test_incomplete_private_lua_mode_is_rejected(self):
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--lua-command','synthetic'])
    def test_book_namespace_channel_and_foreign_response_are_strict(self):
        for book,channel in (('900001','web'),('CB_bad-name','web'),('CB_'+'a'*65,'web'),(BOOK,'gateway')):
            with self.assertRaises(ValueError):state(progress(),book,CAT,channel)
        self.assertEqual(state(progress(bookId='CB_Foreign'),BOOK,CAT,'web')['reason'],'progress_book_mismatch')
    def test_explicit_index_and_missing_index_provenance_are_preserved(self):
        p=state(progress(),BOOK,CAT,'native');self.assertEqual(p['index_source'],'response');self.assertTrue(p['summary_present'])
        raw=progress();del raw['chapterIdx'];self.assertEqual(state(raw,BOOK,CAT,'web')['index_source'],'catalog')
        for raw,cat in ((progress(chapterIdx=0),CAT),(progress(),[dict(chapterUid=17)]),(progress(),CAT*2)):
            self.assertEqual(state(raw,BOOK,cat,'web')['kind'],'unavailable')
    def test_absent_fields_and_zero_marker_do_not_form_a_fake_point(self):
        p=progress(chapterUid=0,chapterOffset=0,progress=0,summary='');del p['chapterIdx']
        self.assertEqual(state(p,BOOK,CAT,'web')['kind'],'no_chapter')
        for key,value in (('chapterOffset',1),('summary','nonempty'),('progress',1)):
            v=dict(p);v[key]=value;self.assertEqual(state(v,BOOK,CAT,'web')['kind'],'unavailable')
        self.assertFalse(mapping(RAW,'17',state(p,BOOK,CAT,'web'))['visible_boundary'])
    def test_unavailable_native_route_is_observed_without_inventing_presence(self):
        p=dict(errcode=-1);v=observed(p,BOOK,CAT,'native')
        self.assertEqual(v['state']['reason'],'progress_rejected');self.assertEqual(v['presence'],{})
    def test_raw_field_presence_is_part_of_read_only_stability(self):
        p=progress();one=observed(p,BOOK,CAT,'web');p.pop('summary');two=observed(p,BOOK,CAT,'web')
        self.assertNotEqual(one,two);self.assertFalse(two['state']['summary_present'])
    def test_mapping_requires_exact_visible_boundary_and_same_source_chapter(self):
        p=state(progress(),BOOK,CAT,'web');r=mapping(RAW,'17',p)
        self.assertTrue(r['visible_boundary'] and r['unique_anchor'] and r['summary_matches'])
        p['chapter_offset']=14;self.assertFalse(mapping(RAW,'17',p)['visible_boundary'])
        p['chapter_offset']=15;self.assertFalse(mapping(RAW,'18',p)['chapter_matches'])
    def test_multi_body_coordinates_keep_the_original_offsets(self):
        raw=RAW+'<html><body><p>Second distinct source paragraph contains exact visible words.</p></body></html>'
        model=FilteredSource(raw,allow_multiple_bodies=True);co=model.locate('Second distinct source paragraph')[0]
        p=state(progress(chapterOffset=co,summary='Second distinct source paragraph'),BOOK,CAT,'web');r=mapping(raw,'17',p)
        self.assertTrue(r['multiple_bodies'] and r['visible_boundary'] and r['unique_anchor'] and r['summary_matches'])
    def test_missing_summary_is_not_replaced_with_a_quote_or_title_authority(self):
        raw=progress();raw.pop('summary');raw['chapterTitle']='Alpha unique opening words'
        p=state(raw,BOOK,CAT,'web');self.assertFalse(p['summary_present']);self.assertFalse(mapping(RAW,'17',p)['summary_matches'])
    def test_native_transport_rejects_writes_wrong_grants_foreign_books_and_repeats(self):
        g=dict(vid='synthetic');api=task.Native(g);api.allowed={BOOK};url='https://i.weread.qq.com/book/getProgress?bookId='+BOOK
        with patch.object(task.NativeProbe,'request',return_value=progress()) as read:
            for args in ((url,{} ,g),(url,None,{}),(url+'x',None,g),('https://weread.qq.com/book/getProgress?bookId='+BOOK,None,g)):
                with self.assertRaises(ValueError):api.request('test',args[0],args[1],credentials=args[2])
            self.assertEqual(read.call_count,0)
            api.request('test',url,credentials=g);api.request('test',url,credentials=g)
            with self.assertRaises(ValueError):api.request('test',url,credentials=g)
            self.assertEqual(read.call_count,2)


if __name__=='__main__':unittest.main()
