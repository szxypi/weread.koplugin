"""Revised completion receipt boundaries; synthetic transport and stores only."""
from contextlib import redirect_stdout,redirect_stderr
import io
import json
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from secure_finish_experiment import FinishExperimentStore,fingerprint
from test_eink_login import Opener
from test_finish_roundtrip import bound,position,shelf
from test_secure_native_session import Backend,credentials
from verify_finish_receipts import POLICY,FinishReadingProbe,main,receipt_matches
from verify_finish_roundtrip import BASE,FinishError,FinishProbe


def receipt(finished):return dict(finishReading=int(finished),status=1)


def complete_tail():
    return [shelf(),position(),receipt(True),shelf(True),position(),
            shelf(True),position(),receipt(False),shelf(),position()]


class ReceiptTests(unittest.TestCase):
    def test_numeric_requested_flag_is_required_for_each_direction(self):
        for desired in (True,False):
            for value in (dict(finishReading=int(desired)),dict(receipt(desired),errcode=0,errCode=None),
                          dict(receipt(desired),succ=1,success=True,bookId=41,book_id='41')):
                with self.subTest(desired=desired,value=value):self.assertTrue(receipt_matches(value,desired,'41'))
            self.assertFalse(receipt_matches(receipt(not desired),desired,'41'))

    def test_generic_success_status_nested_flags_or_finished_are_not_substitutes(self):
        for value in ({},dict(succ=1),dict(success=True),dict(status=1),dict(finished=1),
                      dict(data=receipt(True)),dict(status=4,succ=1),None,[],1):
            with self.subTest(value=value):self.assertFalse(receipt_matches(value,True,'41'))

    def test_flag_has_strict_integer_type_and_known_enum(self):
        for flag in (None,True,False,'1','0',1.0,0.0,2,-1,[],{},float('nan')):
            for desired in (True,False):
                with self.subTest(flag=repr(flag),desired=desired):
                    self.assertFalse(receipt_matches(dict(finishReading=flag),desired,'41'))

    def test_explicit_error_and_contradictory_success_are_rejected(self):
        for key,values in [('errcode',[-1,False,'0',0.0,{},[]]),('errCode',[1,True,'0',0.0]),
                           ('succ',[0,False,'1',1.0,None]),('success',[False,1,'true',None])]:
            for value in values:
                with self.subTest(key=key,value=value):
                    self.assertFalse(receipt_matches(dict(receipt(True),**{key:value}),True,'41'))

    def test_each_present_identity_must_match_and_arguments_are_strict(self):
        for key in ('bookId','book_id'):
            for value in ('42',42,None,False,{},[],0):
                with self.subTest(key=key,value=value):
                    self.assertFalse(receipt_matches(dict(receipt(True),**{key:value}),True,'41'))
        self.assertFalse(receipt_matches(dict(receipt(True),bookId='41',book_id='42'),True,'41'))
        for desired,identity in ((1,'41'),(0,'41'),(None,'41'),(True,41),(True,''),(True,None)):
            self.assertFalse(receipt_matches(receipt(True),desired,identity))

    def test_status_and_unknown_fields_do_not_create_an_ack(self):
        for status in (0,1,4,15,'private-status',dict(private='value')):
            self.assertFalse(receipt_matches(dict(status=status),True,'41'))
            self.assertTrue(receipt_matches(dict(receipt(True),status=status,private='value'),True,'41'))


