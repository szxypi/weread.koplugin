import contextlib,copy,io,json,unittest
from unittest.mock import Mock,patch
import test_translation_generation as fixtures
from test_secure_native_session import Backend,credentials
from test_translation_dispatch import Reply
from translation_result import original_signature,catalog_result,make_proof,restore_catalog
from translation_wire import capture
from secure_translation_generation import TranslationGenerationStore
from verify_translation_preflight import catalog
from verify_translation_dispatch import main,journal_report,read_result


class ResultTest(unittest.TestCase):
    def test_original_text_ignores_only_translation_and_nonbody_markup(self):
        original='<html><head><title>ignored</title></head><body><p>'+'Original punctuation! '*20+'</p></body></html>'
        translated=original.replace('</p>','</p><p class="wr-translation"><span>译文正文。</span></p>')
        self.assertEqual(original_signature(original),original_signature(translated))
        self.assertNotEqual(original_signature(original),original_signature(original.replace('punctuation!','punctuation?')))
        with self.assertRaises(ValueError):original_signature('<p class="wr-translation">'+'译文'*100+'</p>')
    def test_other_chapter_price_book_or_original_metadata_changes_rejected(self):
        before=dict(book_id='900001',format='epub',version=12,chapters=[dict(uid=1,wordCount=500,free_or_owned=True,translateVersion=0),dict(uid=2,wordCount=600)])
        after=copy.deepcopy(before);after['chapters'][0].update(translateVersion=2,hasTranslated=True,transWordCount=500)
        self.assertEqual(catalog_result(before,after,1),2)
        for changed in (dict(after,version=13),dict(after,book_id='900002'),dict(after,format='pdf')):
            with self.assertRaises(ValueError):catalog_result(before,changed,1)
        changed=copy.deepcopy(after);changed['chapters'][1]['translateVersion']=1
        with self.assertRaises(ValueError):catalog_result(before,changed,1)
        changed=copy.deepcopy(after);changed['chapters'][0]['free_or_owned']=False
        with self.assertRaises(ValueError):catalog_result(before,changed,1)
    def test_duplicate_uid_or_version_regression_rejected(self):
        before=dict(chapters=[dict(uid=1,translateVersion=2)])
        for after in (dict(chapters=[]),dict(chapters=before['chapters']*2),dict(chapters=[dict(uid=1,translateVersion=1)])):
            with self.assertRaises(ValueError):catalog_result(before,after,1)
    def test_compact_proof_restores_only_the_selected_translation_fields(self):
        from annotation_experiment_model import digest
        before=dict(chapters=[dict(uid=1,wordCount=500),dict(uid=2,wordCount=600)])
        plan=dict(chapter_uid=1,translate_version=0,catalog_sha256=digest(before))
        proof=make_proof(before,plan,'a'*64)
        after=copy.deepcopy(before);after['chapters'][0].update(hasTranslated=True,translateVersion=2)
        self.assertEqual(restore_catalog(after,plan,proof),before)
        changed=copy.deepcopy(after);changed['chapters'][1]['wordCount']=601
        with self.assertRaises(ValueError):restore_catalog(changed,plan,proof)
        bad=copy.deepcopy(proof);bad['translation_fields_before']['transWordCount']=0
        with self.assertRaises(ValueError):restore_catalog(after,plan,bad)


