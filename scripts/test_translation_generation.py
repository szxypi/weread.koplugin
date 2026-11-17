"""Official translation admission, durable no-replay and read-only boundaries."""
import contextlib,copy,io,json,unittest
from unittest.mock import patch,Mock
from annotation_experiment_model import digest
from translation_generation import bind,validate,generation_body,mode_query,status,mode_ack,content_verified
from secure_translation_generation import TranslationGenerationStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from verify_translation_generation import main,Native,Web,inspect
from verify_translation_preflight import TranslationWebProbe,TranslationError
from verify_translation_preflight import catalog
from verify_eink_login import BASE


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.grant=dict(vid='900000',accessToken='synthetic-access')
        self.member=dict(paying=True)
        self.chapter=dict(uid=1,wordCount=1000,free_or_owned=True,hasTranslated=True,translateVersion=0)
        self.catalog=dict(book_id='900001',format='epub',version=12,chapters=[self.chapter])
        self.source='<html><body><p>'+'Original words. '*80+'</p></body></html>'
        self.baseline=dict(counts=dict(readingTime=0),point='synthetic')
    def plan(self):return bind('900000',self.grant,self.member,self.catalog,self.chapter,self.source,self.baseline)
    def test_complete_one_chapter_request_uses_empty_array_and_no_trial(self):
        p=self.plan();body=generation_body(p)
        self.assertEqual(body,dict(bookId='900001',read=[dict(uid=1,translateVersion=0)],reference=dict(uid=1,texts=[]),freeTrial=0))
        self.assertEqual(mode_query(p),dict(cbid='900001',transFormat='epubTranslate',transType='epubTranslate'))
        self.assertNotIn('synthetic-access',json.dumps(p))
    def test_membership_must_be_explicit_paid(self):
        for member in ({},dict(paying=False),dict(paying=1),dict(paying='true')):
            self.member=member
            with self.subTest(member=member),self.assertRaises(ValueError):self.plan()
    def test_owner_and_catalogue_identity_strict(self):
        for key,value in [('vid','900002'),('vid',900000)]:
            self.grant[key]=value
            with self.assertRaises(ValueError):self.plan()
        self.setUp()
        for value in ('CB_900001','0900001',True):
            self.catalog['book_id']=value
            with self.assertRaises(ValueError):self.plan()
    def test_only_explicit_free_or_owned_chapter_is_admitted(self):
        for value in (False,None,1,'true'):
            self.chapter['free_or_owned']=value
            with self.subTest(value=value),self.assertRaises(ValueError):self.plan()
    def test_chapter_must_be_unique_and_in_observed_catalogue(self):
        self.catalog['chapters']*=2
        with self.assertRaises(ValueError):self.plan()
        self.catalog['chapters']=[]
        with self.assertRaises(ValueError):self.plan()
        self.catalog['chapters']=[self.chapter,dict(self.chapter,wordCount=2000)]
        with self.assertRaises(ValueError):self.plan()
    def test_content_not_metadata_decides_missing_translation(self):
        self.chapter.update(hasTranslated=True,transWordCount=900)
        self.plan()
        self.source+='<p class="wr-translation">现有译文</p>'
        with self.assertRaisesRegex(ValueError,'already_available'):self.plan()
    def test_original_text_and_format_required(self):
        for source in ('','<script>'+'x'*500+'</script>','<p>'+(' '*500)+'</p>',
                '<html><head><title>'+'x'*500+'</title></head><body></body></html>',
                '<html><head><title>'+'x'*500+'</title></head></html>'):
            self.source=source
            with self.subTest(source=source[:12]),self.assertRaises(ValueError):self.plan()
        self.setUp();self.catalog['format']='pdf'
        with self.assertRaises(ValueError):self.plan()
    def test_bad_versions_and_uid_never_coerced(self):
        for target,key in ((self.catalog,'version'),(self.chapter,'translateVersion'),(self.chapter,'uid')):
            before=target[key]
            for value in (True,-1,'1',1.5,2147483648):
                target[key]=value
                with self.subTest(key=key,value=value),self.assertRaises(ValueError):self.plan()
            target[key]=before
    def test_plan_strict_fields_and_hashes(self):
        p=self.plan()
        for change in (dict(p,extra=1),dict(p,source_sha256='x'*64),dict(p,chapter_uid=0)):
            with self.assertRaises(ValueError):validate(change)
        q=validate(p);q['owner']='900009';self.assertEqual(p['owner'],'900000')
    def test_all_baseline_dimensions_bound(self):
        p=self.plan();self.baseline['point']='changed';self.assertNotEqual(self.plan()['baseline_sha256'],p['baseline_sha256'])
        self.assertEqual(p['source_sha256'],digest(self.source));self.assertEqual(p['catalog_sha256'],digest(self.catalog))
    def test_explicit_mode_ack_required(self):
        for raw in ({},{'succ':'1'},{'status':1},{'succ':1,'errcode':1},{'succ':1,'errCode':False}):
            with self.subTest(raw=raw),self.assertRaises(ValueError):mode_ack(raw)
        self.assertTrue(mode_ack({'succ':True}));self.assertTrue(mode_ack({'succ':1,'errcode':0}))
    def test_ready_requires_stopped_current_positive_version(self):
        p=self.plan();value=dict(stopPoll=1,curStatus=[dict(uid=1,translateVersion=2)])
        self.assertEqual(status(value,p),dict(kind='ready',version=2))
        self.assertEqual(status(dict(value,stopPoll=0),p)['kind'],'pending')
        self.assertEqual(status(dict(stopPoll=True,curStatus=[]),p)['kind'],'stopped_unavailable')
        self.assertEqual(status(dict(stopPoll=True,curStatus=[dict(uid=1,translateVersion=0)]),p)['kind'],'stopped_unavailable')
    def test_progress_only_is_pending_not_success(self):
        self.assertEqual(status(dict(translationProgress=100),self.plan())['kind'],'pending')
        with self.assertRaises(ValueError):status(dict(curStatus=[]),self.plan())
    def test_wrong_duplicate_regressed_chapter_status_rejected(self):
        p=self.plan();p['translate_version']=3
        for rows in ([dict(uid=2,translateVersion=4)],[dict(uid=1,translateVersion=4)]*2,[dict(uid=1,translateVersion=2)]):
            with self.subTest(rows=rows),self.assertRaises(ValueError):status(dict(stopPoll=1,curStatus=rows),p)
    def test_unknown_flags_counters_and_nested_error_rejected(self):
        for value in ({'stopPoll':'1'},{'stopPoll':True,'translationProgress':True},{'translationProgress':101},
                {'stopPoll':None,'translationProgress':1},{'succ':False,'stopPoll':False},
                {'stopPoll':False,'curStatus':{}},{'stopPoll':False,'tips':[]},
                {'data':{'errcode':1,'stopPoll':False}},{'data':{},'result':{}},{'stopPoll':False,'errCode':-1}):
            with self.subTest(value=value),self.assertRaises(ValueError):status(value,self.plan())
        self.assertEqual(status({'data':{'stopPoll':False}},self.plan())['kind'],'pending')
    def test_actual_text_is_independent_from_ready(self):
        self.assertFalse(content_verified(self.source))
        self.assertFalse(content_verified('<p class="wr-translation"><img src="x"/></p>'))
        self.assertTrue(content_verified('<p class="wr-translation">译文</p>'))
    def test_wrong_book_or_owner_in_any_response_layer_rejected(self):
        for value in ({'bookId':'900002','stopPoll':False},{'data':{'vid':'900002','stopPoll':False}},
                {'stopPoll':True,'curStatus':[{'uid':1,'translateVersion':2,'bookId':'900002'}]}):
            with self.subTest(value=value),self.assertRaises(ValueError):status(value,self.plan())
        with self.assertRaises(ValueError):mode_ack({'succ':1,'bookId':'900002'},self.plan())


