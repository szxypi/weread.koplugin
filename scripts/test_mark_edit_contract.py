"""Independent original-set, source match and linked-thought predicates."""
from copy import deepcopy
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from mark_edit_contract import make,check,row_hash,disjoint


def fixture():
    old=dict(bookmarkId='old',type=1,style=1,colorStyle=0,chapterUid=2,range='1-2',markText='Existing quote')
    snapshot=dict(book_id='41',marks=dict(schema=1,book_id='41',fetched_at=1,updated=[old],chapters=[]),
        thoughts=dict(schema=1,book_id='41',fetched_at=1,reviews=[]))
    ref=dict(selection=True,bookmarkId='selection:2:10-20:'+'a'*64,type=1,chapterUid=2,chapterIdx=3,range='10-20',markText='New quote')
    created=deepcopy(snapshot);created['marks']['updated'].append(dict(bookmarkId='new',type=1,style=1,colorStyle=0,chapterUid=2,range='10-20',markText='New quote'))
    return snapshot,ref,created


class ContractTests(unittest.TestCase):
    def test_all_colors_preserve_style_source_and_independent_postconditions(self):
        old,ref,new=fixture();target=new['marks']['updated'][1]
        for color in range(6):
            initial=make(old,'create',ref,dict(bookId='41',version=77),style=2,color=color)
            after=deepcopy(new);after['marks']['updated'][1].update(style=2,colorStyle=color)
            self.assertEqual(check(after,initial['metadata']),(True,'new'))
            wanted=color or 1;changed=make(new,'color',target,color=wanted)
            self.assertEqual(changed['body'],dict(bookmarkId='new',style=1,colorStyle=wanted))
            after=deepcopy(new);after['marks']['updated'][1]['colorStyle']=wanted
            self.assertEqual(check(after,changed['metadata']),(True,None))
            for field,value in [('style',2),('range','1-90'),('markText','Changed'),('createTime',123)]:
                bad=deepcopy(after);bad['marks']['updated'][1][field]=value
                with self.subTest(field=field):self.assertFalse(check(bad,changed['metadata'])[0])
        for color in (True,-1,6,'2',1.5):
            with self.assertRaises(ValueError):make(new,'color',target,color=color)
        with self.assertRaises(ValueError):make(new,'color',target,color=0)
    def test_initial_style_is_in_request_match_hash_and_readback(self):
        old,ref,new=fixture();hashes=set()
        for style in (0,1,2):
            plan=make(old,'create',ref,dict(bookId='41',version=77),style=style);hashes.add(plan['metadata']['request_hash'])
            new['marks']['updated'][1]['style']=style
            self.assertEqual(plan['body']['style'],style);self.assertEqual(check(new,plan['metadata']),(True,'new'))
            new['marks']['updated'][1]['style']=(style+1)%3;self.assertFalse(check(new,plan['metadata'])[0])
        self.assertEqual(len(hashes),3)
        for style in (-1,3,True,'2',1.5):
            with self.subTest(style=style),self.assertRaises(ValueError):make(old,'create',ref,dict(bookId='41',version=77),style=style)
    def test_style_changes_only_target_style_and_preserves_linked_thought(self):
        _old,_ref,snapshot=fixture();row=snapshot['marks']['updated'][1]
        snapshot['thoughts']['reviews']=[dict(reviewId='linked',content='Keep this',chapterUid=2,range=row['range'])]
        plan=make(snapshot,'style',row,style=2);after=deepcopy(snapshot);after['marks']['updated'][1]['style']=2
        self.assertEqual(plan['body'],dict(bookmarkId='new',style=2,colorStyle=0))
        self.assertEqual(check(after,plan['metadata']),(True,None));self.assertFalse(check(snapshot,plan['metadata'])[0])
        for field,value in [('colorStyle',1),('markText','changed'),('range','1-10'),('createTime',10),('bookmarkId','changed')]:
            bad=deepcopy(after);bad['marks']['updated'][1][field]=value
            with self.subTest(field=field):self.assertFalse(check(bad,plan['metadata'])[0])
        after['marks']['chapters']=[dict(chapterUid=2,title='new descriptor')]
        self.assertFalse(check(after,plan['metadata'])[0])

    def test_style_rejects_unchanged_unknown_values_stale_reference_and_bookmark(self):
        _old,_ref,snapshot=fixture();row=snapshot['marks']['updated'][1]
        for style in (1,3,-1,True,'2',None):
            with self.subTest(style=style),self.assertRaises(ValueError):make(snapshot,'style',row,style=style)
        with self.assertRaises(ValueError):make(snapshot,'style',dict(row,markText='stale'),style=2)
        row['type']=0
        with self.assertRaises(ValueError):make(snapshot,'style',row,style=2)

    def test_exact_source_create_and_exact_delete(self):
        old,ref,new=fixture();plan=make(old,'create',ref,dict(bookId='41',version=77))
        self.assertNotIn('chapterIdx',plan['body']);self.assertEqual(plan['body']['chapterUid'],2)
        self.assertEqual(check(old,plan['metadata']),(False,None));self.assertEqual(check(new,plan['metadata']),(True,'new'))
        delete=make(new,'delete',new['marks']['updated'][1]);self.assertEqual(check(old,delete['metadata']),(True,None))
        self.assertEqual(delete['body'],dict(bookmarkIds=['new']))

    def test_changed_original_and_extra_identical_mark_do_not_confirm(self):
        old,ref,new=fixture();plan=make(old,'create',ref,dict(bookId='41',version=77))
        for mode in ('original','duplicate','style','thought'):
            changed=deepcopy(new)
            if mode=='original':changed['marks']['updated'][0]['markText']='Edited elsewhere'
            elif mode=='duplicate':changed['marks']['updated'].append(dict(changed['marks']['updated'][1],bookmarkId='another'))
            elif mode=='style':changed['marks']['updated'][1]['style']=2
            else:changed['thoughts']['reviews'].append(dict(reviewId='external',content='Other thought'))
            with self.subTest(mode=mode):self.assertEqual(check(changed,plan['metadata']),(False,None))

    def test_create_and_delete_refuse_linked_thought(self):
        old,ref,new=fixture();thought=dict(reviewId='linked',chapterUid=2,range='12-15',content='Keep this')
        old['thoughts']['reviews'].append(thought);new['thoughts']['reviews'].append(thought)
        with self.assertRaises(ValueError):make(old,'create',ref,dict(bookId='41',version=77))
        with self.assertRaises(ValueError):make(new,'delete',new['marks']['updated'][1])

    def test_selected_chapter_descriptor_can_remain_but_other_changes_cannot(self):
        old,ref,new=fixture();plan=make(old,'create',ref,dict(bookId='41',version=77))
        new['marks']['chapters'].append(dict(chapterUid=2,title='Selected'))
        self.assertEqual(check(new,plan['metadata']),(True,'new'))
        new['marks']['chapters'].append(dict(chapterUid=3,title='Unrelated'))
        self.assertFalse(check(new,plan['metadata'])[0])

    def test_existing_descriptor_and_delete_chapters_are_preserved(self):
        old,ref,new=fixture();old['marks']['chapters']=[dict(chapterUid=2,title='Selected')]
        plan=make(old,'create',ref,dict(bookId='41',version=77))
        self.assertFalse(check(new,plan['metadata'])[0])
        deletion=make(new,'delete',new['marks']['updated'][1]);old['marks']['chapters']=[]
        old['marks']['chapters'].append(dict(chapterUid=2,title='Unexpected'))
        self.assertFalse(check(old,deletion['metadata'])[0])

    def test_last_selected_chapter_descriptor_can_disappear_after_exact_deletion(self):
        old,_ref,new=fixture();old['marks']['updated'][0]['chapterUid']=7;new['marks']['updated'][0]['chapterUid']=7
        new['marks']['chapters']=[dict(chapterUid=2,title='Selected')]
        plan=make(new,'delete',new['marks']['updated'][1]);self.assertEqual(check(old,plan['metadata']),(True,None))
        empty=deepcopy(old);empty['marks']['updated']=[];before=deepcopy(new);before['marks']['updated']=before['marks']['updated'][1:]
        plan=make(before,'delete',before['marks']['updated'][0]);self.assertEqual(check(empty,plan['metadata']),(True,None))

    def test_descriptor_cannot_disappear_while_any_mark_in_that_chapter_remains(self):
        old,_ref,new=fixture();new['marks']['chapters']=[dict(chapterUid=2,title='Selected')]
        plan=make(new,'delete',new['marks']['updated'][1]);self.assertFalse(check(old,plan['metadata'])[0])

    def test_last_mark_delete_does_not_allow_changed_title_or_other_missing_descriptor(self):
        old,_ref,new=fixture();old['marks']['updated'][0]['chapterUid']=7;new['marks']['updated'][0]['chapterUid']=7
        other=dict(chapterUid=7,title='Other');old['marks']['chapters']=[other];new['marks']['chapters']=[other,dict(chapterUid=2,title='Selected')]
        plan=make(new,'delete',new['marks']['updated'][1]);self.assertTrue(check(old,plan['metadata'])[0])
        for changed in ([dict(chapterUid=2,title='Changed')],[],[dict(chapterUid=7,title='Changed')]):
            after=deepcopy(old);after['marks']['chapters']=changed
            with self.subTest(changed=changed):self.assertFalse(check(after,plan['metadata'])[0])

    def test_stale_target_overlapping_selection_and_other_book_are_rejected(self):
        old,ref,new=fixture()
        with self.assertRaises(ValueError):make(new,'create',ref,dict(bookId='41',version=77))
        with self.assertRaises(ValueError):make(old,'create',ref,dict(bookId='42',version=77))
        with self.assertRaises(ValueError):make(new,'delete',dict(new['marks']['updated'][1],markText='Old text'))

    def test_unknown_ranges_in_same_chapter_block_but_other_chapters_do_not(self):
        _old,ref,_new=fixture()
        self.assertFalse(disjoint([dict(chapterUid=2)],ref));self.assertTrue(disjoint([dict(chapterUid=3)],ref))
        self.assertFalse(disjoint([dict(chapterUid=2,range='3-1')],ref))

    def test_optional_fields_have_typed_stable_hashes(self):
        old,_ref,_new=fixture();row=old['marks']['updated'][0]
        self.assertNotEqual(row_hash(row),row_hash(dict(row,abstract='')))
        self.assertNotEqual(row_hash(row),row_hash(dict(row,chapterIdx=0)))

    def test_lifecycle_diagnostic_compares_private_plan_but_emits_only_facets(self):
        import verify_highlight_metadata_lifecycle as task
        old,_ref,new=fixture();new['marks']['chapters']=[dict(chapterUid=2,title='Selected')]
        target=new['marks']['updated'][1];plan=make(new,'delete',target)
        output=b'\nWEREAD_MARK_LIFECYCLE_RESULT='+json.dumps(dict(metadata=plan['metadata'],confirmed=False)).encode()
        with patch.object(task.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=output)):
            result=task.analyze(new,old,target,['synthetic-command'])
        self.assertFalse(result['delete_contract_confirmed']);self.assertTrue(result['selected_descriptor_before'])
        self.assertFalse(result['selected_descriptor_after']);self.assertTrue(result['exact_mark_deletion'])
        self.assertNotIn('New quote',json.dumps(result));self.assertNotIn('bookmarkId',json.dumps(result))

    def test_diagnostic_defaults_offline_without_opening_account(self):
        import verify_highlight_metadata_lifecycle as task
        with patch.object(task,'SessionStore') as login,patch.object(task,'HighlightProbe') as probe,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        login.assert_not_called();probe.assert_not_called();self.assertEqual(json.loads(output.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
