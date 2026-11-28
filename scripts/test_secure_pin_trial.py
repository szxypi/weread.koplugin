import copy
import unittest
from contextlib import nullcontext
from unittest.mock import patch

from native_shelf_trial import bind
from secure_pin_trial import PHASES,PinTrialStore,validate,SERVICE,SERVICE_V2,SERVICE_V3
from secure_shelf_experiment import ShelfExperimentStore,StoreError
from verify_owner_shelf_membership import members_digest


class Backend:
    def __init__(self):self.data=None
    def load(self):return self.data
    def save(self,data):self.data=data
    def delete(self):self.data=None


def plans():
    shelf={'books':[{'bookId':'41','title':'Synthetic book','secret':0,'finishReading':0}],'archive':[]}
    membership={'owner':'123','book_id':'42','members_sha256':members_digest({'41':{}}),'grant_sha256':'a'*64}
    plan=bind(membership,shelf)
    return {key:copy.deepcopy(plan) for key in ('native','web','gateway')}


class PinTrialTests(unittest.TestCase):
    def test_single_sequence_and_persistent_consumption(self):
        backend=Backend();store=PinTrialStore(backend);state,raw=store.reserve(plans(),'b'*64,'c'*64)
        self.assertTrue(store.pending())
        for phase in PHASES[1:]:
            previous=raw;state,raw=store.advance(raw,phase)
            self.assertEqual(state['phase'],phase)
            with self.assertRaises(StoreError):store.advance(previous,phase)
            self.assertEqual(PinTrialStore(backend).read()[0]['phase'],phase)
        self.assertFalse(store.pending())
        with self.assertRaises(StoreError):store.reserve(plans(),'b'*64,'c'*64)
        self.assertEqual(store.read()[0]['phase'],'restored')

    def test_partial_or_skipped_stage_cannot_resume(self):
        backend=Backend();store=PinTrialStore(backend);_,raw=store.reserve(plans(),'b'*64,'c'*64)
        with self.assertRaises(StoreError):store.advance(raw,'pin_pending')
        _,raw=store.advance(raw,'add_pending')
        restarted=PinTrialStore(backend)
        self.assertTrue(restarted.pending())
        with self.assertRaises(StoreError):restarted.reserve(plans(),'b'*64,'c'*64)
        with self.assertRaises(StoreError):restarted.advance(raw,'pin_pending')

    def test_cross_account_and_tampered_records_rejected(self):
        mismatched=plans();mismatched['web']['membership']['owner']='456'
        with self.assertRaises(StoreError):PinTrialStore(Backend()).reserve(mismatched,'b'*64,'c'*64)
        for key,bad in (('progress_sha256','x'),('skill_sha256','x'),('phase','other')):
            backend=Backend();store=PinTrialStore(backend);value,_=store.reserve(plans(),'b'*64,'c'*64)
            value[key]=bad
            with self.subTest(key=key),self.assertRaises(StoreError):validate(value)

    def test_shelf_experiments_stop_while_pin_trial_pending(self):
        with patch('secure_pin_trial.PinTrialStore') as trial:
            shelf=ShelfExperimentStore(Backend(),lock=nullcontext);shelf.check_pin_trial=True
            trial.return_value.pending.return_value=True
            self.assertTrue(shelf.pending())
            with self.assertRaises(StoreError):shelf.begin(plans()['native']['membership'])
            trial.return_value.pending.return_value=False
            self.assertFalse(shelf.pending())
            shelf.begin(plans()['native']['membership'])
            self.assertTrue(shelf.pending())

    def test_v2_pending_blocks_other_shelf_trials(self):
        with patch('secure_pin_trial.PinTrialStore') as trial:
            trial.side_effect=lambda *,service: type('Fake',(),{'pending':lambda _self:service==SERVICE_V2})()
            shelf=ShelfExperimentStore(Backend(),lock=nullcontext);shelf.check_pin_trial=True
            self.assertTrue(shelf.pending())
            self.assertEqual([call.kwargs['service'] for call in trial.call_args_list],[SERVICE,SERVICE_V2])
            with self.assertRaises(StoreError):shelf.begin(plans()['native']['membership'])

    def test_v3_pending_blocks_other_shelf_trials(self):
        with patch('secure_pin_trial.PinTrialStore') as trial:
            trial.side_effect=lambda *,service: type('Fake',(),{'pending':lambda _self:service==SERVICE_V3})()
            shelf=ShelfExperimentStore(Backend(),lock=nullcontext);shelf.check_pin_trial=True
            self.assertTrue(shelf.pending())
            self.assertEqual([call.kwargs['service'] for call in trial.call_args_list],[SERVICE,SERVICE_V2,SERVICE_V3])
            with self.assertRaises(StoreError):shelf.begin(plans()['native']['membership'])


if __name__=='__main__':unittest.main()
