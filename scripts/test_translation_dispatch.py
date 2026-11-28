"""Injected transport only; never opens credentials or a real network."""
import base64,io,json,unittest
from unittest.mock import Mock,patch
from urllib.error import HTTPError,URLError
from annotation_experiment_model import canonical,digest
from test_secure_native_session import Backend,credentials
import test_translation_generation as fixtures
from secure_translation_generation import TranslationGenerationStore
from secure_weread_session import StoreError,MAX_BYTES
from translation_dispatch import send_once
from translation_wire import MAX_WIRE,capture,response,successful_http
from translation_result import make_proof,original_signature


class Reply:
    def __init__(self,raw,status=200):self.raw=raw;self.status=status;self.limit=None;self.closed=False
    def read(self,limit):self.limit=limit;return self.raw[:limit]
    def close(self):self.closed=True


class DispatchTest(unittest.TestCase):
    def setUp(self):
        fixture=fixtures.PlanTest();fixture.setUp();self.grant=credentials();fixture.grant=self.grant;self.plan=fixture.plan()
        self.backend=Backend();self.store=TranslationGenerationStore(self.backend);self.receipt=self.store.reserve(self.plan)
        self.transport=Mock();self.current=Mock()
        self.proof=make_proof(fixture.catalog,self.plan,original_signature(fixture.source))
    def send(self,raw=b'{"succ":1}',op='mode',status=200,reply=None):
        self.reply=reply or Reply(raw,status);self.transport.open.return_value=self.reply
        return send_once(self.store,self.receipt,op,self.grant,current=self.current,opener=self.transport)
    def ready_generation(self):self.receipt,_=self.send();self.transport.reset_mock();self.current.reset_mock()
    def test_durable_claim_precedes_exact_mode_request(self):
        def opened(request,timeout):
            self.assertEqual(self.store.read()[0]['phase'],'mode_pending');self.assertEqual(timeout,20)
            self.assertEqual(request.full_url,'https://i.weread.qq.com/trans/pdfepub?cbid=900001&transFormat=epubTranslate&transType=epubTranslate')
            self.assertEqual(request.get_method(),'GET');self.assertIsNone(request.data)
            self.assertEqual(request.get_header('Vid'),'900000');self.assertEqual(request.get_header('Accesstoken'),self.grant['accessToken'])
            return Reply(b'{"succ":1}')
        self.transport.open.side_effect=opened
        _,parsed=send_once(self.store,self.receipt,'mode',self.grant,current=self.current,opener=self.transport)
        self.assertTrue(parsed);self.assertEqual(self.current.call_count,2);self.assertEqual(self.transport.open.call_count,1)
    def test_generation_exact_single_chapter_empty_array_no_trial(self):
        self.ready_generation();self.receipt,parsed=self.send(b'{"stopPoll":true,"curStatus":[{"uid":1,"translateVersion":2}]}',op='generation')
        request=self.transport.open.call_args.args[0]
        self.assertEqual(request.full_url,'https://i.weread.qq.com/en/bookread');self.assertEqual(request.get_method(),'POST')
        self.assertEqual(json.loads(request.data),dict(bookId='900001',read=[dict(uid=1,translateVersion=0)],reference=dict(uid=1,texts=[]),freeTrial=0))
        self.assertEqual(parsed,dict(kind='ready',version=2));self.assertEqual(self.store.read()[0]['requests'],['mode','generation'])
    def test_raw_error_is_saved_before_api_semantics(self):
        with self.assertRaisesRegex(ValueError,'rejected'):self.send(b'{"succ":0,"errcode":17}')
        ack=self.store.read()[0]['acks'][0];self.assertEqual(ack['response'],dict(succ=0,errcode=17))
        self.assertEqual(base64.b64decode(ack['wire']['body_base64']),b'{"succ":0,"errcode":17}')
        with self.assertRaises(ValueError):self.store.claim(self.store.read()[1],'generation')
    def test_http_error_body_is_saved_even_if_it_claims_success(self):
        error=HTTPError('https://example.invalid',503,'synthetic',{},io.BytesIO(b'{"succ":1}'))
        self.transport.open.side_effect=error
        with self.assertRaisesRegex(ValueError,'http_unconfirmed'):send_once(self.store,self.receipt,'mode',self.grant,current=self.current,opener=self.transport)
        state,r=self.store.read();self.assertEqual(state['acks'][0]['wire']['http_status'],503)
        with self.assertRaises(StoreError):self.store.claim(r,'generation')
        self.assertEqual(self.transport.open.call_count,1)
    def test_redirect_is_a_consumed_unconfirmed_receipt_not_a_second_request(self):
        with self.assertRaisesRegex(ValueError,'http_unconfirmed'):self.send(b'redirect',status=302)
        self.assertEqual(self.transport.open.call_count,1);self.assertEqual(self.store.read()[0]['requests'],['mode'])
    def test_nonjson_duplicate_keys_and_array_receipts_are_retained_unknown(self):
        for raw in (b'<html>unavailable</html>',b'{"succ":0,"succ":1}',b'[1]',b'{"succ":NaN}',b'\xff'):
            self.setUp()
            with self.subTest(raw=raw),self.assertRaises(ValueError):self.send(raw)
            ack=self.store.read()[0]['acks'][0];self.assertEqual(ack['response'],{})
            self.assertEqual(base64.b64decode(ack['wire']['body_base64']),raw)
            with self.assertRaises(ValueError):self.store.claim(self.store.read()[1],'generation')
    def test_oversize_is_bounded_prefix_with_truncation_and_no_next_operation(self):
        with self.assertRaisesRegex(ValueError,'http_unconfirmed'):self.send(b'x'*(MAX_WIRE+100))
        ack=self.store.read()[0]['acks'][0]
        self.assertTrue(ack['wire']['body_truncated']);self.assertEqual(len(base64.b64decode(ack['wire']['body_base64'])),MAX_WIRE)
        self.assertEqual(self.reply.limit,MAX_WIRE+1);self.assertTrue(self.reply.closed)
        with self.assertRaises(StoreError):self.store.claim(self.store.read()[1],'generation')
    def test_transport_loss_never_retries_or_releases_claim(self):
        for error in (TimeoutError(),URLError('synthetic loss')):
            self.setUp();self.transport.open.side_effect=error
            with self.assertRaises(type(error)):send_once(self.store,self.receipt,'mode',self.grant,current=self.current,opener=self.transport)
            state,r=self.store.read();self.assertEqual(state['phase'],'mode_pending');self.assertEqual(state['acks'],[])
            with self.assertRaises(StoreError):send_once(self.store,r,'mode',self.grant,current=self.current,opener=self.transport)
            self.assertEqual(self.transport.open.call_count,1)
    def test_old_receipt_wrong_grant_and_unknown_operation_never_open_transport(self):
        for operation,grant in (('auth',self.grant),('mode',dict(self.grant,accessToken='other')),('mode',dict(self.grant,vid='900002'))):
            with self.assertRaises(ValueError):send_once(self.store,self.receipt,operation,grant,current=self.current,opener=self.transport)
        self.transport.open.assert_not_called();self.assertEqual(self.store.read()[0]['phase'],'prepared')
        self.receipt,_=self.send();self.transport.reset_mock()
        with self.assertRaises(StoreError):send_once(self.store,self.receipt,'mode',self.grant,current=self.current,opener=self.transport)
        self.transport.open.assert_not_called()
    def test_context_loss_before_claim_does_not_consume_or_send(self):
        self.current.side_effect=ValueError('changed')
        with self.assertRaises(ValueError):self.send()
        self.transport.open.assert_not_called();self.assertEqual(self.store.read()[0]['phase'],'prepared')
    def test_context_loss_after_claim_remains_pending_without_sending(self):
        self.current.side_effect=[None,ValueError('changed')]
        with self.assertRaises(ValueError):self.send()
        self.transport.open.assert_not_called();self.assertEqual(self.store.read()[0]['phase'],'mode_pending')
    def test_claim_save_readback_failure_never_sends(self):
        def broken(data):self.backend.data=b'{}'
        self.backend.save=broken
        with self.assertRaises(StoreError):self.send()
        self.transport.open.assert_not_called()
    def test_ack_save_failure_remains_nonreplayable(self):
        original=self.backend.save
        def save(data):
            if json.loads(data)['phase']=='mode_responded':raise OSError('synthetic save failure')
            original(data)
        self.backend.save=save
        with self.assertRaises(OSError):self.send()
        state,r=self.store.read();self.assertEqual(state['phase'],'mode_pending')
        with self.assertRaises(StoreError):self.store.claim(r,'mode')
        self.assertEqual(self.transport.open.call_count,1)
    def test_semantic_parser_runs_after_exact_ack_readback(self):
        def interpret(raw,plan):
            ack=self.store.read()[0]['acks'][0];self.assertEqual(ack['response'],raw);self.assertIn('wire',ack);return True
        with patch('translation_dispatch.mode_ack',side_effect=interpret):self.send()
    def test_close_failure_cannot_discard_an_available_receipt(self):
        reply=Reply(b'{"succ":1}');reply.close=Mock(side_effect=OSError('close'))
        self.send(reply=reply);self.assertEqual(self.store.read()[0]['phase'],'mode_responded')
    def test_unknown_generation_keeps_both_claims_and_raw_receipt(self):
        self.ready_generation()
        with self.assertRaises(ValueError):self.send(b'{"unexpected":true}',op='generation')
        state,r=self.store.read();self.assertEqual(state['phase'],'submitted');self.assertEqual(state['acks'][1]['response'],dict(unexpected=True))
        with self.assertRaises(StoreError):self.store.claim(r,'generation')
    def test_changed_raw_or_parsed_ack_is_detected_on_reopen(self):
        self.send();state=self.store.read()[0];state['acks'][0]['response']['succ']=0
        self.backend.data=canonical(state)
        with self.assertRaises(StoreError):self.store.read()
    def test_two_maximum_wire_receipts_fit_keychain_boundary(self):
        raw=json.dumps(dict(succ=1,padding='x'*(MAX_WIRE-50))).encode();self.assertLessEqual(len(raw),MAX_WIRE)
        self.receipt,_=self.send(raw)
        self.receipt,parsed=self.send(json.dumps(dict(stopPoll=False,padding='x'*(MAX_WIRE-50))).encode(),op='generation')
        self.assertLess(len(self.backend.data),MAX_BYTES);self.assertEqual(parsed['kind'],'pending')
    def test_legacy_semantic_ack_cannot_authorize_live_transport(self):
        r=self.store.claim(self.receipt,'mode');self.receipt=self.store.acknowledge(r,'mode',{'succ':1})
        with self.assertRaisesRegex(ValueError,'mode_wire_required'):self.send(op='generation')
        self.transport.open.assert_not_called();self.assertEqual(self.store.read()[0]['phase'],'mode_responded')
    def test_original_proof_is_frozen_idempotent_and_not_replaceable(self):
        self.receipt=self.store.bind_proof(self.receipt,self.proof)
        self.assertEqual(self.store.bind_proof(self.receipt,self.proof),self.receipt)
        with self.assertRaises(StoreError):self.store.bind_proof(self.receipt,dict(self.proof,original_text_sha256='b'*64))
        self.receipt=self.store.claim(self.receipt,'mode')
        with self.assertRaises(StoreError):self.store.bind_proof(self.receipt,self.proof)
    def test_corrupt_proof_presence_and_types_rejected(self):
        self.store.bind_proof(self.receipt,self.proof);state=self.store.read()[0]
        state['proof']['translation_fields_before']['hasTranslated']=1;self.backend.data=canonical(state)
        with self.assertRaises(StoreError):self.store.read()
    def test_maximum_wires_and_frozen_baseline_fit_actual_keychain_limit(self):
        baseline=dict(padding='x'*(16*1024-32));self.plan['baseline_sha256']=digest(baseline)
        self.backend=Backend();self.store=TranslationGenerationStore(self.backend);self.receipt=self.store.reserve(self.plan)
        self.receipt=self.store.bind_proof(self.receipt,dict(self.proof,baseline=baseline))
        self.receipt,_=self.send(json.dumps(dict(succ=1,padding='x'*(MAX_WIRE-50))).encode())
        self.send(json.dumps(dict(stopPoll=False,padding='x'*(MAX_WIRE-50))).encode(),op='generation')
        self.assertLess(len(self.backend.data),MAX_BYTES)
    def test_mismatching_or_oversized_baseline_cannot_be_bound(self):
        for baseline in (dict(changed=1),dict(padding='x'*(16*1024))):
            with self.assertRaises(ValueError):self.store.bind_proof(self.receipt,dict(self.proof,baseline=baseline))
        self.assertNotIn('proof',self.store.read()[0]);self.transport.open.assert_not_called()


class WireTest(unittest.TestCase):
    def test_strict_envelope_and_canonical_base64(self):
        valid=capture(200,b'{"succ":1}')
        for change in (dict(http_status=True),dict(http_status=600),dict(body_base64='!!'),dict(body_truncated=1),dict(extra=1),dict(body_truncated=True)):
            with self.assertRaises(ValueError):response(dict(valid,**change))
        self.assertTrue(successful_http(valid));self.assertFalse(successful_http(capture(401,b'{}')))
    def test_deep_or_invalid_unicode_json_does_not_lose_wire_bytes(self):
        for raw in (b'['*1500+b'0'+b']'*1500,b'{"x":"\\ud800"}'):
            wire=capture(200,raw);self.assertEqual(response(wire),{});self.assertEqual(base64.b64decode(wire['body_base64']),raw)


if __name__=='__main__':unittest.main()
