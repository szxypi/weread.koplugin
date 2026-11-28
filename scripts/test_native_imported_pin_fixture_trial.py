import unittest
from copy import deepcopy

from native_direct_time_trial_store import Intent
from native_imported_pin_fixture_trial import run
from test_personal_upload_trial import TARGET, source
from test_secure_native_session import Backend, credentials


class TrialTests(unittest.TestCase):
    def setUp(self):
        self.grant=credentials();self.shelf=source();self.shelf['books'].append({'bookId':TARGET,'title':'Synthetic','finishReading':0})
        self.progress={'book':{'bookId':TARGET,'chapterUid':0,'chapterIdx':0,'chapterOffset':0,'progress':0,'updateTime':10}}
        self.records={name:Intent(backend=Backend()) for name in ('pin','restore')}
        self.armed=False;self.posts=0;self.mode='normal'
    def observe(self,_identity):return {'native':deepcopy(self.shelf),'web':deepcopy(self.shelf),'progress':deepcopy(self.progress)}
    def arm(self):self.assertFalse(self.armed);self.armed=True
    def child(self,payload,_command,*,armed,on_step):
        self.assertEqual(payload['book_id'],TARGET)
        if not armed:
            if self.mode=='dry_failure':raise ValueError('dry failed')
            return {'result':'PASS'},0
        self.assertTrue(self.armed);self.assertEqual(self.records['pin'].read()[0]['phase'],'claimed')
        self.posts+=1;self.shelf['books'][-1]['isTop']=1
        if self.mode=='lost_first':raise ValueError('lost receipt')
        if self.mode=='progress_changed':self.progress['book']['chapterOffset']=1
        on_step(1)
        self.assertEqual(self.records['pin'].read()[0]['phase'],'verified')
        self.assertEqual(self.records['restore'].read()[0]['phase'],'claimed')
        self.posts+=1;self.shelf['books'][-1].pop('isTop')
        if self.mode=='lost_second':raise ValueError('lost receipt')
        on_step(2)
        return {'result':'PASS'},2
    def trial(self):
        return run(self.grant,TARGET,self.observe(TARGET),self.observe,lambda:True,self.records,
                   {'bookId':TARGET,'title':'Synthetic'},['synthetic'],self.arm,child=self.child,sleep=lambda _s:None)
    def test_success_requires_two_readbacks_and_claims(self):
        result=self.trial();self.assertEqual(result['result'],'PASS');self.assertEqual(self.posts,2)
        self.assertEqual(result['independent_steps'],2);self.assertEqual(result['native_posts_attempted'],2)
        self.assertEqual(self.records['restore'].read()[0]['phase'],'verified')
        self.assertEqual(self.trial()['result'],'UNVERIFIED');self.assertEqual(self.posts,2)
    def test_dry_failure_never_arms_or_claims(self):
        self.mode='dry_failure';result=self.trial()
        self.assertEqual(result['result'],'UNVERIFIED');self.assertFalse(self.armed);self.assertEqual(self.posts,0)
        self.assertIsNone(self.records['pin'].read()[0])
    def test_unconfirmed_or_changed_state_stops_without_replay(self):
        for mode,posts,pin_phase,restore_phase in (('lost_first',1,'claimed',None),('progress_changed',1,'claimed',None),
                                                   ('lost_second',2,'verified','claimed')):
            with self.subTest(mode=mode):
                self.setUp();self.mode=mode;result=self.trial()
                self.assertEqual(result['result'],'UNVERIFIED');self.assertIsNone(result['native_posts_attempted'])
                self.assertEqual(self.posts,posts);self.assertEqual(self.records['pin'].read()[0]['phase'],pin_phase)
                record=self.records['restore'].read()[0];self.assertEqual(record['phase'] if record else None,restore_phase)
                self.assertEqual(self.trial()['result'],'UNVERIFIED');self.assertEqual(self.posts,posts)


if __name__=='__main__':unittest.main()
