"""Offline boundary checks for a new imported-book selection."""
from copy import deepcopy
import unittest

from cb_fixture_selection_trial import Intent,execute,prepare
from test_cb_fixture_highlight_trial import fixture
from test_secure_native_session import Backend


class Fake:
    def __init__(self,baseline,*,associated=False,auto_remove=False,fail=None,unrelated=False):
        self.original=deepcopy(baseline);self.value=deepcopy(baseline);self.associated=associated
        self.auto_remove=auto_remove;self.fail=fail;self.unrelated=unrelated;self.sent=[]
    def owned(self):return True
    def read(self):return deepcopy(self.value)
    def thought(self,step,body,_receipt):
        self.sent.append('thought'+str(step))
        if step==1:
            self.value['thoughts']['new']=dict(body,reviewId='new')
            if self.associated:self.value['marks']['updated']['associated']=dict(bookmarkId='associated',type=1,
                chapterUid=int(body['chapterUid']),range=body['range'],markText=body['abstract'])
            if self.unrelated:self.value['marks']['updated']['foreign']={'bookmarkId':'foreign'}
        elif step==2:self.value['thoughts']['new']['content']=body['content']
        else:
            self.value['thoughts'].pop('new')
            if self.auto_remove:self.value['marks']['updated'].pop('associated',None)
        if self.fail=='thought'+str(step):raise RuntimeError('unknown effect')
    def cleanup(self,body,_receipt):
        self.sent.append('cleanup');assert body=={'bookmarkIds':['associated']}
        self.value['marks']['updated'].pop('associated')
        if self.fail=='cleanup':raise RuntimeError('unknown effect')


def case(**kwargs):
    sample,baseline,_old,_body=fixture();plan,context,body=prepare('900000','CB_Synthetic42','a'*32,sample,1,baseline,'b'*32)
    fake=Fake(baseline,**kwargs);intent=Intent(Backend())
    def run():return execute(plan,context,body,baseline,intent,fake.owned,fake.read,fake.thought,fake.cleanup,sleep=lambda _n:None)
    return fake,intent,run


class SelectionTests(unittest.TestCase):
    def test_thought_and_optional_associated_mark_lifecycles(self):
        for associated,auto_remove,cleanup in ((False,False,0),(True,False,1),(True,True,0)):
            with self.subTest(associated=associated,auto_remove=auto_remove):
                fake,intent,run=case(associated=associated,auto_remove=auto_remove);result=run()
                self.assertEqual(result['result'],'PASS');self.assertEqual(result['cleanup_writes'],cleanup)
                self.assertEqual(result['associated_highlight_observed'],associated)
                self.assertEqual(fake.value,fake.original);self.assertEqual(intent.read(),(None,None))
                self.assertEqual(fake.sent,['thought1','thought2','thought3']+(['cleanup'] if cleanup else []))

    def test_unknown_effect_is_durable_and_cannot_replay(self):
        for index,phase in enumerate(('thought1','thought2','thought3','cleanup')):
            with self.subTest(phase=phase):
                fake,intent,run=case(associated=True,fail=phase)
                with self.assertRaises(RuntimeError):run()
                self.assertEqual(fake.sent,['thought1','thought2','thought3','cleanup'][:index+1])
                self.assertEqual(intent.read()[0]['phase'],'pending')
                with self.assertRaises(ValueError):run()
                self.assertEqual(len(fake.sent),index+1)

    def test_unrelated_mark_stops_before_edit(self):
        fake,intent,run=case(unrelated=True)
        with self.assertRaises(ValueError):run()
        self.assertEqual(fake.sent,['thought1']);self.assertEqual(intent.read()[0]['native_steps'],0)

    def test_changed_original_or_source_blocks_before_dispatch(self):
        fake,intent,run=case();fake.value['position']['chapter']='different'
        with self.assertRaises(ValueError):run()
        self.assertEqual(fake.sent,[]);self.assertEqual(intent.read(),(None,None))
        sample,baseline,_old,_body=fixture();sample['source']+='changed'
        with self.assertRaises(ValueError):prepare('900000','CB_Synthetic42','a'*32,sample,1,baseline,'b'*32)


if __name__=='__main__':unittest.main()
