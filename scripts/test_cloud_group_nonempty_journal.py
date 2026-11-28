"""A group intent is single use and binds the exact imported fixture."""
import unittest

from cloud_group_nonempty_journal import Journal, SERVICE
from cloud_group_journal import SERVICE as EMPTY_SERVICE
from secure_weread_session import StoreError
from test_secure_native_session import Backend


def plan():
    return dict(owner='123456', grant_hash='a'*64, name='KOReader-Test-'+'a'*24, target='CB_SyntheticOnly',
                upload_attempt='b'*32, upload_plan_hash='c'*64, native_before='d'*64, web_before='e'*64)


class NonemptyJournalTest(unittest.TestCase):
    def test_transitions_are_single_use_and_stale_tokens_fail(self):
        self.assertNotEqual(SERVICE, EMPTY_SERVICE)
        journal = Journal(Backend()); initial = journal.begin(**plan())
        with self.assertRaises(StoreError): journal.begin(**plan())
        claimed = journal.advance(initial, 'create_claimed')
        with self.assertRaises(StoreError): journal.advance(initial, 'create_claimed')
        with self.assertRaises(StoreError): journal.advance(claimed, 'delete_claimed')
        with self.assertRaises(StoreError): journal.advance(claimed, 'created', group_id_value='43')
        claimed = journal.claim_dispatch(claimed, 'create_claimed')
        with self.assertRaises(StoreError): journal.claim_dispatch(claimed, 'create_claimed')
        with self.assertRaises(StoreError): journal.advance(claimed, 'created', group_id_value='1')
        created = journal.advance(claimed, 'created', group_id_value='43')
        deletion = journal.advance(created, 'delete_claimed')
        deletion = journal.claim_dispatch(deletion, 'delete_claimed')
        journal.advance(deletion, 'restored')
        self.assertEqual(journal.read()[0]['phase'], 'restored')
        with self.assertRaises(StoreError): journal.begin(**plan())

    def test_invalid_bindings_never_reserve(self):
        for key, bad in (('target', '42'), ('upload_attempt', 'bad'), ('upload_plan_hash', 'bad'),
                         ('owner', '0'), ('grant_hash', 'bad'), ('name', 'Existing')):
            journal = Journal(Backend()); values = plan(); values[key] = bad
            with self.subTest(key=key), self.assertRaises(StoreError): journal.begin(**values)
            self.assertIsNone(journal.read()[0])


if __name__ == '__main__': unittest.main()
