"""Observable-state and once-only private trial boundaries. Synthetic data only."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch
from secure_shelf_experiment import canonical,Receipt
from secure_shelf_flag_trial import FlagTrialStore,validate_plan
from secure_weread_session import StoreError
from shelf_flag_change_contract import make,check,request,position,valid_metadata,state_hash
from test_secure_native_session import Backend,credentials
import verify_shelf_flag_change as task


def source():return dict(books=[dict(bookId='41',secret=0,finishReading=0),dict(bookId='42',secret=1,finishReading=1)],archive=[dict(archiveId='group',name='Synthetic',bookIds=['41','42'])])
def point():return dict(book=dict(bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=20,progress=12.5))
def plan():
    first=source();second=deepcopy(first);second['books'][0]['secret']=1
    return dict(owner='900000',grant_sha256=task.digest(credentials()),change=make(first,point(),'41','private',True)['metadata'],restore=make(second,point(),'41','private',False)['metadata'])


class ShelfFlagTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'Probe') as probe,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();probe.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
    def test_private_body_and_exact_opposite_transitions(self):
        self.assertEqual(request('private','41',True),dict(bookIds=['41'],private=1))
        self.assertEqual(request('private','41',False),dict(bookIds=['41'],private=0))
        value=plan();self.assertTrue(validate_plan(value));self.assertNotEqual(value['change']['request_hash'],value['restore']['request_hash'])
        changed=source();changed['books'][0]['secret']=1
        self.assertTrue(check(changed,point(),value['change']));self.assertTrue(check(source(),point(),value['restore']))
    def test_missing_pinned_flag_is_unknown_not_false(self):
        with self.assertRaises(ValueError):make(source(),point(),'41','pinned',True)
    def test_false_pin_is_a_valid_pure_model_when_actually_returned(self):
        value=source();value['books'][0]['isTop']=False
        metadata=make(value,point(),'41','pinned',True)['metadata'];self.assertTrue(valid_metadata(metadata))
        value['books'][0]['isTop']=True;self.assertTrue(check(value,point(),metadata))
    def test_other_flags_members_groups_and_position_are_protected(self):
        p=plan()['change']
        for kind in ('secret','finished','member','group_name','group_member','group_pin','offset','percent'):
            value=source();value['books'][0]['secret']=1;progress=point()
            if kind=='secret':value['books'][1]['secret']=0
            elif kind=='finished':value['books'][1]['finishReading']=0
            elif kind=='member':value['books'].pop()
            elif kind=='group_name':value['archive'][0]['name']='Changed'
            elif kind=='group_member':value['archive'][0]['bookIds'].pop()
            elif kind=='group_pin':value['archive'][0]['isTop']=1
            elif kind=='offset':progress['book']['chapterOffset']+=1
            else:progress['book']['progress']+=.00001
            with self.subTest(kind=kind):self.assertFalse(check(value,progress,p))
    def test_group_and_book_order_do_not_change_meaning(self):
        value=source();value['books'].reverse();value['archive'][0]['bookIds'].reverse()
        self.assertEqual(state_hash(value),state_hash(source()))
    def test_invalid_fields_are_not_coerced(self):
        for value in (True,None,'bad',0):
            with self.subTest(value=value),self.assertRaises(ValueError):request('private',value,True)
        for value in (1,0,'1',None):
            with self.subTest(desired=value),self.assertRaises(ValueError):request('private','41',value)
        value=source();value['books'][1]['secret']=2
        with self.assertRaises(ValueError):make(value,point(),'41','private',True)
    def test_unstarted_zero_position_must_be_exact(self):
        value=dict(book=dict(bookId='41',chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0))
        self.assertEqual(position(value,'41')['chapter_uid'],'0')
        self.assertTrue(valid_metadata(make(source(),value,'41','private',True)['metadata']))
        value['book']['chapterOffset']=1
        with self.assertRaises(ValueError):position(value,'41')
    def test_private_trial_rejects_originally_private_or_mutated_scope(self):
        for field in ('before','desired','book_id','kind','request_hash'):
            value=plan();value['change'][field]={'before':True,'desired':False,'book_id':'42','kind':'pinned','request_hash':'a'*64}[field]
            with self.subTest(field=field),self.assertRaises(StoreError):validate_plan(value)
    def test_prepared_claims_and_retirement_cannot_be_replayed(self):
        store=FlagTrialStore(Backend());r=store.reserve(plan());self.assertTrue(store.pending())
        for before,after in [('prepared','change_pending'),('change_pending','change_verified'),('change_verified','restore_pending'),('restore_pending','retired')]:
            old=r;r=store.advance(r,before,after)
            with self.assertRaises(StoreError):store.advance(old,before,after)
        self.assertFalse(store.pending());self.assertEqual(store.read()[0]['posts'],2)
        with self.assertRaises(StoreError):store.reserve(plan())
    def test_unknown_pending_cannot_skip_to_restore(self):
        store=FlagTrialStore(Backend());r=store.reserve(plan());r=store.advance(r,'prepared','change_pending')
        with self.assertRaises(StoreError):store.advance(r,'change_pending','restore_pending')
        self.assertTrue(store.pending())
    def test_store_readback_failure_prevents_claim(self):
        class Bad(Backend):
            def save(self,data):self.data=b'corrupt'
        with self.assertRaises(StoreError):FlagTrialStore(Bad()).reserve(plan())
    def test_only_the_bound_private_request_can_dispatch(self):
        probe=task.Probe();probe.target='41';probe.grant=task.digest(credentials());claimed=[];probe.dispatch=lambda:claimed.append(True)
        with patch.object(task.NativeProbe,'request',return_value=dict(succ=1)) as network:
            for url,body in [('https://example.org/book/secret',request('private','41',True)),(task.BASE+'/book/secret',request('private','42',True)),(task.BASE+'/shelf/top',request('pinned','41',True))]:
                with self.subTest(url=url),self.assertRaises(ValueError):probe.request('write',url,body,credentials())
            network.assert_not_called();self.assertEqual(claimed,[])
            probe.request('write',task.BASE+'/book/secret',request('private','41',True),credentials())
            with self.assertRaises(ValueError):probe.request('write',task.BASE+'/book/secret',request('private','41',True),credentials())
            probe.request('write',task.BASE+'/book/secret',request('private','41',False),credentials())
            self.assertEqual(probe.posts,2);self.assertEqual(len(claimed),2)
            with self.assertRaises(ValueError):probe.request('write',task.BASE+'/book/secret',request('private','41',False),credentials())
    def test_lost_claim_or_grant_never_reaches_network(self):
        probe=task.Probe();probe.target='41';probe.grant=task.digest(credentials());probe.dispatch=lambda:(_i for _i in ()).throw(StoreError('synthetic claim failed'))
        with patch.object(task.NativeProbe,'request') as network,self.assertRaises(StoreError):probe.request('write',task.BASE+'/book/secret',request('private','41',True),credentials())
        network.assert_not_called();self.assertEqual(probe.posts,0)
        probe.grant='bad'
        with patch.object(task.NativeProbe,'request') as network,self.assertRaises(ValueError):probe.request('shelf',task.BASE+'/shelf/sync',credentials=credentials())
        network.assert_not_called()


if __name__=='__main__':unittest.main()
