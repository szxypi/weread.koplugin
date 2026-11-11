"""Point lifecycle guards, optional response fields and exact original sets."""
from copy import deepcopy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch
from bookmark_reference import reference
from bookmark_point import project
from mark_edit_contract import make,check
from test_bookmark_point import coordinate
from test_mark_edit_contract import fixture


class BookmarkContractTests(unittest.TestCase):
    def fixture(self):
        old,_text,_created=fixture();raw='<body><p>Unique bookmark\r\nsource text with enough context.</p></body>'
        ref=reference('41','2',3,project(raw,coordinate(raw,'Unique')))
        old['marks']['updated'][0]['range']='1-999'
        old['thoughts']['reviews']=[dict(reviewId='linked',chapterUid=2,range='1-999',content='Preserve')]
        plan=make(old,'bookmark_create',ref,dict(bookId='41',version=77))
        target={k:v for k,v in plan['body'].items() if k not in ('bookId','bookVersion')};target.update(bookmarkId='new',createTime=1)
        added=deepcopy(old);added['marks']['updated'].append(target)
        return old,ref,plan,added,target

    def test_type_point_preview_and_absent_native_fields(self):
        old,_ref,plan,added,_target=self.fixture()
        self.assertEqual(set(plan['body']),{'bookId','chapterUid','bookVersion','type','style','range','markText'})
        self.assertEqual((plan['body']['type'],plan['body']['style']),(0,0));self.assertIn('\r\n',plan['body']['markText'])
        self.assertEqual(check(old,plan['metadata']),(False,None));self.assertEqual(check(added,plan['metadata']),(True,'new'))

    def test_optional_response_fields_and_exact_preview_if_present(self):
        _old,_ref,plan,added,target=self.fixture()
        for field in ('markText','style','colorStyle'):target.pop(field,None)
        added['marks']['updated'][-1]=target;self.assertEqual(check(added,plan['metadata']),(True,'new'))
        for field,value in [('markText','Changed'),('style',1),('colorStyle',True),('type',1),('range','99'),('chapterUid',3)]:
            bad=deepcopy(added);bad['marks']['updated'][-1][field]=value
            with self.subTest(field=field):self.assertEqual(check(bad,plan['metadata']),(False,None))

    def test_unchanged_original_sets_and_one_new_record(self):
        _old,_ref,plan,added,_target=self.fixture()
        for group in ('mark','thought','chapter','duplicate'):
            bad=deepcopy(added)
            if group=='mark':bad['marks']['updated'][0]['markText']='Changed'
            elif group=='thought':bad['thoughts']['reviews'][0]['content']='Changed'
            elif group=='chapter':bad['marks']['chapters'].append(dict(chapterUid=9,title='New unrelated'))
            else:bad['marks']['updated'].append(dict(bad['marks']['updated'][-1],bookmarkId='another'))
            with self.subTest(group=group):self.assertFalse(check(bad,plan['metadata'])[0])

    def test_duplicate_point_and_stale_deletion_blocked_without_blocking_text_overlap(self):
        old,ref,_plan,added,target=self.fixture()
        with self.assertRaises(ValueError):make(added,'bookmark_create',ref,dict(bookId='41',version=77))
        delete=make(added,'bookmark_delete',target);self.assertTrue(check(old,delete['metadata'])[0])
        with self.assertRaises(ValueError):make(added,'delete',target)
        with self.assertRaises(ValueError):make(added,'bookmark_delete',dict(target,createTime=2))
        with self.assertRaises(ValueError):make(added,'bookmark_delete',added['marks']['updated'][0])

    def test_unknown_catalog_scope_version_and_invalid_source_ref_rejected(self):
        old,ref,_plan,_added,_target=self.fixture()
        for field,value in [('chapterIdx',4),('range','01'),('markText','\x00'),('markText','\ud800'),('type',1),('bookmarkId','other')]:
            with self.subTest(field=field),self.assertRaises((ValueError,UnicodeError)):
                make(old,'bookmark_create',dict(ref,**{field:value}),dict(bookId='41',version=77))
        for version in (None,True,0,-1,'77'):
            with self.subTest(version=version),self.assertRaises(ValueError):make(old,'bookmark_create',ref,dict(bookId='41',version=version))

    def test_readonly_verifier_defaults_offline_without_loading_account(self):
        import verify_bookmark_contract as task
        with patch.object(task,'SessionStore') as login,patch.object(task,'BookmarkProbe') as source,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        login.assert_not_called();source.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_pending_scope_exclusion_never_bypasses_a_native_bookmark_trial(self):
        import verify_native_thought_trial as task
        from unittest.mock import Mock
        for native in (False,True):
            with patch.object(task,'AnnotationExperimentStore') as a,patch.object(task,'FinishExperimentStore') as f,patch.object(task,'ShelfExperimentStore') as s,patch.object(task,'PositionExperimentStore') as p,patch.object(task,'HighlightTrialStore') as h,patch.object(task,'MarkStyleTrialStore') as styles,patch.object(task,'BookmarkTrialStore') as bookmarks,patch.object(task,'NativeShelfTrialStore') as shelf_trial,patch.object(task,'NativeFinishTrialStore') as finish_trial,patch.object(task,'InitialMarkStyleStore') as initial,patch.object(task,'MarkColorStore') as colors,patch.object(task,'NonemptyMarksStore') as nonempty:
                nonempty.return_value.read.return_value=initial.return_value.read.return_value=colors.return_value.read.return_value=(None,None)
                finish_trial.return_value.pending.return_value=False
                shelf_trial.return_value.pending.return_value=False
                styles.return_value.read.return_value=h.return_value.read.return_value=(None,None)
                for factory in (a,f,s,p):factory.return_value.pending.return_value=False
                bookmarks.side_effect=lambda **kw:Mock(read=Mock(return_value=({'phase':'create_pending'} if kw['native']==native else None,None)))
                self.assertTrue(task.other_pending());self.assertEqual(task.other_pending(exclude_bookmark=True),native)


if __name__=='__main__':unittest.main()
