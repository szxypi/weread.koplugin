"""Bounded native executor contracts; synthetic receipts and memory storage."""
from contextlib import redirect_stdout,redirect_stderr
import copy
import hashlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock,patch

import verify_owner_progress_roundtrip as task
import owner_progress_roundtrip_contract as contract
from secure_position_experiment import ExperimentStore,binding,fingerprint
from test_secure_native_session import Backend
from test_owner_reading import OWNER,COOKIES,stage,frame
from test_position_roundtrip import plan
from test_owner_progress_preview import records


def addon(mode='good'):
    value=dict(**dict.fromkeys(contract.FLAGS,True),result='PASS',failure='none',guard_denied=0,posts_attempted=4,
               guard_reads=7,synthetic_acknowledgements=0,failed_line=0,post_statuses=[200]*4)
    value['unrelated_position_seen']=False
    value['disarmed']=value['permission_blocked']=False
    if mode=='not_seen':value.update(result='UNVERIFIED',failure='probe_unconfirmed',probe_confirmed=False,probe_seen=False,
                                    safe_resolution=False,restore_acknowledged=False,posts_attempted=3,post_statuses=[200]*3)
    if mode=='zero':
        value.update(**dict.fromkeys(contract.FLAGS,False))
        value.update(result='UNVERIFIED',failure='preparation_failed',posts_attempted=0,post_statuses=[])
    if mode=='unknown_restore':value.update(result='UNVERIFIED',failure='restore_unconfirmed',restore_acknowledged=False,
                                          safe_resolution=False,post_statuses=[200,200,200,0])
    if mode=='disarmed':value.update(result='UNVERIFIED',failure='same_unconfirmed',posts_attempted=0,post_statuses=[],
                                    disarmed=True,permission_blocked=True,probe_confirmed=False,probe_seen=False,
                                    same_position_confirmed=False,restore_acknowledged=False)
    return value


def envelope(digest,mode='good'):
    extra=addon(mode);row=stage();row['progress_roundtrip']=extra
    return dict(report=dict(result='PASS' if mode=='good' else 'UNVERIFIED',tmpfs_profile=True,profile_removed=True,
                            stages=[row],runner_error='none' if mode=='good' else 'experiment_unverified'),
                cookies=COOKIES.copy(),progress_private=dict(records=records()[:extra['posts_attempted']],guard_installed=True,intent_digest=digest))


