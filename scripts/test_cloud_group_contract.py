"""Synthetic checks for bounded, empty-group-only trial planning."""
from copy import deepcopy
import unittest

from cloud_group_contract import acknowledged, create_request, created, delete_request, digest, inspect_closed, project, restored


def shelf():
    return {'books': [{'bookId': '42', 'title': 'Synthetic', 'finishReading': 0, 'secret': 0}],
            'archive': [{'archiveId': 2, 'name': 'Synthetic', 'bookIds': ['42'], 'albumIds': []}]}


class CloudGroupContractTest(unittest.TestCase):
    def setUp(self):
        self.name = 'KOReader-Test-' + 'a' * 24
        self.before = project(shelf())
        self.after = shelf()
        self.after['archive'].append({'archiveId': 42, 'name': self.name, 'bookIds': [], 'albumIds': []})

    def test_new_empty_group_and_restore(self):
        after = project(self.after)
        self.assertEqual(created(self.before, after, self.name, require_album_ids=True), '42')
        self.assertTrue(restored(self.before, project(shelf())))
        self.assertFalse(restored(self.before, after))
        self.assertEqual(create_request(self.name), {'bookIds': [], 'albumIds': [], 'archiveId': 0, 'name': self.name})
        self.assertEqual(delete_request('42'), {'archiveId': 42, 'removeBooks': 0})

    def test_target_and_receipt_are_strict(self):
        for name in ('Existing', 'KOReader-Test-a', 'KOReader-Test-' + 'A' * 24):
            with self.subTest(name=name), self.assertRaises(ValueError): create_request(name)
        for ident in ('1', '0', '-1', '01', '42/other', 42, '9007199254740992'):
            with self.subTest(ident=ident), self.assertRaises(ValueError): delete_request(ident)
        self.assertTrue(acknowledged({'succ': 1}))
        for reply in ({}, {'succ': True}, {'succ': 1, 'errcode': -1}, {'succ': 1, 'errcode': False},
                      {'succ': 1, 'errCode': 0.0}, {'succ': 1, 'success': False}):
            self.assertFalse(acknowledged(reply))

    def test_unrelated_change_or_nonempty_group_is_never_accepted(self):
        cases = []
        item = deepcopy(self.after); item['books'][0]['secret'] = 1; cases.append(item)
        item = deepcopy(self.after); item['archive'][0]['bookIds'] = []; cases.append(item)
        item = deepcopy(self.after); item['archive'][-1]['bookIds'] = ['42']; cases.append(item)
        item = deepcopy(self.after); item['archive'][-1]['albumIds'] = ['9']; cases.append(item)
        item = deepcopy(self.after); item['archive'][-1]['name'] = 'other'; cases.append(item)
        item = deepcopy(self.after); item['archive'].append({'archiveId': 43, 'name': 'other', 'bookIds': []}); cases.append(item)
        item = deepcopy(self.after); item['albums'] = []; cases.append(item)
        for item in cases:
            with self.subTest(case=len(cases)), self.assertRaises(ValueError): created(self.before, project(item), self.name)

    def test_rejects_duplicate_ids_and_unknown_members(self):
        item = shelf(); item['archive'].append(deepcopy(item['archive'][0]))
        with self.assertRaises(ValueError): project(item)
        item = shelf(); item['archive'][0]['bookIds'] = ['42', '42']
        with self.assertRaises(ValueError): project(item)
        item = shelf(); item['archive'][0]['albumIds'] = None
        with self.assertRaises(ValueError): project(item)
        item = deepcopy(self.after); item['archive'][-1].pop('albumIds')
        self.assertEqual(created(self.before, project(item), self.name), '42')
        with self.assertRaises(ValueError): created(self.before, project(item), self.name, require_album_ids=True)

    def test_read_only_inspection_binds_other_state_and_never_guesses(self):
        observed=inspect_closed(project(self.after),self.name,digest(self.before))
        self.assertTrue(observed['present'] and observed['other_state_unchanged'] and observed['empty_books'] and observed['empty_albums'])
        absent=inspect_closed(self.before,self.name,digest(self.before))
        self.assertFalse(absent['present']);self.assertTrue(absent['other_state_unchanged'])
        changed=deepcopy(self.after);changed['books'][0]['secret']=1
        self.assertFalse(inspect_closed(project(changed),self.name,digest(self.before))['other_state_unchanged'])


if __name__ == '__main__': unittest.main()