class StoreTest(unittest.TestCase):
    setUp=PlanTest.setUp
    plan=PlanTest.plan
    def test_claims_are_durable_ordered_and_never_repeat(self):
        backend=Backend();store=TranslationGenerationStore(backend);receipt=store.reserve(self.plan())
        with self.assertRaises(StoreError):store.claim(receipt,'generation')
        receipt=store.claim(receipt,'mode');reopened=TranslationGenerationStore(backend)
        self.assertEqual(reopened.read()[0]['phase'],'mode_pending')
        with self.assertRaises(StoreError):reopened.claim(receipt,'mode')
        receipt=store.acknowledge(receipt,'mode',{'succ':1})
        receipt=store.claim(receipt,'generation');receipt=store.acknowledge(receipt,'generation',{'translationProgress':0})
        value=store.read()[0];self.assertEqual(value['phase'],'submitted');self.assertEqual(value['requests'],['mode','generation'])
        for op in ('mode','generation'):
            with self.assertRaises(StoreError):store.claim(receipt,op)
        with self.assertRaises(StoreError):store.reserve(self.plan())
    def test_unknown_response_saved_before_interpretation(self):
        store=TranslationGenerationStore(Backend());r=store.reserve(self.plan());r=store.claim(r,'mode')
        r=store.acknowledge(r,'mode',{'unrecognized':'synthetic'})
        self.assertEqual(store.read()[0]['acks'][0]['response'],{'unrecognized':'synthetic'})
        with self.assertRaises(ValueError):store.claim(r,'generation')
    def test_unknown_generation_receipt_retained_without_replay(self):
        s=TranslationGenerationStore(Backend());r=s.reserve(self.plan());r=s.claim(r,'mode');r=s.acknowledge(r,'mode',{'succ':1});r=s.claim(r,'generation')
        r=s.acknowledge(r,'generation',{'unknown':True});self.assertEqual(s.read()[0]['acks'][1]['response'],{'unknown':True})
        with self.assertRaises(StoreError):s.claim(r,'generation')
    def test_replaced_receipt_and_damaged_record_fail_closed(self):
        backend=Backend();s=TranslationGenerationStore(backend);r=s.reserve(self.plan());s.claim(r,'mode')
        with self.assertRaises(StoreError):s.claim(r,'mode')
        value=json.loads(backend.data);value['requests']=[];backend.data=json.dumps(value).encode()
        with self.assertRaises(StoreError):s.read()
    def test_failed_claim_readback_does_not_grant_network(self):
        class Broken(Backend):
            def save(self,data):super().save(data);self.data=b'{}'
        with self.assertRaises(StoreError):TranslationGenerationStore(Broken()).reserve(self.plan())
    def test_wrong_mode_book_receipt_is_retained_without_generation_claim(self):
        s=TranslationGenerationStore(Backend());r=s.reserve(self.plan());r=s.claim(r,'mode');r=s.acknowledge(r,'mode',{'succ':1,'bookId':'900002'})
        with self.assertRaises(ValueError):s.claim(r,'generation')
        self.assertEqual(s.read()[0]['requests'],['mode'])
    def test_large_receipt_stops_with_original_claim_preserved(self):
        s=TranslationGenerationStore(Backend());r=s.reserve(self.plan());r=s.claim(r,'mode')
        with self.assertRaises(StoreError):s.acknowledge(r,'mode',{'body':'x'*(24*1024)})
        self.assertEqual(s.read()[0]['phase'],'mode_pending')
    def test_two_maximum_receipts_fit_actual_keychain_limit(self):
        from secure_weread_session import MAX_BYTES
        backend=Backend();s=TranslationGenerationStore(backend);r=s.reserve(self.plan());r=s.claim(r,'mode')
        r=s.acknowledge(r,'mode',{'succ':1,'padding':'x'*(23*1024)});r=s.claim(r,'generation')
        s.acknowledge(r,'generation',{'stopPoll':False,'padding':'x'*(23*1024)})
        self.assertLess(len(backend.data),MAX_BYTES);self.assertEqual(s.read()[0]['phase'],'submitted')


