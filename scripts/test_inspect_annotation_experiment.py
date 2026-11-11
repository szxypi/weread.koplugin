"""Pending-record diagnosis never writes or exposes private response fields."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from annotation_experiment_model import bind,context,note_text,shelf_state,thoughts_state,marks_state,point
from inspect_annotation_experiment import inspect,Inspector,main,BASE
from test_annotation_experiment import shelf,thoughts,marks,info,position,note
from test_eink_login import Opener
from test_secure_native_session import credentials


class InspectionTests(unittest.TestCase):
    def fixture(self):
        sources=dict(shelf=shelf(),thoughts=thoughts(),marks=marks(),metadata=info(),position=position())
        baseline=dict(shelf=shelf_state(sources['shelf']),thoughts=thoughts_state(sources['thoughts'],'41','900000'),
            marks=marks_state(sources['marks'],'41','900000'),position=point(sources['position'],'41'))
        key,ctx=context(sources['marks'],sources['metadata'],'41','900000')
        plan=bind('900000','41',key,'a'*32,ctx,baseline)
        created=note('new-test',note_text('a'*32));created['review']['chapterUid']='2'
        sources['thoughts']=thoughts(created)
        return sources,plan

    def test_only_fixed_types_and_equality_flags_leave_the_private_snapshot(self):
        sources,plan=self.fixture();sources['thoughts']['reviews'][-1]['review']['extra']='must not leak'
        result=inspect(sources,plan)
        self.assertTrue(all(result['original_'+key+'_unchanged'] for key in ['shelf','marks','position','thoughts','context']))
        self.assertTrue(result['test_private'] and result['test_same_owner'] and result['test_same_book'] and result['full_projection_valid'])
        self.assertTrue(all(result['test_context_checks'].values()))
        self.assertEqual(result['test_field_types']['chapterUid'],'str');self.assertEqual(result['matching_test_records'],1)
        for private in ['must not leak','Private quote','new-test','Private original thought','a'*32]:self.assertNotIn(private,json.dumps(result))

    def test_invalid_new_field_is_diagnosed_without_hiding_changes_to_originals(self):
        sources,plan=self.fixture();sources['thoughts']['reviews'][-1]['review']['createTime']='must not leak'
        result=inspect(sources,plan);self.assertFalse(result['full_projection_valid']);self.assertEqual(result['projection_reason'],'my_thoughts_number')
        self.assertTrue(result['original_thoughts_unchanged']);self.assertNotIn('must not leak',json.dumps(result))
        changed=deepcopy(sources);changed['thoughts']['reviews'][0]['review']['content']='External edit'
        self.assertFalse(inspect(changed,plan)['original_thoughts_unchanged'])

    def test_inspector_only_allows_fixed_read_urls_with_a_five_request_cap(self):
        opener=Opener([{}]*5);probe=Inspector('41',opener);probe.last=0
        with patch('inspect_annotation_experiment.time.sleep'):
            for _i in range(5):probe.request('shelf',BASE+'/shelf/sync',credentials=credentials())
            for stage,url,body in [('shelf',BASE+'/shelf/sync',None),('thoughts',BASE+'/review/delete',{}),('marks',BASE+'/book/bookmarklist?bookId=99&synckey=0',None)]:
                with self.assertRaises(ValueError):probe.request(stage,url,body,credentials())
        self.assertTrue(all(r.get_method()=='GET' for r in opener.requests));self.assertEqual(len(opener.requests),5)

    def test_default_never_reads_login_or_intent_storage(self):
        with patch('inspect_annotation_experiment.AnnotationExperimentStore') as intent,patch('inspect_annotation_experiment.SessionStore') as web,\
            patch('inspect_annotation_experiment.NativeSessionStore') as native,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        intent.assert_not_called();web.assert_not_called();native.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