class RoundtripTests(unittest.TestCase):
    def test_default_is_offline_without_any_keychain_or_child(self):
        with patch.object(task,'SessionStore') as web,patch.object(task,'ExperimentStore') as intent,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        web.assert_not_called();intent.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_apply_needs_saved_session_exact_fingerprint_and_a_command(self):
        for args in (['--apply'],['--saved-session','--apply'],['--saved-session','--expected-plan','a'*64],
                     ['--saved-session','--apply','--expected-plan','bad','--lua-command','synthetic'],['--lua-command','synthetic']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def test_receipts_require_exact_statuses_and_no_manufactured_ack(self):
        clean=envelope('a'*64);contract.decode(frame(clean),OWNER)
        for key,bad in (('posts_attempted',5),('synthetic_acknowledgements',1),('safe_resolution',False),('guard_denied',1),('probe_seen',False)):
            value=envelope('a'*64);value['report']['stages'][0]['progress_roundtrip'][key]=bad
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        for key,bad in (('guard_installed',False),('intent_digest','bad'),('records',[])):
            value=envelope('a'*64);value['progress_private'][key]=bad
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_observing_baseline_after_an_unseen_probe_cannot_resolve_the_intent(self):
        value=envelope('a'*64,'not_seen');contract.decode(frame(value),OWNER)
        value['report']['stages'][0]['progress_roundtrip']['safe_resolution']=True
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        value=envelope('a'*64,'unknown_restore');contract.decode(frame(value),OWNER)
        value['report']['stages'][0]['progress_roundtrip']['safe_resolution']=True
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def run_saved(self,*,mode='good',apply=True,check=False,child_error=None,wrong_plan=False,wrong_receipt=False,changed=False,pending=False,cleanup_fail=False,begin_fail=False):
        backend=Backend();intents=ExperimentStore(backend);value=plan();bound=binding(OWNER,value,'a'*64)
        if pending:intents.begin(bound)
        if cleanup_fail:backend.delete=lambda:True
        if begin_fail:backend.load=lambda:None
        web=MagicMock();web.vid=OWNER;web.book_id=value['book_id'];web.plan=copy.deepcopy(value);web.report=dict(stages=[])
        web.prepare.return_value=dict(book_id=value['book_id'],chapter_uid=str(value['baseline']['chapter_uid']),source_raw_sha256='a'*64,progress_preview={})
        after=dict(book=dict(bookId=value['book_id'],chapterUid=value['baseline']['chapter_uid'],chapterIdx=value['baseline']['chapter_idx'],
                             chapterOffset=value['baseline']['chapter_offset']+int(changed),progress=value['baseline']['raw_percent']))
        web.request.return_value=after
        def child_reply(_command,**options):
            private=json.loads(options['input'])['progress_roundtrip']
            digest='f'*64 if wrong_receipt else private['intent_digest']
            return SimpleNamespace(returncode=0 if mode=='good' else 1,stdout=frame(envelope(digest,mode)))
        with patch.object(task,'SessionStore') as store,patch.object(task,'ExperimentStore',return_value=intents), \
                patch.object(task,'Preflight',return_value=web),patch.object(task,'save_refreshed_web_session',return_value=False), \
                patch.object(task.subprocess,'run',side_effect=child_error or child_reply) as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid=OWNER,cookies=COOKIES.copy())
            args=['--saved-session']
            if apply:args+=['--apply','--expected-plan','f'*64 if wrong_plan else fingerprint(bound),'--lua-command','synthetic']
            if check:args+=['--check-only','--lua-command','synthetic']
            code=task.main(args)
        return code,json.loads(out.getvalue()),intents,child

    def test_plan_preparation_never_creates_a_marker_or_launches_native_writes(self):
        code,value,intents,child=self.run_saved(apply=False)
        self.assertEqual((code,value['result']),(0,'BOUNDED_NATIVE_EXPERIMENT_PLAN_READY'))
        self.assertEqual(len(value['plan_fingerprint']),64)
        self.assertFalse(intents.pending());child.assert_not_called()

    def test_verified_four_posts_and_independent_original_position_remove_only_owned_intent(self):
        code,value,intents,child=self.run_saved()
        self.assertEqual((code,value['result']),(0,'OWNER_NATIVE_POSITION_ROUNDTRIP_VERIFIED'))
        self.assertEqual(value['account_data_writes_attempted'],4)
        self.assertEqual(value['intent_state'],'cleared');self.assertFalse(intents.pending())
        self.assertTrue(value['independent_original_position_verified']);self.assertEqual(child.call_count,1)
        self.assertNotIn('synthetic-ps',json.dumps(value));self.assertNotIn('synthetic-only-key',json.dumps(value))

    def test_stale_plan_and_existing_intent_stop_before_child(self):
        for options in (dict(wrong_plan=True),dict(pending=True)):
            code,value,_intents,child=self.run_saved(**options)
            self.assertEqual(code,1);child.assert_not_called();self.assertEqual(value['account_data_writes_attempted'],0)

    def test_unknown_or_replayed_receipts_are_never_retried_or_released(self):
        for options in (dict(child_error=RuntimeError('synthetic-private-body')),dict(wrong_receipt=True)):
            code,value,intents,child=self.run_saved(**options)
            self.assertEqual(code,1);self.assertTrue(intents.pending());self.assertEqual(child.call_count,1)
            self.assertIsNone(value['account_data_writes_attempted']);self.assertEqual(value['intent_state'],'pending')
            self.assertNotIn('synthetic-private-body',json.dumps(value))

    def test_proved_no_dispatch_and_not_spawned_child_can_release(self):
        for options in (dict(mode='zero'),dict(child_error=FileNotFoundError())):
            code,value,intents,_child=self.run_saved(**options)
            self.assertEqual(code,1);self.assertFalse(intents.pending());self.assertEqual(value['account_data_writes_attempted'],0)

    def test_unseen_probe_unknown_restore_or_changed_original_keep_the_marker(self):
        for options in (dict(mode='not_seen'),dict(mode='unknown_restore'),dict(changed=True)):
            code,value,intents,_child=self.run_saved(**options)
            self.assertEqual(code,1);self.assertTrue(intents.pending());self.assertEqual(value['intent_state'],'pending')

    def test_cleanup_failure_is_reported_as_unknown_not_as_cleared(self):
        code,value,intents,_child=self.run_saved(cleanup_fail=True)
        self.assertEqual(code,1);self.assertTrue(intents.pending());self.assertEqual(value['intent_state'],'unknown')

    def test_failed_begin_readback_keeps_uncertain_marker_and_never_launches(self):
        code,value,intents,child=self.run_saved(begin_fail=True)
        self.assertEqual(code,1);self.assertEqual(value['intent_state'],'unknown')
        self.assertIsNotNone(intents.backend.data);child.assert_not_called()
        self.assertEqual(value['account_data_writes_attempted'],0)

    def test_disarmed_actual_runner_checks_need_no_intent_and_no_apply_permission(self):
        code,value,intents,child=self.run_saved(mode='disarmed',apply=False,check=True)
        self.assertEqual((code,value['result']),(0,'OWNER_NATIVE_EXECUTOR_DISARMED_VERIFIED'))
        self.assertFalse(intents.pending());self.assertTrue(value['pre_dispatch_guard_verified'])
        self.assertEqual(value['account_data_writes_attempted'],0);self.assertEqual(child.call_count,1)

    def test_original_metadata_and_explicit_chapter_fields_are_required(self):
        value=plan();first=value['baseline']
        raw=dict(bookId=value['book_id'],chapterUid=first['chapter_uid'],chapterIdx=first['chapter_idx'],
                 chapterOffset=first['chapter_offset'],progress=first['raw_percent'])
        self.assertTrue(task.original_position(raw,value))
        for field in ('chapterIdx','chapterUid','chapterOffset'):
            missing=dict(raw);del missing[field]
            self.assertFalse(task.original_position(missing,value))


if __name__=='__main__':unittest.main()
