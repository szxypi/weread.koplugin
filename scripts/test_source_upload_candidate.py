"""Source-coordinate upload preparation only; no network or credential access."""
from contextlib import redirect_stdout
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch,MagicMock
from source_upload_candidate import project
import verify_source_upload_candidate as task


class CandidateTests(unittest.TestCase):
    raw='<html><body><p>ABCDEFG😀&amp;中文HIJKLMNOPQRSTUVWXYZ末尾。</p></body></html>'
    chapters=[dict(chapterUid=11,chapterIdx=0,wordCount=1)]
    point=dict(book_id='900001',chapter_uid='11',chapter_offset=15)

    def test_default_never_loads_credentials(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_source_units_and_summary_do_not_use_catalog_word_count(self):
        value=project(self.raw,self.point,self.chapters,37)
        self.assertEqual(value['chapter_offset'],15);self.assertEqual(value['chapter_idx'],0)
        self.assertEqual(value['summary'],'ABCDEFG😀&中文HIJKLMNOP')
        self.assertEqual(value['percent'],37);self.assertFalse(value['upload_verified'])

    def test_summary_preserves_whole_astral_scalars_and_decodes_entities(self):
        value=project(self.raw,dict(self.point,chapter_offset=22),self.chapters,0)
        self.assertTrue(value['summary'].startswith('😀&中文'))
        self.assertLessEqual(len(value['summary']),20)

    def test_no_guess_for_markup_entity_interior_or_end_boundary(self):
        for offset in (0,23,25,999):
            with self.assertRaises(ValueError):project(self.raw,dict(self.point,chapter_offset=offset),self.chapters,10)

    def test_ambiguous_or_missing_catalog_is_rejected(self):
        for rows in ([],self.chapters*2,[dict(chapterUid=11)],[dict(chapterUid=11,chapterIdx=True)],
                     [dict(chapterUid=11,chapterIdx=1,chapter_idx=2)],[dict(chapterUid=11,chapterId=22,chapterIdx=1)]):
            with self.assertRaises(ValueError):project(self.raw,self.point,rows,10)

    def test_invalid_point_identity_and_percent_rejected(self):
        for percent in (True,-1,101,.5,float('nan')):
            with self.assertRaises(ValueError):project(self.raw,self.point,self.chapters,percent)
        for key,value in (('book_id','other'),('chapter_uid',True),('chapter_offset',False),('chapter_offset',15.5)):
            with self.assertRaises(ValueError):project(self.raw,dict(self.point,**{key:value}),self.chapters,10)

    def test_repeated_short_context_cannot_be_assigned_to_first_occurrence(self):
        raw='<body><p>'+('abcdefghijklmnopqrstuvwx'*50)+'</p></body>'
        with self.assertRaises(ValueError):project(raw,dict(self.point,chapter_offset=300),self.chapters,10)

    def run_saved(self,lua=False,bad=False):
        points=[dict(self.point,raw_percent=37),dict(self.point,chapter_offset=22,raw_percent=37)]
        probe=MagicMock();probe.chapters=self.chapters;probe.shards={key:'private shard' for key in ('e_0','e_1','e_3')}
        probe.report={'stages':[]};probe.prepare.return_value={'progress_preview':dict(zip(('baseline','target'),points))}
        def reply(_command,**options):
            private=json.loads(options['input'])
            self.assertEqual(set(private),{'raw','chapters','cases'})
            self.assertTrue(all(set(case)=={'point','percent'} for case in private['cases']))
            rows=[project(private['raw'],case['point'],private['chapters'],case['percent']) for case in private['cases']]
            return SimpleNamespace(returncode=0,stdout=b'PRIVATE_DIAGNOSTIC' if bad else b'\nSOURCE_UPLOAD_CANDIDATES='+json.dumps(rows).encode())
        with patch.object(task,'Probe',return_value=probe),patch.object(task,'SessionStore') as store, \
                patch.object(task,'decode_content_shards',return_value=self.raw), \
                patch.object(task,'save_refreshed_web_session',return_value=False), \
                patch.object(task.subprocess,'run',side_effect=reply) as child,redirect_stdout(io.StringIO()) as output:
            store.return_value.load.return_value=dict(vid='900099',cookies={'wr_skey':'PRIVATE_COOKIE'})
            code=task.main(['--saved-session']+(['--lua-command','synthetic-only'] if lua else []))
        return code,json.loads(output.getvalue()),child

    def test_saved_readonly_model_never_launches_a_child_or_exposes_private_data(self):
        code,report,child=self.run_saved()
        self.assertEqual(code,0);child.assert_not_called()
        self.assertEqual(report['result'],'REAL_SOURCE_CANDIDATES_MODEL_VERIFIED')
        self.assertNotIn(self.raw,json.dumps(report));self.assertNotIn('PRIVATE_COOKIE',json.dumps(report))

    def test_lua_comparison_receives_no_expected_answers_or_credentials(self):
        code,report,child=self.run_saved(lua=True)
        self.assertEqual(code,0);self.assertEqual(child.call_count,1)
        self.assertTrue(report['independent_lua_comparison']);self.assertFalse(report['upload_enabled'])

    def test_missing_private_frame_remains_unverified_without_echoing_output(self):
        code,report,child=self.run_saved(lua=True,bad=True)
        self.assertEqual(code,1);self.assertEqual(child.call_count,1)
        self.assertEqual(report['reason'],'candidate_unverified')
        self.assertNotIn('PRIVATE_',json.dumps(report))


if __name__=='__main__':unittest.main()
