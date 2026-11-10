"""Offline intent, receipt, redaction and native executor boundaries."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import hashlib
import io
import json
from types import SimpleNamespace
import subprocess
import unittest
from unittest.mock import patch

from owner_shelf_membership_contract import FLAGS,FRAME,decode_runner,decode_stage,validate_stage
from secure_shelf_experiment import ShelfExperimentStore,Receipt,fingerprint,validate_plan
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from verify_owner_shelf_membership import main,members_digest,prepare


def baseline():return [{'bookId':str(index)} for index in range(41,81)]


def bound():return dict(owner='88008800',book_id='99009900',members_sha256=members_digest([row['bookId'] for row in baseline()]),grant_sha256='c'*64)


def stage(apply=False):
    value=dict(result='PASS',phase='complete',permit_writes=apply,shelf_books=40,profile_files_audited=4,screenshots=0,
               failed_line=0,denied_route=0,request_counts=[9 if apply else 3,1,int(apply),int(apply),0],
               post_statuses=[200,200] if apply else [],**dict.fromkeys(FLAGS,True))
    if not apply:
        for key in ('roundtrip_restored','journal_before_posts','native_cache_readback'):value[key]=False
    return value


def envelope(apply=False):
    receipt=hashlib.sha256(b'private-intent').hexdigest() if apply else ''
    return dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,runner_error='none',stage=stage(apply)),
                private=dict(plan_fingerprint=fingerprint(bound()),intent_digest=receipt,final_members_digest=bound()['members_sha256']))


class IntentTests(unittest.TestCase):
    def test_durable_pending_blocks_new_target_and_fresh_service(self):
        backend=Backend();store=ShelfExperimentStore(backend);receipt=store.begin(bound())
        self.assertTrue(ShelfExperimentStore(backend).pending())
        self.assertNotIn('88008800',repr(receipt))
        self.assertEqual(json.loads(backend.data)['maximum_posts'],2)
        with self.assertRaisesRegex(StoreError,'shelf_experiment_unconfirmed'):ShelfExperimentStore(backend).begin(dict(bound(),book_id='43'))

    def test_only_owned_verified_or_proved_unsent_receipt_can_clear(self):
        store=ShelfExperimentStore(Backend());receipt=store.begin(bound())
        for kwargs in ({},{'restored_verified':True,'not_dispatched':True}):
            with self.assertRaises(StoreError):store.finish(receipt,**kwargs)
        store.finish(receipt,not_dispatched=True);latest=store.begin(bound())
        with self.assertRaises(StoreError):store.finish(receipt,restored_verified=True)
        self.assertTrue(store.pending());store.finish(latest,restored_verified=True);self.assertFalse(store.pending())

    def test_corrupt_or_failed_readback_never_overwritten_or_claimed_cleared(self):
        backend=Backend();backend.data=b'private-corrupt';store=ShelfExperimentStore(backend)
        with self.assertRaises(StoreError):store.begin(bound())
        self.assertEqual(backend.data,b'private-corrupt')
        backend=Backend();backend.load=lambda:None
        with self.assertRaisesRegex(StoreError,'shelf_intent_readback_failed'):ShelfExperimentStore(backend).begin(bound())
        backend=Backend();store=ShelfExperimentStore(backend);receipt=store.begin(bound());backend.delete=lambda:None
        with self.assertRaisesRegex(StoreError,'shelf_intent_cleanup_unverified'):store.finish(receipt,restored_verified=True)
        self.assertTrue(store.pending())

    def test_binding_schema_and_fingerprint_are_exact(self):
        for key,value in (('owner','foreign'),('book_id','0'),('members_sha256','bad'),('grant_sha256',True)):
            with self.assertRaises(StoreError):validate_plan(dict(bound(),**{key:value}))
        with self.assertRaises(StoreError):validate_plan(dict(bound(),title='private'))
        self.assertNotEqual(fingerprint(bound()),fingerprint(dict(bound(),book_id='43')))


class ContractTests(unittest.TestCase):
    def test_preview_and_applied_schema_accept_only_their_own_receipts(self):
        for apply in (False,True):self.assertEqual(decode_runner(FRAME+json.dumps(envelope(apply)).encode(),apply),envelope(apply))
        with self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(envelope(True)).encode(),False)

    def test_all_acceptance_flags_must_be_proven_for_apply(self):
        for key in FLAGS:
            value=stage(True);value[key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(value,True)

    def test_no_private_or_unbounded_extra_output(self):
        for value in (dict(stage(),title='private'),dict(stage(),credentials={}),dict(stage(),raw={})):
            with self.assertRaises(ValueError):validate_stage(value,False)
        for key,value in (('result',[]),('phase',[]),('permit_writes',0),('shelf_books',True),('screenshots',1),
                          ('failed_line',-1),('request_counts',[3,1,0,0,True]),('request_counts',[14,1,0,0,0])):
            changed=stage();changed[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(changed,False)

    def test_preview_cannot_hide_or_reclassify_a_write(self):
        for value in ([3,1,1,0,0],[3,1,0,1,0]):
            changed=stage();changed['request_counts']=value;changed['post_statuses']=[200]
            with self.assertRaises(ValueError):validate_stage(changed,False)
        for statuses in ([200,429],[200],[200,True]):
            changed=stage(True);changed['post_statuses']=statuses
            with self.assertRaises(ValueError):validate_stage(changed,True)

    def test_framing_receipt_cleanup_and_types_are_mandatory(self):
        raw=FRAME+json.dumps(envelope()).encode()
        for invalid in (raw+raw,raw+b'private',b'private',b'x'*(2*1024*1024+1)+raw):
            with self.assertRaises(ValueError):decode_runner(invalid,False)
        for key in ('profile_removed','tmpfs_profile'):
            value=envelope();value['report'][key]=False
            with self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(value).encode(),False)
        value=envelope();value['private']['title']='private'
        with self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(value).encode(),False)
        value=envelope();value['private']['intent_digest']='a'*64
        with self.assertRaises(ValueError):decode_runner(FRAME+json.dumps(value).encode(),False)


class HostTests(unittest.TestCase):
    def invoke(self,apply=False,child=None,error=None,pending=False,prepare_error=None,oversize=False,wrong_plan=False,foreign_after=False):
        credentials=dict(vid='88008800',accessToken='private-access',refreshToken='private-refresh',deviceId='private-device')
        payload=dict(credentials=credentials,book_id='99009900',expected_metadata={'title':'private-title'},shelf_books=40,members_digest=bound()['members_sha256'])
        if oversize:payload['expected_metadata']['intro']='x'*(256*1024)
        if child is None:child=SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(envelope(apply)).encode(),stderr=b'private-output')
        with patch('verify_owner_shelf_membership.SessionStore') as web,patch('verify_owner_shelf_membership.NativeSessionStore') as native,\
                patch('verify_owner_shelf_membership.ShelfExperimentStore') as intents,patch('verify_owner_shelf_membership.DiscoveryProbe') as probe,\
                patch('verify_owner_shelf_membership.prepare',return_value=(bound(),payload),side_effect=prepare_error),\
                patch('verify_owner_shelf_membership.subprocess.run',return_value=child,side_effect=error) as process,redirect_stdout(io.StringIO()) as output:
            web.return_value.load.return_value={'vid':'88008800'};native.return_value.load.return_value=credentials
            intents.return_value.pending.return_value=pending;intents.return_value.begin.return_value=Receipt(b'private-intent')
            probe.return_value.report={'stages':[]};probe.return_value.request.return_value={'books':baseline()+([{'bookId':'99009900'}] if foreign_after else [])}
            args=['--saved-session']
            if apply:args+=['--apply','--expected-plan','d'*64 if wrong_plan else fingerprint(bound())]
            args+=['--lua-command','synthetic-runner']
            code=main(args)
        native.return_value.delete.assert_not_called();native.return_value.save.assert_not_called();self.assertEqual(credentials,{})
        text=output.getvalue()
        for secret in ('88008800','99009900','private-access','private-title','private-refresh','private-output','private-device','private-intent'):
            self.assertNotIn(secret,text)
        return code,json.loads(text),process,intents.return_value

    def test_default_is_offline_and_never_loads_or_writes_keychain(self):
        with patch('verify_owner_shelf_membership.SessionStore') as web,patch('verify_owner_shelf_membership.NativeSessionStore') as native,\
                patch('verify_owner_shelf_membership.ShelfExperimentStore') as intents,patch('verify_owner_shelf_membership.DiscoveryProbe') as probe,\
                patch('verify_owner_shelf_membership.subprocess.run') as child,redirect_stdout(io.StringIO()):self.assertEqual(main([]),0)
        for item in (web,native,intents,probe,child):item.assert_not_called()

    def test_apply_requires_a_scoped_plan_and_runner(self):
        for args in (['--apply'],['--saved-session'],['--lua-command','fake'],['--saved-session','--apply','--lua-command','fake']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)

    def test_readonly_success_does_not_reserve_an_intent(self):
        code,report,process,intents=self.invoke()
        self.assertEqual(code,0);self.assertEqual(report['account_data_writes_attempted'],0);self.assertTrue(report['independent_membership_unchanged'])
        intents.begin.assert_not_called();intents.finish.assert_not_called();self.assertEqual(process.call_count,1)

    def test_applied_success_independently_confirms_before_clearing(self):
        code,report,_process,intents=self.invoke(True)
        self.assertEqual(code,0);self.assertTrue(report['real_plugin_write_verified']);self.assertEqual(report['account_data_writes_attempted'],2)
        self.assertEqual(report['intent_state'],'cleared');intents.finish.assert_called_once_with(Receipt(b'private-intent'),restored_verified=True)

    def test_pending_intent_prevents_any_new_run(self):
        code,report,process,intents=self.invoke(True,pending=True)
        self.assertEqual(code,1);self.assertEqual(report['detail'],'shelf_experiment_unconfirmed');process.assert_not_called();intents.begin.assert_not_called()

    def test_timeout_or_untrusted_output_keeps_uncertainty_without_replay(self):
        cases=[dict(error=subprocess.TimeoutExpired('private-output',210,output=b'private-access')),
               dict(child=SimpleNamespace(returncode=1,stdout=b'private-output',stderr=b'private-title'))]
        for kwargs in cases:
            code,report,process,intents=self.invoke(True,**kwargs)
            self.assertEqual(code,1);self.assertEqual(report['intent_state'],'pending');self.assertIsNone(report['account_data_writes_attempted'])
            self.assertEqual(process.call_count,1);intents.finish.assert_not_called()

    def test_known_prelaunch_failures_release_only_unsent_attempts(self):
        for kwargs in (dict(error=FileNotFoundError('private-output')),dict(oversize=True)):
            code,report,_process,intents=self.invoke(True,**kwargs)
            self.assertEqual(code,1);self.assertEqual(report['intent_state'],'cleared');self.assertEqual(report['account_data_writes_attempted'],0)
            intents.finish.assert_called_once_with(Receipt(b'private-intent'),not_dispatched=True)

    def test_false_restoration_or_wrong_receipt_cannot_clear_intent(self):
        for kind in ('digest','plan','intent'):
            value=envelope(True)
            key={'digest':'final_members_digest','plan':'plan_fingerprint','intent':'intent_digest'}[kind];value['private'][key]='d'*64
            child=SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(value).encode(),stderr=b'private-output')
            code,report,_process,intents=self.invoke(True,child=child)
            self.assertEqual(code,1);self.assertEqual(report['intent_state'],'pending');intents.finish.assert_not_called()

    def test_plan_change_stops_before_intent_or_process(self):
        code,report,process,intents=self.invoke(True,wrong_plan=True)
        self.assertEqual(code,1);self.assertEqual(report['detail'],'shelf_plan_changed');process.assert_not_called();intents.begin.assert_not_called()

    def test_independent_membership_change_keeps_the_intent(self):
        code,report,_process,intents=self.invoke(True,foreign_after=True)
        self.assertEqual(code,1);self.assertFalse(report['independent_membership_unchanged']);self.assertEqual(report['intent_state'],'pending')
        intents.finish.assert_not_called()

    def test_known_zero_native_dispatch_is_not_treated_as_a_possible_write(self):
        value=envelope(True);value['report'].update(result='UNVERIFIED',runner_error='stage_unverified')
        value['report']['stage'].update(result='UNVERIFIED',phase='preview',roundtrip_restored=False,request_counts=[1,1,0,0,0],post_statuses=[])
        child=SimpleNamespace(returncode=1,stdout=FRAME+json.dumps(value).encode(),stderr=b'private-output')
        code,report,_process,intents=self.invoke(True,child=child)
        self.assertEqual(code,1);self.assertEqual(report['account_data_writes_attempted'],0);self.assertEqual(report['intent_state'],'cleared')
        intents.finish.assert_called_once_with(Receipt(b'private-intent'),not_dispatched=True)

    def test_readonly_receipt_and_counts_still_have_to_match_the_private_plan(self):
        for key in ('digest','count'):
            value=envelope()
            if key=='digest':value['private']['final_members_digest']='d'*64
            else:value['report']['stage']['shelf_books']=39
            child=SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(value).encode(),stderr=b'private-output')
            code,_report,_process,intents=self.invoke(child=child)
            self.assertEqual(code,1);intents.begin.assert_not_called();intents.finish.assert_not_called()


class PreparationTests(unittest.TestCase):
    def test_known_search_target_absence_and_native_metadata_are_bound(self):
        replies=[{'books':[{'bookId':'41'}]},
                 {'books':[{'bookInfo':{'bookId':'42','title':'三体1','author':'刘慈欣'},'searchIdx':1}],'hasMore':0},
                 {'bookId':'42','title':'三体1','author':'刘慈欣','totalWords':12345}]
        calls=[]
        probe=SimpleNamespace(request=lambda stage,url,**_kwargs:(calls.append((stage,url)) or replies.pop(0)))
        bound_value,payload=prepare({'vid':'900000','accessToken':'synthetic-access'},probe)
        self.assertEqual(payload['expected_metadata']['wordCount'],12345);self.assertEqual(payload['shelf_books'],1)
        self.assertEqual(bound_value['book_id'],'42');self.assertEqual([row[0] for row in calls],['discovery_shelf','search','discovery_metadata'])
        self.assertEqual(bound_value['members_sha256'],members_digest(['41']))

    def test_mismatched_native_title_cannot_be_used_as_the_selected_target(self):
        replies=[{'books':[{'bookId':'41'}]},
                 {'books':[{'bookInfo':{'bookId':'42','title':'三体1','author':'刘慈欣'},'searchIdx':1}],'hasMore':0},
                 {'bookId':'42','title':'Other book','author':'刘慈欣'}]
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:replies.pop(0))
        with self.assertRaisesRegex(ValueError,'membership_target_changed'):prepare({'vid':'900000','accessToken':'synthetic-access'},probe)


if __name__=='__main__':unittest.main()
