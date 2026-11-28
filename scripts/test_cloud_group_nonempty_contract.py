"""Reject changes to any state outside a single self-authored fixture."""
from copy import deepcopy
import unittest

from cloud_group_contract import project
from cloud_group_nonempty_contract import create_request, created, restored


TARGET = 'CB_SyntheticOnly'
NAME = 'KOReader-Test-' + 'a' * 24


def source():
    return {'books': [{'bookId': '42', 'title': 'Synthetic', 'finishReading': 0},
                      {'bookId': TARGET, 'title': 'Fixture', 'finishReading': 0}],
            'archive': [{'archiveId': 2, 'name': 'Existing', 'bookIds': ['42', TARGET], 'albumIds': ['9']}],
            'albums': [{'albumId': '9'}]}


class NonemptyGroupContractTest(unittest.TestCase):
    def setUp(self):
        self.before = project(source())
        self.after = source()
        self.after['archive'][0]['bookIds'].remove(TARGET)
        self.after['archive'].append({'archiveId': 43, 'name': NAME, 'bookIds': [TARGET], 'albumIds': []})

    def test_create_and_restore_allow_only_fixture_movement(self):
        self.assertEqual(create_request(NAME, TARGET)['bookIds'], [TARGET])
        self.assertEqual(created(self.before, project(self.after), NAME, TARGET, require_album_ids=True), '43')
        deleted = deepcopy(self.after); deleted['archive'].pop()
        self.assertTrue(restored(self.before, project(deleted), TARGET))
        self.assertFalse(restored(self.before, project(self.after), TARGET))

    def test_invalid_fixture_and_changed_user_data_are_rejected(self):
        for target in ('42', 'CB_', 'CB_bad/other', None):
            with self.subTest(target=target), self.assertRaises(ValueError): create_request(NAME, target)
        cases = []
        item = deepcopy(self.after); item['books'][0]['finishReading'] = 1; cases.append(item)
        item = deepcopy(self.after); item['archive'][0]['bookIds'] = []; cases.append(item)
        item = deepcopy(self.after); item['archive'][0]['albumIds'] = []; cases.append(item)
        item = deepcopy(self.after); item['albums'] = []; cases.append(item)
        item = deepcopy(self.after); item['archive'][-1]['bookIds'].append('42'); cases.append(item)
        item = deepcopy(self.after); item['archive'][-1]['albumIds'] = ['9']; cases.append(item)
        item = deepcopy(self.after); item['archive'][-1]['name'] = 'Other'; cases.append(item)
        item = deepcopy(self.after); item['archive'][-1].pop('albumIds'); cases.append(item)
        item = deepcopy(self.after); item['archive'].append({'archiveId': 44, 'name': 'Other', 'bookIds': []}); cases.append(item)
        for item in cases:
            with self.subTest(item=item), self.assertRaises(ValueError):
                created(self.before, project(item), NAME, TARGET, require_album_ids=True)

    def test_missing_target_or_reused_name_cannot_be_baseline(self):
        absent = source(); absent['books'].pop()
        with self.assertRaises(ValueError): created(project(absent), project(self.after), NAME, TARGET)
        collision = source(); collision['archive'][0]['name'] = NAME
        with self.assertRaises(ValueError): created(project(collision), project(self.after), NAME, TARGET)


if __name__ == '__main__': unittest.main()
