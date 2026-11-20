"""Offline completion protocol/intent checks; no account, Keychain or network."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from secure_finish_experiment import FinishExperimentStore,Receipt,validate_plan,fingerprint
from secure_weread_session import StoreError
from test_eink_login import Opener
from test_secure_native_session import Backend,credentials
from verify_finish_roundtrip import BASE,FinishProbe,FinishError,acknowledged,digest,main,point,shelf_flags


def shelf(finished=False):
    return dict(books=[dict(bookId='41',title='Private target title',finishReading=int(finished),finished=int(not finished)),
                       dict(bookId='42',title='Private other title',finishReading=1)])


def position(offset=100):return dict(book=dict(bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=offset,progress=37.5))


def bound():
    flags,_rows=shelf_flags(shelf())
    return dict(owner='900000',book_id='41',before=False,shelf_flags_sha256=digest(flags),
                position_sha256=digest(point(position(),'41')),grant_sha256=digest(credentials()))


def complete_tail():
    return [shelf(),position(),dict(succ=1),shelf(True),position(),
            shelf(True),position(),dict(succ=1),shelf(),position()]


class IntentTests(unittest.TestCase):
    def test_owned_pending_survives_reopen_and_blocks_overwrite(self):
        backend=Backend();store=FinishExperimentStore(backend);receipt=store.begin(bound())
        self.assertTrue(FinishExperimentStore(backend).pending())
        self.assertNotIn('900000',repr(receipt));self.assertEqual(json.loads(backend.data)['maximum_posts'],2)
        with self.assertRaises(StoreError):FinishExperimentStore(backend).begin(dict(bound(),book_id='42'))

    def test_only_owned_restored_or_unsent_receipt_can_clear(self):
        store=FinishExperimentStore(Backend());old=store.begin(bound())
        for options in ({},{'restored_verified':True,'not_dispatched':True}):
            with self.assertRaises(StoreError):store.finish(old,**options)
        store.finish(old,not_dispatched=True);latest=store.begin(bound())
        with self.assertRaises(StoreError):store.finish(old,restored_verified=True)
        self.assertTrue(store.pending());store.finish(latest,restored_verified=True);self.assertFalse(store.pending())

    def test_schema_and_plan_fingerprint_are_bounded_and_exact(self):
        for key,value in [('owner','foreign'),('book_id','0'),('before',0),('before',True),('grant_sha256','bad'),('position_sha256',True)]:
            with self.subTest(key=key,value=value),self.assertRaises(StoreError):validate_plan(dict(bound(),**{key:value}))
        with self.assertRaises(StoreError):validate_plan(dict(bound(),title='private'))
        self.assertNotEqual(fingerprint(bound()),fingerprint(dict(bound(),position_sha256='a'*64)))
        backend=Backend();store=FinishExperimentStore(backend);store.begin(bound());value=json.loads(backend.data)
        for field,invalid in [('schema',True),('maximum_posts',3),('scope','foreign'),('attempt','bad'),('started_at','')]:
            backend.data=json.dumps(dict(value,**{field:invalid})).encode()
            with self.subTest(field=field),self.assertRaises(StoreError):store.pending()

    def test_corruption_and_failed_readback_cannot_be_overwritten(self):
        for raw in [b'private-corrupt',b'x'*4097,b'[]']:
            backend=Backend();backend.data=raw
            with self.assertRaises(StoreError):FinishExperimentStore(backend).begin(bound())
            self.assertEqual(backend.data,raw)
        backend=Backend();backend.load=lambda:None
        with self.assertRaisesRegex(StoreError,'finish_intent_readback_failed'):FinishExperimentStore(backend).begin(bound())

    def test_failed_delete_is_still_pending(self):
        backend=Backend();store=FinishExperimentStore(backend);receipt=store.begin(bound());backend.delete=lambda:None
        with self.assertRaisesRegex(StoreError,'finish_intent_cleanup_unverified'):store.finish(receipt,restored_verified=True)
        self.assertTrue(store.pending())


class ProtocolTests(unittest.TestCase):
    def probe(self,tail=()):
        opener=Opener([shelf(),position(),*tail]);probe=FinishProbe(opener,sleep=lambda _seconds:None)
        plan,_row=probe.prepare(credentials());return probe,opener,plan

    def test_mark_then_restore_with_independent_positions_and_no_cookie(self):
        probe,opener,plan=self.probe(complete_tail());probe.run(credentials(),plan,confirmed=True)
        self.assertTrue(probe.report['steps_verified']);self.assertEqual(probe.report['data_writes_attempted'],2)
        posts=[r for r in opener.requests if r.get_method()=='POST'];self.assertEqual(len(posts),2)
        for index,request in enumerate(posts):
            self.assertEqual(request.full_url,BASE+'/book/markstatus')
            self.assertEqual(json.loads(request.data),dict(bookId='41',auto=0,finishInfo=0,isCancel=index,status=4))
        for request in opener.requests:
            self.assertIsNone(request.get_header('Cookie'));self.assertIsNone(request.get_header('Authorization'))
            self.assertEqual(request.get_header('Vid'),'900000')
        self.assertEqual([x['finished'] for x in probe.report['operations']],[True,False])
        self.assertEqual(probe.report['authentication_posts_attempted'],0)
        self.assertEqual(probe.report['write_receipts'],[dict(known_fields=['succ'],other_fields_count=0)]*2)

    def test_exact_plan_confirmation_owner_and_grant_required(self):
        for mode in ['unconfirmed','foreign_owner','grant','new_plan','mutated_flags','mutated_position','mutated_bound']:
            probe,opener,plan=self.probe();grant=credentials();candidate=plan
            if mode=='foreign_owner':grant['vid']='900099'
            elif mode=='grant':grant['accessToken']='synthetic-replaced'
            elif mode=='new_plan':candidate=deepcopy(plan)
            elif mode=='mutated_flags':plan.flags['42']=False
            elif mode=='mutated_position':plan.position['chapter_offset']=101
            elif mode=='mutated_bound':plan.bound['book_id']='42'
            with self.subTest(mode=mode),self.assertRaises((FinishError,StoreError)):
                probe.run(grant,candidate,confirmed=mode!='unconfirmed')
            self.assertEqual(len(opener.requests),2);self.assertEqual(probe.report['data_writes_attempted'],0)

    def test_consumed_probe_cannot_replay_or_select_another_book(self):
        probe,opener,plan=self.probe(complete_tail());probe.run(credentials(),plan,confirmed=True);count=len(opener.requests)
        for action in [lambda:probe.run(credentials(),plan,confirmed=True),lambda:probe.prepare(credentials())]:
            with self.assertRaises(FinishError):action()
        self.assertEqual(len(opener.requests),count)

    def test_unrelated_routes_and_payloads_are_denied_before_transport(self):
        probe,opener,_plan=self.probe()
        for url,body in [(BASE+'/login',{}),(BASE+'/shelf/add',{'bookIds':['41']}),
                         (BASE+'/book/markstatus',dict(bookId='41')),(BASE+'/book/getProgress?bookId=42',None),
                         ('http://i.weread.qq.com/shelf/sync',None),(BASE+'/shelf/sync?other=1',None)]:
            with self.subTest(url=url),self.assertRaises(FinishError):probe.request('unconfirmed',url,body,credentials())
        self.assertEqual(len(opener.requests),2)

    def test_preflight_flags_or_position_change_stops_before_post(self):
        for changed,where in [(shelf(True),'shelf'),(position(101),'position')]:
            tail=[changed if where=='shelf' else shelf(),changed if where=='position' else position()]
            probe,opener,plan=self.probe(tail)
            with self.assertRaisesRegex(FinishError,'finish_preflight_changed'):probe.run(credentials(),plan,confirmed=True)
            self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))

    def test_unknown_or_conflicting_ack_cannot_restore_even_if_desired_observed(self):
        responses=[{},dict(succ=0),dict(succ='1'),dict(succ=1.0),dict(succ=1,success=False),
                   dict(succ=1,errcode=0,errCode=-1),TimeoutError('private-timeout')]
        for reply in responses:
            probe,opener,plan=self.probe([shelf(),position(),reply,shelf(True),position()])
            with self.subTest(reply=type(reply).__name__),self.assertRaisesRegex(FinishError,'finish_write_unconfirmed'):
                probe.run(credentials(),plan,confirmed=True)
            self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),1)

    def test_bounded_stale_readback_never_claims_success(self):
        probe,opener,plan=self.probe([shelf(),position(),dict(succ=1),*([shelf(),position()]*3)])
        with self.assertRaisesRegex(FinishError,'finish_write_unconfirmed'):probe.run(credentials(),plan,confirmed=True)
        self.assertEqual(len(opener.requests),11);self.assertEqual(probe.report['data_writes_attempted'],1)

    def test_readback401_never_renews_or_reposts(self):
        errors=[HTTPError(BASE+'/shelf/sync',401,'private-error',{},io.BytesIO(b'private-body')) for _i in range(3)]
        probe,opener,plan=self.probe([shelf(),position(),dict(succ=1),*errors])
        with self.assertRaises(FinishError):probe.run(credentials(),plan,confirmed=True)
        self.assertEqual(probe.report['data_writes_attempted'],1)
        self.assertFalse(any(r.full_url.endswith('/login') for r in opener.requests))
        self.assertTrue(all(error.closed for error in errors))

    def test_unrelated_flag_or_reading_position_changes_stop_after_first_post(self):
        other=shelf(True);other['books'][1]['finishReading']=0
        for snapshot,raw_position in [(other,position()),(shelf(True),position(101))]:
            probe,_opener,plan=self.probe([shelf(),position(),dict(succ=1),snapshot,raw_position])
            with self.assertRaises(FinishError):probe.run(credentials(),plan,confirmed=True)
            self.assertEqual(probe.report['data_writes_attempted'],1)

    def test_restore_preflight_must_still_match_verified_changed_state(self):
        probe,_opener,plan=self.probe([shelf(),position(),dict(succ=1),shelf(True),position(),shelf(),position()])
        with self.assertRaisesRegex(FinishError,'finish_preflight_changed'):probe.run(credentials(),plan,confirmed=True)
        self.assertEqual(probe.report['data_writes_attempted'],1)

    def test_unknown_restore_receipt_retains_uncertainty_even_when_flag_restored(self):
        tail=complete_tail();tail[7]=TimeoutError('private-lost-restore')
        probe,_opener,plan=self.probe(tail)
        with self.assertRaisesRegex(FinishError,'finish_write_unconfirmed'):probe.run(credentials(),plan,confirmed=True)
        self.assertEqual(probe.report['data_writes_attempted'],2);self.assertFalse(probe.report['steps_verified'])

    def test_unknown_flags_duplicates_limits_and_wrong_progress_are_rejected(self):
        invalid=[{},dict(books=[dict(bookId='41',finishReading=2)]),dict(books=[dict(bookId='41')]*2),dict(books=[{}]*5001)]
        for value in invalid:
            with self.assertRaises(FinishError):shelf_flags(value)
        for value in [dict(book=dict(bookId='42',progress=10)),dict(book=dict(bookId='41',progress=10)),dict(errcode=-1)]:
            with self.assertRaises(FinishError):point(value,'41')
        self.assertIsNone(shelf_flags(dict(books=[dict(bookId='41',finished=1)]))[0]['41'])
        self.assertFalse(acknowledged(dict(succ=1,errCode=False)))


class CliTests(unittest.TestCase):
    def execute(self,tail,apply=False,*,backend=None,expected=None,other_pending=False):
        opener=Opener([shelf(),position(),*tail]);probe=FinishProbe(opener,sleep=lambda _seconds:None)
        store=FinishExperimentStore(backend or Backend());grant=credentials()
        args=['--saved-session']+(['--apply','--expected-plan',expected or fingerprint(bound())] if apply else [])
        with patch('verify_finish_roundtrip.SessionStore') as web,patch('verify_finish_roundtrip.NativeSessionStore') as native,\
             patch('verify_finish_roundtrip.FinishExperimentStore',return_value=store),\
             patch('verify_finish_roundtrip.ShelfExperimentStore') as membership,\
             patch('verify_finish_roundtrip.FinishProbe',return_value=probe),redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='900000');native.return_value.load.return_value=grant
            membership.return_value.pending.return_value=other_pending
            code=main(args)
        self.assertEqual(grant,{})
        for value in ['Private target title','Private other title','synthetic-native-access','synthetic-native-refresh',
                      'eink334691225'+'1'*19,'"41"','"42"','"900000"']:
            self.assertNotIn(value,out.getvalue())
        native.return_value.delete.assert_not_called();web.return_value.delete.assert_not_called()
        return code,json.loads(out.getvalue()),store,opener

    def test_default_offline_and_invalid_apply_never_open_stores(self):
        with patch('verify_finish_roundtrip.SessionStore') as web,patch('verify_finish_roundtrip.FinishProbe') as probe,\
             redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY');web.assert_not_called();probe.assert_not_called()
        for args in [['--apply'],['--apply','--expected-plan','a'*64],['--saved-session','--expected-plan','a'*64]]:
            with patch('verify_finish_roundtrip.SessionStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)
            store.assert_not_called()

    def test_readonly_preview_independent_and_no_intent(self):
        code,value,store,opener=self.execute([shelf(),position()])
        self.assertEqual(code,0);self.assertEqual(value['result'],'OWNER_FINISH_PREVIEW_VERIFIED')
        self.assertEqual(len(opener.requests),4);self.assertFalse(store.pending());self.assertEqual(value['data_writes_attempted'],0)

    def test_applied_success_requires_independent_final_and_clears_owned_intent(self):
        code,value,store,opener=self.execute([*complete_tail(),shelf(),position()],True)
        self.assertEqual(code,0);self.assertEqual(value['result'],'OWNER_FINISH_ROUNDTRIP_VERIFIED')
        self.assertTrue(value['roundtrip_verified'] and value['independent_flags_and_position_restored']);self.assertFalse(store.pending())
        self.assertEqual(len(opener.requests),14)

    def test_changed_plan_and_other_pending_experiment_prevent_posts(self):
        for options in [dict(expected='a'*64),dict(other_pending=True)]:
            code,value,store,opener=self.execute([],True,**options)
            self.assertEqual(code,1);self.assertEqual(value['data_writes_attempted'],0);self.assertFalse(store.pending())
            self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))

    def test_failed_preflight_proved_unsent_intent_can_clear(self):
        code,value,store,_opener=self.execute([shelf(True),position()],True)
        self.assertEqual(code,1);self.assertEqual(value['intent_state'],'cleared');self.assertFalse(store.pending())

    def test_unknown_post_intent_survives_reopen_without_any_replay(self):
        backend=Backend();tail=[shelf(),position(),TimeoutError('private'),shelf(True),position()]
        code,value,store,_opener=self.execute(tail,True,backend=backend)
        self.assertEqual(code,1);self.assertEqual(value['data_writes_attempted'],1);self.assertTrue(store.pending())
        code,value,_store,opener=self.execute([],True,backend=backend)
        self.assertEqual(code,1);self.assertEqual(len(opener.requests),0);self.assertEqual(value['intent_state'],'pending')

    def test_final_mismatch_and_failed_cleanup_are_never_claimed_restored(self):
        code,value,store,_opener=self.execute([*complete_tail(),shelf(True),position()],True)
        self.assertEqual(code,1);self.assertFalse(value['roundtrip_verified']);self.assertTrue(store.pending())
        backend=Backend();backend.delete=lambda:None
        code,value,store,_opener=self.execute([*complete_tail(),shelf(),position()],True,backend=backend)
        self.assertEqual(code,1);self.assertFalse(value['roundtrip_verified']);self.assertTrue(store.pending())

    def test_owner_load_failure_sends_nothing(self):
        with patch('verify_finish_roundtrip.SessionStore') as web,patch('verify_finish_roundtrip.NativeSessionStore') as native,\
             patch('verify_finish_roundtrip.FinishProbe') as probe,redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='900000');native.return_value.load.side_effect=StoreError('private')
            self.assertEqual(main(['--saved-session']),1)
        probe.assert_not_called();self.assertEqual(json.loads(out.getvalue())['data_writes_attempted'],0)


if __name__=='__main__':unittest.main()
