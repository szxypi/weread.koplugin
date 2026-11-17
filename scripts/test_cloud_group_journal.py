"""The temporary cloud-group trial cannot replay a claimed operation."""
import unittest

from cloud_group_journal import Journal
from cloud_group_contract import digest
from secure_weread_session import StoreError


class Memory:
    def __init__(self): self.value = None; self.fail_readback = False; self.fail_next_save = False
    def load(self): return b'changed' if self.fail_readback and self.value else self.value
    def save(self, raw):
        self.value = raw
        if self.fail_next_save: self.fail_next_save = False; self.fail_readback = True


class GroupJournalTest(unittest.TestCase):
    def setUp(self):
        self.backend = Memory(); self.journal = Journal(backend=self.backend)
        self.args = ('42', 'a' * 64, 'KOReader-Test-' + 'b' * 24, 'c' * 64, 'd' * 64)

    def test_success_never_resets_scope(self):
        token = self.journal.begin(*self.args)
        token = self.journal.advance(token, 'create_claimed')
        with self.assertRaises(StoreError): self.journal.advance(token, 'create_claimed')
        token = self.journal.advance(token, 'created', group_id_value='42')
        token = self.journal.advance(token, 'delete_claimed')
        token = self.journal.advance(token, 'restored')
        self.assertEqual(self.journal.read()[0]['phase'], 'restored')
        with self.assertRaises(StoreError): self.journal.begin(*self.args)
        with self.assertRaises(StoreError): self.journal.advance(token, 'delete_claimed')

    def test_uncertain_create_or_delete_cannot_be_reclaimed(self):
        old = self.journal.begin(*self.args)
        claimed = self.journal.advance(old, 'create_claimed')
        with self.assertRaises(StoreError): self.journal.advance(old, 'create_claimed')
        with self.assertRaises(StoreError): self.journal.advance(claimed, 'delete_claimed')
        created = self.journal.advance(claimed, 'created', group_id_value='42')
        delete_claimed = self.journal.advance(created, 'delete_claimed')
        with self.assertRaises(StoreError): self.journal.advance(created, 'delete_claimed')
        with self.assertRaises(StoreError): self.journal.begin(*self.args)
        self.assertEqual(self.journal.read()[1], delete_claimed)

    def test_rejected_create_is_terminal_and_invalid_ids_rejected(self):
        token = self.journal.advance(self.journal.begin(*self.args), 'create_claimed')
        with self.assertRaises(StoreError): self.journal.advance(token, 'created', group_id_value='1')
        token = self.journal.advance(token, 'rejected_unchanged')
        with self.assertRaises(StoreError): self.journal.advance(token, 'created', group_id_value='42')
        with self.assertRaises(StoreError): self.journal.begin(*self.args)

    def test_write_readback_failure_never_grants_claim(self):
        token = self.journal.begin(*self.args)
        self.backend.fail_next_save = True
        with self.assertRaises(StoreError): self.journal.advance(token, 'create_claimed')
        self.backend.fail_readback = False
        self.assertEqual(self.journal.read()[0]['phase'], 'create_claimed')
        with self.assertRaises(StoreError): self.journal.advance(token, 'create_claimed')

    def test_uncertain_scope_can_be_closed_only_with_two_unchanged_observations(self):
        native={'groups':{},'members':['42'],'flags':'n','albums':{'present':True,'value':[]}}
        web={'groups':{},'members':['42'],'flags':'w','albums':{'present':False}}
        args=('42','a'*64,self.args[2],digest(native),digest(web))
        token=self.journal.advance(self.journal.begin(*args),'create_claimed')
        changed={'groups':{'2':{'name':'other'}},'members':['42'],'flags':'n','albums':{'present':True,'value':[]}}
        with self.assertRaises(StoreError):self.journal.close_unchanged(token,[(native,web),(changed,web)])
        self.assertEqual(self.journal.read()[0]['phase'],'create_claimed')
        closed=self.journal.close_unchanged(token,[(native,web),(native,web)])
        self.assertEqual(self.journal.read()[0]['phase'],'closed_unverified')
        with self.assertRaises(StoreError):self.journal.begin(*args)
        with self.assertRaises(StoreError):self.journal.advance(closed,'created',group_id_value='42')


if __name__ == '__main__': unittest.main()
