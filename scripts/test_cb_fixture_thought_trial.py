"""Offline model, intent and failure-boundary tests for a fresh CB fixture."""
from copy import deepcopy
import unittest

from cb_fixture_highlight_trial import Intent as SeedIntent
from cb_fixture_thought_trial import ThoughtIntent,execute
from test_cb_fixture_highlight_trial import fixture
from test_secure_native_session import Backend


class Fake:
    def __init__(self,baseline,fail=None,change=None):
        self.original=deepcopy(baseline);self.value=deepcopy(baseline);self.fail=fail;self.change=change;self.sent=[]
    def owned(self):return True
    def read(self):return deepcopy(self.value)
    def seed(self,phase,body,_receipt):
        self.sent.append('seed_'+phase)
        if phase=='create_pending':self.value['marks']['updated']['seed']=dict(body,bookmarkId='seed')
        else:self.value['marks']['updated'].pop('seed')
        if self.fail=='seed_'+phase:raise RuntimeError('unknown effect')
    def thought(self,phase,body,_receipt):
        self.sent.append('thought_'+phase)
        if phase=='create_pending':self.value['thoughts']['new']=dict(body,reviewId='new')
        elif phase=='edit_pending':self.value['thoughts']['new']['content']=body['content']
        else:self.value['thoughts'].pop('new')
        if self.change==phase:self.value['marks']['updated']['seed']['style']=2
        if self.fail=='thought_'+phase:raise RuntimeError('unknown effect')


def case(*,fail=None,change=None):
    sample,baseline,_plan,_body=fixture();fake=Fake(baseline,fail,change)
    seed=SeedIntent(Backend());thought=ThoughtIntent(Backend())
    def run():return execute('900000','CB_Synthetic42','a'*32,sample,1,baseline,seed,thought,
        fake.owned,fake.read,fake.seed,fake.thought,nonce='b'*32,sleep=lambda _n:None)
    return fake,seed,thought,run


class FixtureThoughtTests(unittest.TestCase):
    def test_five_ordered_writes_and_independent_restore(self):
        fake,seed,thought,run=case();result=run()
        self.assertEqual(fake.sent,['seed_create_pending','thought_create_pending','thought_edit_pending',
                                    'thought_delete_pending','seed_delete_pending'])
        self.assertEqual(result,dict(result='PASS',seed_writes=2,thought_writes=3,original_records_restored=True))
        self.assertEqual(fake.value,fake.original);self.assertEqual(seed.read(),(None,None));self.assertEqual(thought.read(),(None,None))

    def test_unknown_effect_never_replays_or_deletes_fixture_seed(self):
        stages=['seed_create_pending','thought_create_pending','thought_edit_pending','thought_delete_pending','seed_delete_pending']
        for index,stage in enumerate(stages):
            fake,seed,thought,run=case(fail=stage)
            with self.subTest(stage=stage),self.assertRaises(RuntimeError):run()
            self.assertEqual(fake.sent,stages[:index+1]);self.assertTrue(seed.read()[0] or thought.read()[0])
            with self.assertRaises(ValueError):run()
            self.assertEqual(fake.sent,stages[:index+1])

    def test_changed_seed_during_thought_stops_before_next_write(self):
        fake,seed,thought,run=case(change='create_pending')
        with self.assertRaises(ValueError):run()
        self.assertEqual(fake.sent,['seed_create_pending','thought_create_pending'])
        self.assertEqual(seed.read()[0]['phase'],'created');self.assertEqual(thought.read()[0]['phase'],'create_pending')

    def test_original_state_changes_are_rejected_before_writing(self):
        fake,seed,thought,run=case();fake.value['thoughts']['foreign']={}
        with self.assertRaises(ValueError):run()
        self.assertEqual(fake.sent,[]);self.assertEqual(seed.read(),(None,None));self.assertEqual(thought.read(),(None,None))


if __name__=='__main__':unittest.main()