class ProtocolTests(unittest.TestCase):
    def probe(self,tail=()):
        opener=Opener([shelf(),position(),*tail]);probe=FinishReadingProbe(opener,sleep=lambda _seconds:None)
        plan,_row=probe.prepare(credentials());return probe,opener,plan

    def test_both_receipts_and_independent_full_flags_positions_are_required(self):
        probe,opener,plan=self.probe(complete_tail());probe.run(credentials(),plan,confirmed=True)
        self.assertTrue(probe.report['steps_verified']);self.assertEqual(probe.report['receipt_policy'],POLICY)
        posts=[r for r in opener.requests if r.get_method()=='POST'];self.assertEqual(len(posts),2)
        for ordinal,request in enumerate(posts):
            self.assertEqual(request.full_url,BASE+'/book/markstatus')
            self.assertEqual(json.loads(request.data),dict(bookId='41',auto=0,finishInfo=0,isCancel=ordinal,status=4))
        self.assertEqual([r['finish_reading_enum'] for r in probe.report['write_receipts']],['1','0'])
        self.assertTrue(all(r['finish_reading_matches_requested'] for r in probe.report['write_receipts']))

    def test_policy_plan_differs_from_legacy_for_the_same_private_baseline(self):
        probe,_opener,plan=self.probe()
        self.assertNotEqual(probe.plan_fingerprint(),fingerprint(plan.bound))
        self.assertEqual(probe.report['plan_fingerprint'],probe.plan_fingerprint())
        legacy=FinishProbe(Opener([shelf(),position()]));legacy.prepare(credentials())
        self.assertEqual(legacy.report['plan_fingerprint'],fingerprint(plan.bound))

    def test_unknown_first_receipt_never_triggers_restore_even_if_flag_changed(self):
        for reply in (dict(status=1),dict(succ=1),receipt(False),dict(receipt(True),bookId='42'),
                      dict(receipt(True),success=False),dict(finishReading=True),TimeoutError('private-timeout')):
            probe,opener,plan=self.probe([shelf(),position(),reply,shelf(True),position()])
            with self.subTest(reply=type(reply).__name__),self.assertRaisesRegex(FinishError,'finish_write_unconfirmed'):
                probe.run(credentials(),plan,confirmed=True)
            self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),1)
            self.assertFalse(probe.report['steps_verified'])

    def test_matching_receipt_without_independent_flag_never_restores(self):
        probe,opener,plan=self.probe([shelf(),position(),receipt(True),*([shelf(),position()]*3)])
        with self.assertRaisesRegex(FinishError,'finish_write_unconfirmed'):probe.run(credentials(),plan,confirmed=True)
        self.assertEqual(probe.report['data_writes_attempted'],1);self.assertEqual(len(opener.requests),11)

    def test_matching_receipt_does_not_mask_unrelated_flag_or_position_change(self):
        other=shelf(True);other['books'][1]['finishReading']=0
        for snapshot,raw_position in ((other,position()),(shelf(True),position(101))):
            probe,_opener,plan=self.probe([shelf(),position(),receipt(True),snapshot,raw_position])
            with self.assertRaises(FinishError):probe.run(credentials(),plan,confirmed=True)
            self.assertEqual(probe.report['data_writes_attempted'],1)

    def test_unknown_restore_receipt_does_not_claim_success_or_replay(self):
        tail=complete_tail();tail[7]=dict(status=1)
        probe,opener,plan=self.probe(tail)
        with self.assertRaisesRegex(FinishError,'finish_write_unconfirmed'):probe.run(credentials(),plan,confirmed=True)
        self.assertEqual(probe.report['data_writes_attempted'],2);self.assertFalse(probe.report['steps_verified'])
        count=len(opener.requests)
        with self.assertRaises(FinishError):probe.run(credentials(),plan,confirmed=True)
        self.assertEqual(len(opener.requests),count)

    def test_401_after_write_only_reads_and_never_renews(self):
        errors=[HTTPError(BASE+'/shelf/sync',401,'private-error',{},io.BytesIO(b'private-body')) for _i in range(3)]
        probe,opener,plan=self.probe([shelf(),position(),receipt(True),*errors])
        with self.assertRaises(FinishError):probe.run(credentials(),plan,confirmed=True)
        self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),1)
        self.assertEqual(probe.report['authentication_posts_attempted'],0)
        self.assertTrue(all(error.closed for error in errors))

    def test_shape_keeps_only_bounded_values_and_no_unknown_keys_or_identity(self):
        probe,_opener,_plan=self.probe()
        raw=dict(receipt(True),bookId='41',book_id='42',private_title='Private',private_token='sensitive')
        shape=probe.receipt_shape(raw,True);text=json.dumps(shape)
        self.assertEqual(shape['other_fields_count'],2);self.assertFalse(shape['returned_book_id_matches'])
        for private in ('private_title','private_token','Private','sensitive','"41"','"42"'):self.assertNotIn(private,text)
        for value,expected in ((None,'invalid'),('private-status','invalid'),({},'invalid'),(16,'invalid'),(True,'invalid'),(0,'0')):
            shape=probe.receipt_shape(dict(finishReading=value,status=value),False)
            self.assertEqual(shape['finish_reading_enum'],expected);self.assertEqual(shape['status_enum'],expected)
        self.assertEqual(probe.receipt_shape({},True)['finish_reading_enum'],'absent')


