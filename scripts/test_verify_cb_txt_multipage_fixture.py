import contextlib
import io
import json
import unittest
from unittest.mock import patch

from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend, credentials
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_multipage_fixture as task


class MultiPageFixtureTests(unittest.TestCase):
    def prior(self,i):
        return lambda:({'target':'CB_prior'+str(i),'plan':{'owner':credentials()['vid']}},'token'+str(i),b'receipt')

    def test_fixture_has_one_marker_and_no_private_source(self):
        self.assertEqual(task.BODY.count(task.MARKER.encode()),1)
        self.assertTrue(4000<len(task.BODY)<10000)

    def test_offline_default_never_loads_session(self):
        with patch.object(task,'SessionStore',side_effect=AssertionError('opened')),contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_scoped_roundtrip_preserves_prior_and_is_nonreplayable(self):
        journal=task.Journal(Backend());receipt=Receipt(Backend());probe=FakeProbe()
        class Group:
            def read(self):return {'target':'CB_oldgroup'},'token'
        priors=tuple(self.prior(i) for i in range(4))
        with patch.object(task,'GroupJournal',Group):
            result=task.execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,priors,
                                apply=True,sleep=lambda _:None,now=lambda:1000)
            self.assertEqual(result['result'],'TXT_IMPORT_AND_SOURCE_VERIFIED')
            self.assertEqual(journal.read()[0]['phase'],'restored')
            self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
            with self.assertRaises(ValueError):
                task.execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,priors,apply=True)

    def test_prior_or_group_collision_never_cleans(self):
        for collision in ('prior','group'):
            journal=task.Journal(Backend());receipt=Receipt(Backend());probe=FakeProbe()
            priors=list(self.prior(i) for i in range(4))
            if collision=='prior':priors[2]=lambda:({'target':'CB_synthetic123','plan':{'owner':credentials()['vid']}},'token',b'receipt')
            class Group:
                def read(self):return {'target':'CB_synthetic123' if collision=='group' else 'CB_oldgroup'},'token'
            with self.subTest(collision=collision),patch.object(task,'GroupJournal',Group):
                result=task.execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,priors,
                                    apply=True,sleep=lambda _:None,now=lambda:1000)
                self.assertEqual(result['result'],'UNVERIFIED')
                self.assertEqual(probe.attempts['cleanup'],0)

    def test_uncertain_notification_never_retries_or_cleans(self):
        journal=task.Journal(Backend());receipt=Receipt(Backend());probe=FakeProbe(mode='notify_lost')
        priors=tuple(self.prior(i) for i in range(4))
        result=task.execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,priors,
                            apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(result['result'],'UNVERIFIED')
        self.assertEqual(probe.attempts['notify'],1)
        self.assertEqual(probe.attempts['cleanup'],0)
        again=task.execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,priors,apply=True)
        self.assertEqual(again['result'],'UNVERIFIED')
        self.assertEqual(probe.attempts['notify'],1)

    def test_changed_previous_guard_prevents_cleanup(self):
        journal=task.Journal(Backend());receipt=Receipt(Backend());probe=FakeProbe()
        def prior():
            return ({'target':'CB_old','plan':{'owner':credentials()['vid']}},'changed' if probe.attempts['notify'] else 'original',b'receipt')
        priors=(prior,)+tuple(self.prior(i) for i in range(3))
        result=task.execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,priors,
                            apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(result['result'],'UNVERIFIED')
        self.assertEqual(probe.attempts['cleanup'],0)

    def test_missing_prior_or_guard_stops_before_writes(self):
        for priors,guard in ((tuple(self.prior(i) for i in range(3)),lambda:True),
                             (tuple(self.prior(i) for i in range(4)),lambda:False)):
            probe=FakeProbe()
            with self.assertRaises(ValueError):
                task.execute(probe,task.Journal(Backend()),Receipt(Backend()),credentials(),lambda *_:True,
                             lambda _:True,guard,priors,apply=True)
            self.assertEqual(sum(probe.attempts.values()),0)


if __name__=='__main__':unittest.main()
