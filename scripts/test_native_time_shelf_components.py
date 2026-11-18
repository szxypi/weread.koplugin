"""Shelf fingerprints identify field changes without retaining account data."""
from copy import deepcopy
import unittest

from cloud_group_contract import project
from native_time_shelf_components import compare,make,validate
from test_cloud_group_nonempty_contract import source
from txt_full_summary import digest


class ShelfComponentTests(unittest.TestCase):
    def test_fields_are_hashed_and_original_data_is_not_retained(self):
        value=project(source());stamp=make(value);validate(stamp,digest(value))
        for secret in ('Synthetic','Fixture','CB_SyntheticOnly',"'42'"):
            self.assertNotIn(secret,repr(stamp))
        self.assertEqual(compare(stamp,make(deepcopy(value))),dict(members_changed=False,flags_changed=False,
            albums_changed=False,groups_added_or_removed=False,group_fields_changed=[],other_group_fields_changed=False))

    def test_non_ascii_group_names_use_the_same_projection_hash_as_preflight(self):
        value=project(source());value['groups']['2']['name']='合成分组😀'
        stamp=make(value);self.assertEqual(stamp['projection'],digest(value));validate(stamp,digest(value))
        self.assertNotIn('合成分组',repr(stamp))

    def test_one_group_field_change_is_reported_without_identity_or_value(self):
        value=project(source());value['groups']['2']['updateTime']=1;old=make(value)
        changed=deepcopy(value);changed['groups']['2']['updateTime']=2;delta=compare(old,make(changed))
        self.assertEqual(delta['group_fields_changed'],['updateTime'])
        self.assertFalse(delta['groups_added_or_removed']);self.assertFalse(delta['members_changed'])
        self.assertNotIn('Synthetic',repr(delta));self.assertNotIn('CB_SyntheticOnly',repr(delta))

    def test_independent_components_and_unknown_fields_remain_distinct(self):
        value=project(source());old=make(value)
        for mode in ('members','flags','albums','group','unknown'):
            changed=deepcopy(value)
            if mode=='members':changed['members'].append('900003')
            elif mode=='flags':changed['flags']='a'*64
            elif mode=='albums':changed['albums']['present']=False
            elif mode=='group':changed['groups'].pop('2')
            else:changed['groups']['2']['unexpectedMetadata']='synthetic'
            stamp=make(changed);delta=compare(old,stamp)
            if mode=='unknown':self.assertNotIn('unexpectedMetadata',repr(stamp))
            key={'members':'members_changed','flags':'flags_changed','albums':'albums_changed',
                 'group':'groups_added_or_removed','unknown':'other_group_fields_changed'}[mode]
            with self.subTest(mode=mode):self.assertTrue(delta[key])

    def test_malformed_and_oversized_components_are_not_accepted(self):
        value=project(source());stamp=make(value)
        for mode in ('hash','field_hash','unknown_field','projection'):
            item=deepcopy(stamp)
            if mode=='hash':item['flags']='bad'
            elif mode=='field_hash':next(iter(item['groups'].values()))['name']='bad'
            elif mode=='unknown_field':item['extra']='bad'
            else:item['projection']='a'*64
            with self.subTest(mode=mode),self.assertRaises(ValueError):validate(item,digest(value))
        value['groups']['2']['unsafe field']='private';self.assertIsNone(make(value))
        value=project(source());value['groups']={str(i):{'name':'x','bookIds':[]} for i in range(300)}
        self.assertIsNone(make(value))


if __name__=='__main__':unittest.main()