class CommandTest(unittest.TestCase):
    def setUp(self):
        f=fixtures.PlanTest();f.setUp();self.grant=credentials();f.grant=self.grant
        self.info=dict(bookId='900001',format='epub',version=12)
        row=dict(chapterUid=1,wordCount=1000,price=0,paid=0,hasTranslated=False,translateVersion=0)
        raw=dict(data=[dict(bookId='900001',updated=[row])])
        self.model=catalog(raw,'900001',self.info);f.catalog=self.model;f.chapter=self.model['chapters'][0]
        self.plan=f.plan();self.baseline=f.baseline;self.source=f.source;self.translated=self.source.replace('</body>','<p class="wr-translation">实际合成译文。</p></body>')
        self.after=copy.deepcopy(raw);self.after['data'][0]['updated'][0].update(hasTranslated=True,translateVersion=2,transWordCount=1000)
        self.store=TranslationGenerationStore(Backend());self.receipt=self.store.reserve(self.plan)
        self.session=Mock();self.session.load.side_effect=lambda:dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'))
        self.native=Mock();self.native.load.side_effect=lambda *a:copy.deepcopy(self.grant)
        self.web=Mock();self.web.report=dict(stages=[]);self.web.content_sample=dict(source=self.source,chapter_uid=1,book_id='900001')
        self.web.authenticated=True
        def content(*a):
            self.web.content_sample=dict(source=self.translated,chapter_uid=1,book_id='900001')
            return dict(content_decoded=True,nonempty_translation_blocks=1)
        self.web.inspect_content.side_effect=content
        self.api=Mock();self.api.samples=[dict(book_id='900001',expected=self.model)];self.api.report=dict(stages=[])
        self.api.request.side_effect=lambda stage,*a,**k:copy.deepcopy(self.info if stage=='book' else self.after)
        self.transport=Mock()
        self.transport.open.side_effect=lambda request,**kw:Reply(b'{"succ":1}' if request.get_method()=='GET' else b'{"stopPoll":true,"curStatus":[{"uid":1,"translateVersion":2}]}')
        self.preflight_effect=None
    def run_command(self,args):
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch('verify_translation_dispatch.SessionStore',return_value=self.session))
            stack.enter_context(patch('verify_translation_dispatch.NativeSessionStore',return_value=self.native))
            for target in ('NativeCaptureStore','CaptureStore'):
                stack.enter_context(patch('verify_translation_dispatch.'+target,return_value=Mock(read=Mock(return_value=(None,None)))))
            stack.enter_context(patch('verify_translation_dispatch.TranslationGenerationStore',return_value=self.store))
            stack.enter_context(patch('verify_translation_dispatch.Native',return_value=self.api))
            stack.enter_context(patch('verify_translation_dispatch.Web',return_value=self.web))
            self.inspection=stack.enter_context(patch('verify_translation_dispatch.inspect',return_value=self.plan,side_effect=self.preflight_effect))
            self.snapshot=stack.enter_context(patch('verify_translation_dispatch.snapshot',return_value=copy.deepcopy(self.baseline)))
            stack.enter_context(patch('verify_translation_dispatch.save_refreshed_web_session'))
            self.builder=stack.enter_context(patch('verify_translation_dispatch.build_opener',return_value=self.transport))
            output=stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            code=main(args);result=json.loads(output.getvalue())
        return code,result
    def test_offline_default_never_opens_store_or_transport(self):
        with patch('verify_translation_dispatch.SessionStore') as store,patch('verify_translation_dispatch.TranslationGenerationStore') as intent,\
                patch('verify_translation_dispatch.build_opener') as transport,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0);store.assert_not_called();intent.assert_not_called();transport.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_explicit_access_operation_and_selector_boundaries(self):
        for args in (['--saved-session'],['--apply'],['--saved-session','--apply','--chapter-offset','1'],
                ['--saved-session','--dry-run','--chapter-offset','20000'],['--saved-session','--apply','--mode-only']):
            with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)
    def test_disarmed_prepared_plan_checks_without_claim_or_transport(self):
        code,r=self.run_command(['--saved-session','--dry-run'])
        self.assertEqual(code,0);self.assertEqual(r['result'],'TRANSLATION_DISPATCH_DISARMED_VERIFIED')
        self.assertEqual(self.store.read()[0]['phase'],'prepared');self.transport.open.assert_not_called();self.builder.assert_not_called()
    def test_disarmed_discovery_leaves_absent_intent_absent(self):
        self.store=TranslationGenerationStore(Backend())
        code,r=self.run_command(['--saved-session','--dry-run','--chapter-offset','12'])
        self.assertEqual(code,0);self.assertIsNone(self.store.read()[0]);self.assertFalse(r['durable_intent_present'])
        self.assertEqual(self.inspection.call_args.kwargs['chapter_offset'],12);self.transport.open.assert_not_called()
    def test_mode_only_stops_before_generation(self):
        code,r=self.run_command(['--saved-session','--mode-only'])
        self.assertEqual(code,0);self.assertEqual(r['result'],'MODE_ACK_SAVED_VERIFIED')
        self.assertEqual(r['mode_request_attempts'],1);self.assertEqual(r['generation_request_attempts'],0)
        self.assertEqual(self.store.read()[0]['phase'],'mode_responded');self.web.inspect_content.assert_not_called()
    def test_apply_uses_two_preflights_once_each_and_independent_content_proof(self):
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,0);self.assertEqual(r['result'],'PASS_REAL_SINGLE_CHAPTER_GENERATION')
        self.assertEqual(r['generation_ack_kind'],'ready');self.assertTrue(r['actual_translated_content_read_twice'])
        self.assertTrue(r['generation_status_observed_stopped'])
        self.assertEqual(r['mode_request_attempts'],1);self.assertEqual(r['generation_request_attempts'],1)
        self.assertEqual(self.inspection.call_count,2);self.assertEqual(self.transport.open.call_count,2)
        self.assertEqual(self.web.inspect_content.call_count,2);self.assertEqual(r['journal']['phase'],'submitted')
    def test_generation_only_cannot_repeat_mode(self):
        r=self.store.claim(self.receipt,'mode');self.store.acknowledge(r,'mode',{'succ':1},wire=capture(200,b'{"succ":1}'))
        code,r=self.run_command(['--saved-session','--generation-only'])
        self.assertEqual(code,0);self.assertEqual(r['mode_request_attempts'],0);self.assertEqual(r['generation_request_attempts'],1)
    def test_unknown_mode_ack_stops_and_audits_without_generation(self):
        self.transport.open.side_effect=lambda *a,**k:Reply(b'{"unknown":true}')
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,1);self.assertEqual(r['phase'],'mode');self.assertEqual(r['generation_request_attempts'],0)
        self.assertEqual(r['post_failure_baseline_check'],'match');self.assertEqual(self.store.read()[0]['phase'],'mode_responded')
    def test_changed_between_operations_preflight_stops_before_generation(self):
        self.preflight_effect=[self.plan,ValueError('translation_generation/baseline_changed')]
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,1);self.assertEqual(r['generation_request_attempts'],0)
        self.assertEqual(r['phase'],'between_operations');self.assertEqual(self.transport.open.call_count,1)
        self.assertEqual(self.store.read()[0]['phase'],'mode_responded')
    def test_consumed_journal_never_opens_network(self):
        self.store.claim(self.receipt,'mode')
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,1);self.assertEqual(r['reason'],'translation_trial/consumed');self.transport.open.assert_not_called()
    def test_original_or_baseline_change_cannot_be_success(self):
        self.translated=self.translated.replace('Original words.','Changed words.')
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,1);self.assertEqual(r['reason'],'translation_trial/original_changed')
        self.assertEqual(self.store.read()[0]['phase'],'submitted')
    def test_public_journal_has_no_raw_bodies_or_private_plan(self):
        code,r=self.run_command(['--saved-session','--mode-only']);self.assertEqual(code,0)
        public=json.dumps(r);self.assertNotIn(self.grant['accessToken'],public);self.assertNotIn('body_base64',public)
        self.assertNotIn('900001',public);self.assertNotIn('900000',public);self.assertNotIn('Original words.',public)
        self.assertEqual(journal_report(None)['phase'],'absent')
    def test_pending_not_ready_uses_bounded_readonly_observation_without_resubmit(self):
        self.web.inspect_content.side_effect=None;self.web.inspect_content.return_value=dict(content_decoded=True,nonempty_translation_blocks=0)
        self.web.content_sample=dict(source=self.source)
        wait,current=Mock(),Mock()
        with patch('verify_translation_dispatch.snapshot',return_value=self.baseline):
            with self.assertRaisesRegex(ValueError,'not_ready'):read_result(self.api,self.web,self.grant,self.plan,self.api.samples[0],
                original_signature(self.source),self.baseline,dict(kind='pending',version=None),current=current,wait=wait)
        self.assertEqual(self.web.inspect_content.call_count,6);self.assertEqual(wait.call_count,5)
        self.transport.open.assert_not_called();self.assertEqual(self.store.read()[0]['phase'],'prepared')
    def test_final_catalog_witness_must_be_stable(self):
        reads=[]
        def request(stage,*a,**k):
            if stage=='book':return self.info
            reads.append(1);raw=copy.deepcopy(self.after)
            if len(reads)>1:raw['data'][0]['updated'][0]['wordCount']+=1
            return raw
        self.api.request.side_effect=request
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,1);self.assertEqual(r['reason'],'translation_trial/final_changed')
        self.assertEqual(self.store.read()[0]['phase'],'submitted')
    def test_stopped_unavailable_receipt_is_not_upgraded_by_unrelated_metadata(self):
        self.transport.open.side_effect=lambda request,**kw:Reply(b'{"succ":1}' if request.get_method()=='GET' else b'{"stopPoll":true,"curStatus":[]}')
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,1);self.assertEqual(r['generation_ack_kind'],'stopped_unavailable')
        self.assertEqual(r['reason'],'translation_trial/not_ready');self.assertEqual(self.web.inspect_content.call_count,1)
    def test_readonly_inspection_uses_original_proof_without_replay_or_journal_change(self):
        code,_=self.run_command(['--saved-session','--apply']);self.assertEqual(code,0)
        before=self.store.read()[1];self.transport.reset_mock()
        code,r=self.run_command(['--saved-session','--inspect-result'])
        self.assertEqual(code,0);self.assertEqual(r['result'],'PASS_REAL_GENERATION_READONLY_INSPECTION')
        self.assertTrue(r['journal_unchanged']);self.assertEqual(self.store.read()[1],before)
        self.transport.open.assert_not_called();self.builder.assert_not_called()
    def test_readonly_inspection_does_not_need_an_old_expired_sender_grant(self):
        code,_=self.run_command(['--saved-session','--apply']);self.assertEqual(code,0)
        self.grant['accessToken']='synthetic-new-current-grant';before=self.store.read()[1];self.transport.reset_mock()
        code,r=self.run_command(['--saved-session','--inspect-result'])
        self.assertEqual(code,0);self.assertFalse(r['dispatch_grant_matches_current']);self.assertEqual(self.store.read()[1],before)
        self.transport.open.assert_not_called()
    def test_inspection_without_original_proof_cannot_fabricate_a_baseline(self):
        r=self.store.claim(self.receipt,'mode');r=self.store.acknowledge(r,'mode',{'succ':1},wire=capture(200,b'{"succ":1}'))
        r=self.store.claim(r,'generation');self.store.acknowledge(r,'generation',{'stopPoll':False},wire=capture(200,b'{"stopPoll":false}'))
        before=self.store.read()[1];code,r=self.run_command(['--saved-session','--inspect-result'])
        self.assertEqual(code,1);self.assertEqual(r['reason'],'translation_result/proof')
        self.assertEqual(self.store.read()[1],before);self.transport.open.assert_not_called()
    def test_inspection_cannot_turn_http_failure_into_success(self):
        from annotation_experiment_model import canonical
        code,_=self.run_command(['--saved-session','--apply']);self.assertEqual(code,0)
        state=self.store.read()[0];state['acks'][1]['wire']['http_status']=503;self.store.backend.data=canonical(state)
        before=self.store.read()[1];self.transport.reset_mock();code,r=self.run_command(['--saved-session','--inspect-result'])
        self.assertEqual(code,1);self.assertEqual(self.store.read()[1],before);self.transport.open.assert_not_called()
    def test_available_content_does_not_relabel_a_pending_ack_as_stopped(self):
        self.transport.open.side_effect=lambda request,**kw:Reply(b'{"succ":1}' if request.get_method()=='GET' else b'{"stopPoll":false,"curStatus":[]}')
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,0);self.assertEqual(r['result'],'TRANSLATED_CONTENT_VERIFIED_GENERATION_STATUS_PENDING')
        self.assertFalse(r['generation_status_observed_stopped']);self.assertTrue(r['actual_translated_content_read_twice'])
    def test_stopped_same_chapter_ack_can_supply_an_absent_catalog_version(self):
        self.after['data'][0]['updated'][0].pop('translateVersion')
        code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,0);self.assertEqual(r['translation_version_source'],'stopped_ack')
        self.assertNotIn('translateVersion',self.after['data'][0]['updated'][0])
    def test_explicit_zero_catalog_version_is_not_treated_as_absent(self):
        self.after['data'][0]['updated'][0]['translateVersion']=0;wait=Mock()
        with patch('verify_translation_dispatch.read_result',side_effect=lambda *args,**kw:read_result(*args,**kw,wait=wait)):
            code,r=self.run_command(['--saved-session','--apply'])
        self.assertEqual(code,1);self.assertEqual(r['reason'],'translation_trial/not_ready')
        self.assertEqual(wait.call_count,5);self.assertEqual(self.transport.open.call_count,2)


if __name__=='__main__':unittest.main()
