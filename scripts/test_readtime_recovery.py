"""Consumed time requests are diagnosed only with reads, never replayed."""
from contextlib import redirect_stdout
from copy import deepcopy
import io,json,unittest
from unittest.mock import patch
from annotation_experiment_model import digest
from secure_weread_session import StoreError
from test_eink_login import Opener
from test_readtime_trial import fixture_trial
from selection_trial_mock import credentials
import verify_readtime_recovery as recovery


def fixture():
    trial,source,_op,clock,before,stats,*_r=fixture_trial();trial.prepare({},credentials())
    receipt=trial.store.advance(trial.store.reserve(trial.bound),'claimed')
    source.baseline.reset_mock();source.prepare.reset_mock()
    source.plan=trial.source.plan
    opener=Opener([deepcopy(v) for _i in range(2) for v in (before,stats)])
    task=recovery.Recovery(source,trial.store,opener=opener,clock=lambda:clock[0],sleep=lambda n:clock.__setitem__(0,clock[0]+n))
    return task,source,opener,receipt,clock


class RecoveryTests(unittest.TestCase):
    def invoke(self,task,**kwargs):
        with patch.object(recovery,'reading_position',return_value=task.source.plan.web_position):
            return task.run({'vid':credentials()['vid']},credentials(),**kwargs)

    def test_default_does_not_open_accounts_or_send(self):
        for argv in ([],['--retire-unverified']):
            with patch.object(recovery,'SessionStore') as store,patch.object(recovery,'Recovery') as probe,redirect_stdout(io.StringIO()) as out:
                self.assertEqual(recovery.main(argv),bool(argv))
            store.assert_not_called();probe.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)

    def test_two_unchanged_reads_retain_claim_by_default(self):
        task,source,op,r,_clock=fixture();result=self.invoke(task)
        self.assertEqual(result['result'],'PASS_READONLY_UNCHANGED');self.assertEqual(task.store.read()[1],r)
        self.assertEqual(len(op.requests),4);self.assertTrue(all(x.data is None for x in op.requests))
        source.prepare.assert_called_with({'vid':credentials()['vid']},credentials(),existing=task.store.read()[0]['plan']['source'])
        self.assertEqual(source.baseline.call_count,3);self.assertFalse(result['old_scope_reusable'])

    def test_retirement_keeps_consumed_scope_and_can_never_advance(self):
        task,_source,op,_r,_clock=fixture();old=deepcopy(task.store.read()[0]);result=self.invoke(task,retire=True)
        state,receipt=task.store.read();self.assertEqual(result['result'],'UNVERIFIED_RETIRED');self.assertEqual(state['phase'],'retired')
        self.assertEqual(state['plan'],old['plan']);self.assertEqual(state['reserved_posts'],1)
        self.assertTrue(state['retirement']['original_trial_unverified']);self.assertIsNotNone(task.store.backend.data)
        for action in (lambda:task.store.reserve(state['plan']),lambda:task.store.advance(receipt,'verified'),lambda:task.store.finish(receipt)):
            with self.assertRaises(StoreError):action()
        self.assertTrue(all(x.data is None for x in op.requests))

    def test_changed_counter_statistics_or_position_prevents_retirement(self):
        for kind in ('readingTime','ttsTime','statistics','position'):
            task,_source,op,r,_clock=fixture()
            if kind=='statistics':op.responses[3]['totalReadTime']+=1
            elif kind=='position':op.responses[2]['book']['chapterOffset']+=1
            else:op.responses[2]['book'][kind]+=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):self.invoke(task,retire=True)
            self.assertEqual(task.store.read()[1],r);self.assertTrue(all(x.data is None for x in op.requests))

    def test_changed_source_web_position_grant_or_owner_prevents_retirement(self):
        for kind in ('source','web','grant','owner'):
            task,source,op,r,_clock=fixture()
            if kind=='source':source.baseline.side_effect=ValueError('selection_trial/changed')
            with self.subTest(kind=kind),patch.object(recovery,'reading_position',return_value={} if kind=='web' else source.plan.web_position):
                if kind=='grant':
                    original=task.source.baseline
                    def changed(*args,**kwargs):
                        result=original(*args,**kwargs);task.grant=digest({'different':'grant'});return result
                    task.source.baseline=changed
                saved={'vid':'other' if kind=='owner' else credentials()['vid']}
                with self.assertRaises(ValueError):task.run(saved,credentials(),retire=True)
            self.assertEqual(task.store.read()[1],r);self.assertTrue(all(x.data is None for x in op.requests))

    def test_timeout_and_replacement_never_retire_or_retry(self):
        for kind in ('timeout','replace','callback'):
            task,_source,op,r,_clock=fixture()
            if kind=='timeout':op.responses[2]=TimeoutError()
            def final():
                if kind=='replace':task.store.backend.data=None
                elif kind=='callback':raise OSError('synthetic')
            with self.subTest(kind=kind),self.assertRaises(Exception):self.invoke(task,retire=True,on_final=final)
            if kind!='replace':self.assertEqual(task.store.read()[1],r)
            self.assertLessEqual(len(op.requests),4);self.assertTrue(all(x.data is None for x in op.requests))

    def test_retirement_audit_tampering_is_rejected(self):
        for key in ('no_replay','original_trial_unverified','plan_sha256','independent_reads','checked_at'):
            task,_source,_op,_r,_clock=fixture();self.invoke(task,retire=True)
            value=json.loads(task.store.backend.data)
            value['retirement'][key]=False if key in ('no_replay','original_trial_unverified','checked_at') else 'wrong'
            task.store.backend.data=json.dumps(value).encode()
            with self.subTest(key=key),self.assertRaises(StoreError):task.store.read()

    def test_no_writes_foreign_paths_or_unprepared_network_requests(self):
        task,_source,op,_r,_clock=fixture()
        for url,body in [(recovery.BASE+'/book/batchUploadProgress',{}),(recovery.BASE+'/login',{}),(recovery.BASE+'/book/getProgress?bookId=42',None)]:
            with self.assertRaises(ValueError):task.request('outside',url,body,credentials())
        self.assertEqual(len(op.requests),0)


if __name__=='__main__':unittest.main()
