import unittest
from copy import deepcopy
from unittest.mock import patch

from imported_pin_trial import request, sample
from imported_pin_audit_binding import create as create_binding
from test_imported_pin_audit_binding import Memory
from personal_upload_trial import hash_value
from test_imported_pin_trial import Intent
from verify_imported_pin_trial import execute, inspect


class AuditTest(unittest.TestCase):
    def setUp(self):
        self.saved = {'vid': '900000'}
        self.grant = {'vid': '900000', 'accessToken': 'synthetic', 'deviceId': 'synthetic-device'}
        self.shelf = {'books': [{'bookId': 'CB_abc', 'title': 'Synthetic', 'finishReading': 0, 'secret': 0}], 'archive': []}
        self.progress = {'book': {'bookId': 'CB_abc', 'chapterUid': 2, 'chapterIdx': 1,
                                  'chapterOffset': 4, 'progress': 15, 'updateTime': 10}}
        self.records = {'pin': Intent(), 'restore': Intent()}
        state = sample(lambda _id: {'native': deepcopy(self.shelf), 'web': deepcopy(self.shelf),
                                    'progress': deepcopy(self.progress)}, lambda: True, 'CB_abc')
        selection = {'owner': '900000', 'book_id': 'CB_abc', 'grant_hash': hash_value(self.grant)}
        for name in self.records:
            baseline = {'snapshot_hash': hash_value(state), 'native_hash': hash_value(state['native']),
                        'web_hash': hash_value(state['web']), 'progress_hash': state['progress_hash']}
            self.records[name].claim({'selection': deepcopy(selection), 'record': {'kind': name},
                                      'body': request('CB_abc', name == 'pin'), 'baseline': baseline})
        self.records['pin'].state['phase'] = 'verified'
        self.web = type('Web', (), {'request': lambda _self, *_args: deepcopy(self.shelf)})()
        owner = self
        class Probe:
            def request(self, stage, *_args, **_kwargs):
                return deepcopy(owner.progress if stage == 'progress' else owner.shelf)
        self.patches = [patch('verify_imported_pin_trial.NativeProbe', Probe),
                        patch('verify_imported_pin_trial.SessionStore', lambda: type('Store', (), {'load': lambda _: owner.saved})()),
                        patch('verify_imported_pin_trial.NativeSessionStore', lambda: type('Store', (), {'load': lambda _, _vid: owner.grant})())]
        for item in self.patches: item.start();self.addCleanup(item.stop)
    def test_independent_read_only_audit(self):
        result = inspect(self.saved, self.grant, self.web, self.records)
        self.assertEqual(result['result'], 'READ_ONLY_INSPECTED')
        self.assertTrue(result['matches_original_snapshot'])
        self.assertEqual(result['original_components_match'], {'native': True, 'web': True, 'progress': True})
        self.assertEqual(self.records['pin'].state['phase'], 'verified')
    def test_distinguishes_progress_change(self):
        self.progress['book']['chapterOffset'] = 5
        result = inspect(self.saved, self.grant, self.web, self.records)
        self.assertFalse(result['matches_original_snapshot'])
        self.assertEqual(result['original_components_match'], {'native': True, 'web': True, 'progress': False})
    def test_rejects_rebound_target_or_account(self):
        self.records['restore'].state['plan']['selection']['book_id'] = 'CB_other'
        with self.assertRaises(ValueError): inspect(self.saved, self.grant, self.web, self.records)
    def test_renewed_grant_needs_matching_audit_binding(self):
        backend=Memory();pin=self.records['pin'].state;restore=self.records['restore'].state
        create_binding('900000',self.grant,pin,restore,backend)
        self.grant=dict(self.grant,accessToken='renewed')
        with self.assertRaises(ValueError): inspect(self.saved,self.grant,self.web,self.records)
        self.assertEqual(inspect(self.saved,self.grant,self.web,self.records,backend)['result'],'READ_ONLY_INSPECTED')
        self.grant=dict(self.grant,deviceId='other-device')
        with self.assertRaises(ValueError): inspect(self.saved,self.grant,self.web,self.records,backend)
    def test_guarded_execution_and_consumed_record(self):
        owner=self;sent=[]
        class Probe:
            def request(self,stage,url,body=None,credentials=None):
                if stage=='pin_write':
                    self_kind='pin' if body['isDel']==0 else 'restore'
                    assert url.endswith('/shelf/top') and body==request('CB_abc',self_kind=='pin')
                    assert credentials==owner.grant;sent.append(self_kind)
                    if self_kind=='pin':owner.shelf['books'][0]['isTop']=1
                    else:owner.shelf['books'][0].pop('isTop',None)
                    return {'succ':1}
                return deepcopy(owner.progress if stage in ('progress','candidate_progress') else owner.shelf)
        records={'pin':Intent(),'restore':Intent()}
        with patch('verify_imported_pin_trial.NativeProbe',Probe),patch('verify_imported_pin_trial.other_pending',return_value=False):
            self.assertEqual(execute(self.saved,self.grant,self.web,records)['result'],'READ_ONLY_PREVIEW')
            self.assertEqual(sent,[])
            self.assertEqual(execute(self.saved,self.grant,self.web,records,apply=True)['result'],'PASS')
            self.assertEqual(sent,['pin','restore'])
            self.assertEqual(execute(self.saved,self.grant,self.web,records,apply=True)['result'],'UNVERIFIED')
            self.assertEqual(sent,['pin','restore'])


if __name__ == '__main__': unittest.main()