class GuardTest(unittest.TestCase):
    def test_default_is_offline_and_never_opens_credentials(self):
        with patch('verify_translation_generation.SessionStore') as session,patch('verify_translation_generation.NativeSessionStore') as native,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0);session.assert_not_called();native.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_preparer_cannot_change_mode_generate_purchase_or_renew(self):
        api=Native();api.allowed_ids={'900001'}
        bad=[('mode',BASE+'/trans/pdfepub?cbid=900001&transFormat=epubTranslate&transType=epubTranslate',None),
            ('generation',BASE+'/en/bookread',{'bookId':'900001'}),('refresh',BASE+'/auth',{}),('purchase',BASE+'/pay/book',{})]
        for stage,url,body in bad:
            with self.subTest(stage=stage),self.assertRaises(TranslationError):api.guard(stage,url,body)
        api.guard('progress',BASE+'/book/getProgress?bookId=900001',None)
        with self.assertRaises(TranslationError):api.guard('progress',BASE+'/book/getProgress?bookId=900002',None)
    def test_web_preparer_cannot_write_or_follow_unrelated_positions(self):
        api=Web();api.authenticated=True;api.book_id='900001'
        api.guard('progress','https://weread.qq.com/web/book/getProgress?bookId=900001',None)
        for stage,url,body in [('progress','https://weread.qq.com/web/book/getProgress?bookId=900002',None),
            ('mode','https://weread.qq.com/web/reader/toggleTranslate',{}),('read','https://weread.qq.com/web/book/enRead',{})]:
            with self.assertRaises(TranslationError):api.guard(stage,url,body)
        api.close()
    def test_explicit_chapter_cannot_escape_free_or_owned_set(self):
        api=TranslationWebProbe();sample={'expected':{'chapters':[{'uid':1,'wordCount':1000,'free_or_owned':False}]}}
        with self.assertRaises(TranslationError):api.inspect_content(sample,1)
        self.assertIsNone(api.content_sample);api.close()


