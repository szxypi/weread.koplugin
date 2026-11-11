"""Independent original-set, source match and linked-thought predicates."""
from copy import deepcopy
import unittest
from mark_edit_contract import make,check,row_hash,disjoint


def fixture():
    old=dict(bookmarkId='old',type=1,style=1,colorStyle=0,chapterUid=2,range='1-2',markText='Existing quote')
    snapshot=dict(book_id='41',marks=dict(schema=1,book_id='41',fetched_at=1,updated=[old],chapters=[]),
        thoughts=dict(schema=1,book_id='41',fetched_at=1,reviews=[]))
    ref=dict(selection=True,bookmarkId='selection:2:10-20:'+'a'*64,type=1,chapterUid=2,chapterIdx=3,range='10-20',markText='New quote')
    created=deepcopy(snapshot);created['marks']['updated'].append(dict(bookmarkId='new',type=1,style=1,colorStyle=0,chapterUid=2,range='10-20',markText='New quote'))
    return snapshot,ref,created


class ContractTests(unittest.TestCase):
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


if __name__=='__main__':unittest.main()