class CliTests(unittest.TestCase):
    def execute(self,tail=(),*,apply=False,expected=None,backend=None):
        opener=Opener([shelf(),position(),*tail]);probe=FinishReadingProbe(opener,sleep=lambda _seconds:None)
        store=FinishExperimentStore(backend or Backend());grant=credentials()
        # Compute a policy-bound preview independently with synthetic inputs.
        preview=FinishReadingProbe(Opener([shelf(),position()]));preview.prepare(credentials())
        args=['--saved-session']+(['--apply','--expected-plan',expected or preview.plan_fingerprint()] if apply else [])
        with patch('verify_finish_roundtrip.SessionStore') as web,patch('verify_finish_roundtrip.NativeSessionStore') as native,\
             patch('verify_finish_roundtrip.FinishExperimentStore',return_value=store),\
             patch('verify_finish_roundtrip.ShelfExperimentStore') as membership,\
             patch('verify_finish_receipts.FinishReadingProbe',return_value=probe),redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='900000');native.return_value.load.return_value=grant
            membership.return_value.pending.return_value=False
            code=main(args)
        self.assertEqual(grant,{})
        for private in ('Private target title','Private other title','synthetic-native-access','synthetic-native-refresh',
                        '"41"','"42"','"900000"'):self.assertNotIn(private,out.getvalue())
        native.return_value.delete.assert_not_called();web.return_value.delete.assert_not_called()
        return code,json.loads(out.getvalue()),store,opener

    def test_default_offline_does_not_load_credentials_or_create_probe(self):
        with patch('verify_finish_roundtrip.SessionStore') as store,patch('verify_finish_receipts.FinishReadingProbe') as probe,\
             redirect_stdout(io.StringIO()) as out:self.assertEqual(main([]),0)
        store.assert_not_called();probe.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_invalid_apply_never_loads_credentials(self):
        for args in (['--apply'],['--saved-session','--expected-plan','a'*64]):
            with patch('verify_finish_roundtrip.SessionStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
                main(args)
            store.assert_not_called()

    def test_readonly_preview_creates_no_intent_and_sends_four_gets(self):
        code,value,store,opener=self.execute([shelf(),position()])
        self.assertEqual(code,0);self.assertEqual(value['result'],'OWNER_FINISH_PREVIEW_VERIFIED')
        self.assertEqual(value['receipt_policy'],POLICY);self.assertFalse(store.pending())
        self.assertEqual(len(opener.requests),4);self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))

    def test_legacy_preview_cannot_authorize_revised_policy(self):
        code,value,store,opener=self.execute(apply=True,expected=fingerprint(bound()))
        self.assertEqual(code,1);self.assertEqual(value['detail'],'finish_plan_changed');self.assertFalse(store.pending())
        self.assertEqual(value['data_writes_attempted'],0);self.assertEqual(len(opener.requests),2)

    def test_full_roundtrip_needs_extra_final_read_and_clears_owned_intent(self):
        code,value,store,opener=self.execute([*complete_tail(),shelf(),position()],apply=True)
        self.assertEqual(code,0);self.assertTrue(value['roundtrip_verified']);self.assertFalse(store.pending())
        self.assertEqual(len(opener.requests),14);self.assertEqual(value['data_writes_attempted'],2)

    def test_missing_receipt_retains_intent_and_reopen_sends_nothing(self):
        backend=Backend()
        code,value,store,_opener=self.execute([shelf(),position(),dict(status=1),shelf(True),position()],apply=True,backend=backend)
        self.assertEqual(code,1);self.assertTrue(store.pending());self.assertEqual(value['data_writes_attempted'],1)
        code,value,_store,opener=self.execute(apply=True,backend=backend)
        self.assertEqual(code,1);self.assertEqual(value['data_writes_attempted'],0);self.assertEqual(len(opener.requests),0)

    def test_final_changed_position_keeps_intent_and_unverified_result(self):
        code,value,store,_opener=self.execute([*complete_tail(),shelf(),position(101)],apply=True)
        self.assertEqual(code,1);self.assertFalse(value['roundtrip_verified']);self.assertTrue(store.pending())


if __name__=='__main__':unittest.main()