class InspectionTest(unittest.TestCase):
    def setUp(self):
        self.grant={'vid':'900000','accessToken':'synthetic'}
        self.info=dict(bookId='900001',format='epub',version=12)
        self.raw=dict(data=[dict(bookId='900001',updated=[dict(chapterUid=1,wordCount=1000,price=0,paid=0,hasTranslated=True)])])
        self.model=catalog(self.raw,'900001',self.info)
        self.api=Mock();self.api.member={'paying':True};self.api.samples=[dict(book_id='900001',expected=self.model)]
        self.api.request.side_effect=lambda stage,*a,**k:self.info if stage=='book' else self.raw
        self.web=Mock();self.web.vid='900000'
        self.web.content_sample=dict(book_id='900001',chapter_uid=1,source='<p>'+'Original content '*80+'</p>')
        self.web.inspect_content.return_value=dict(content_decoded=True,nonempty_translation_blocks=0)
        self.baseline=dict(counts=0,position='synthetic')
    def test_two_observations_are_required_before_plan(self):
        report={}
        with patch('verify_translation_generation.snapshot',return_value=self.baseline) as observed:
            plan=inspect(self.api,self.web,self.grant,report)
        self.assertEqual(observed.call_count,2);self.assertEqual(self.web.inspect_content.call_count,2)
        self.assertTrue(report['positions_counts_shelf_stable']);self.assertEqual(plan['chapter_uid'],1)
    def test_changed_baseline_stops_before_reserve(self):
        with patch('verify_translation_generation.snapshot',side_effect=[self.baseline,dict(counts=1)]):
            with self.assertRaisesRegex(ValueError,'baseline_changed'):inspect(self.api,self.web,self.grant,{})
    def test_changed_catalogue_stops(self):
        self.raw['data'][0]['updated'][0]['wordCount']=1001
        with patch('verify_translation_generation.snapshot',return_value=self.baseline):
            with self.assertRaisesRegex(ValueError,'catalog_changed'):inspect(self.api,self.web,self.grant,{})
    def test_available_text_does_not_reserve_a_generation(self):
        self.web.inspect_content.return_value['nonempty_translation_blocks']=1
        with patch('verify_translation_generation.snapshot') as observed:
            with self.assertRaisesRegex(ValueError,'no_missing_sample'):inspect(self.api,self.web,self.grant,{})
        observed.assert_not_called()
    def test_reopened_plan_rejects_changed_grant(self):
        with patch('verify_translation_generation.snapshot',return_value=self.baseline):
            plan=inspect(self.api,self.web,self.grant,{})
            with self.assertRaisesRegex(ValueError,'plan_changed'):inspect(self.api,self.web,dict(self.grant,accessToken='changed'),{},plan)


if __name__=='__main__':unittest.main()
