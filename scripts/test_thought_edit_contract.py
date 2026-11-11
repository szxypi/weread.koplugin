"""Independent no-nonce CRUD postconditions and conservative concurrency checks."""
from copy import deepcopy
import unittest
from thought_edit_contract import make,check,snapshot_hash,row_hash,digest,valid_content
from my_cloud_thoughts_model import complete
from test_annotation_experiment import thoughts,marks,info,note


class ContractTests(unittest.TestCase):
    def fixture(self):
        snapshot=complete(thoughts(),'41','900000',1);reference=deepcopy(marks()['updated'][0])
        return snapshot,reference

    def test_create_does_not_append_an_identifier_to_user_text(self):
        snapshot,reference=self.fixture();text='我的实际私密想法 😀\n第二行。'
        plan=make(snapshot,'create',reference,text,marks=marks(),metadata=info(),owner='900000')
        self.assertEqual(plan['body']['content'],text);self.assertEqual(plan['body']['isPrivate'],1)
        self.assertNotIn('content',plan['metadata']);self.assertNotIn(text,str(plan['metadata']))
        created=note('new-test',text);observed=complete(thoughts(created),'41','900000',2)
        self.assertEqual(check(observed,plan['metadata']),(True,'new-test'))

    def test_preexisting_identical_text_is_not_mistaken_for_the_creation(self):
        snapshot,reference=self.fixture();snapshot['reviews'][0].update(content='Same exact text',isPrivate=1)
        plan=make(snapshot,'create',reference,'Same exact text',marks=marks(),metadata=info(),owner='900000')
        self.assertEqual(check(snapshot,plan['metadata']),(False,None))
        observed=deepcopy(snapshot);new=deepcopy(observed['reviews'][0]);new['reviewId']='new-test';observed['reviews'].append(new)
        self.assertEqual(check(observed,plan['metadata']),(True,'new-test'))

    def test_other_changes_and_public_or_duplicate_creations_do_not_confirm(self):
        snapshot,reference=self.fixture();plan=make(snapshot,'create',reference,'Actual text',marks=marks(),metadata=info(),owner='900000')
        observed=complete(thoughts(note('new-test','Actual text')),'41','900000',2)
        for mode in ['public','duplicate','other_edit','quote','range','chapter']:
            value=deepcopy(observed)
            if mode=='public':value['reviews'][-1]['isPrivate']=0
            elif mode=='duplicate':value['reviews'].append(dict(value['reviews'][-1],reviewId='new-two'))
            elif mode=='other_edit':value['reviews'][0]['content']='External edit'
            elif mode=='quote':value['reviews'][-1]['abstract']='Other quote'
            elif mode=='range':value['reviews'][-1]['range']='1-3'
            else:value['reviews'][-1]['chapterUid']=99
            with self.subTest(mode=mode):self.assertEqual(check(value,plan['metadata']),(False,None))

    def test_edit_preserves_the_original_privacy_and_only_changes_content(self):
        for privacy in [0,1]:
            snapshot,_ref=self.fixture();snapshot['reviews'][0]['isPrivate']=privacy
            plan=make(snapshot,'edit',snapshot['reviews'][0],'New text')
            self.assertEqual(plan['body'],dict(reviewId='existing-note',content='New text'))
            changed=deepcopy(snapshot);changed['reviews'][0]['content']='New text'
            self.assertTrue(check(changed,plan['metadata'])[0])
            changed['reviews'][0]['isPrivate']=1-privacy;self.assertFalse(check(changed,plan['metadata'])[0])

    def test_delete_only_confirms_the_exact_original_set_without_that_record(self):
        snapshot,_ref=self.fixture();plan=make(snapshot,'delete',snapshot['reviews'][0])
        self.assertEqual(plan['body'],dict(reviewId='existing-note'))
        self.assertTrue(check(dict(snapshot,reviews=[]),plan['metadata'])[0]);self.assertFalse(check(snapshot,plan['metadata'])[0])

    def test_stale_reference_or_wrong_book_is_refused(self):
        snapshot,reference=self.fixture();stale=dict(snapshot['reviews'][0],content='Old version')
        with self.assertRaises(ValueError):make(snapshot,'edit',stale,'New text')
        with self.assertRaises(ValueError):make(snapshot,'create',dict(reference,range='1-3'),'New text',marks=marks(),metadata=info(),owner='900000')
        plan=make(snapshot,'delete',snapshot['reviews'][0])
        with self.assertRaises(ValueError):check(dict(snapshot,book_id='99'),plan['metadata'])

    def test_digest_is_typed_stable_and_order_independent(self):
        snapshot,_ref=self.fixture();other=dict(snapshot['reviews'][0],reviewId='other');snapshot['reviews'].append(other)
        self.assertEqual(snapshot_hash(snapshot),snapshot_hash(dict(snapshot,reviews=list(reversed(snapshot['reviews'])),fetched_at=999)))
        self.assertNotEqual(digest(['1']),digest([1]));self.assertNotEqual(digest(['a','bc']),digest(['ab','c']))
        self.assertNotEqual(row_hash(snapshot['reviews'][0]),row_hash(dict(snapshot['reviews'][0],isPrivate=0)))
        with self.assertRaises(ValueError):snapshot_hash(dict(snapshot,reviews=[other,other]))

    def test_content_bounds_do_not_truncate_or_modify_user_text(self):
        for value in ['',None,' \n\t','bad\x00','a'*131073]:self.assertFalse(valid_content(value))
        for value in ['😀 文本','中文\n第二行','a'*131072]:self.assertTrue(valid_content(value))


if __name__=='__main__':unittest.main()
