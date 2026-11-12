"""First-position model, one durable claim and independently checked receipts."""
from contextlib import ExitStack,redirect_stdout,redirect_stderr
from copy import deepcopy
import io,json,time,unittest
from unittest.mock import patch,Mock
from native_initial_position import no_chapter,valid_no_chapter,counts,validate_plan,PROTOCOL
from secure_native_initial_position import NativeInitialPositionStore
from secure_native_txt_roundtrip import point
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from native_initial_fixture import NativeInitialServer
from native_reader_fixture import GRANT,BOOK_ID,GUEST,chapter_txt
from native_txt_read_model import body
from txt_coordinates import PlainSource
from txt_full_summary import digest
from shelf_flag_change_contract import state_hash
from owner_initial_plan_contract import validate_payload,validate_private,decode,FLAGS
from test_owner_unstarted import payload as unstarted_payload
from test_owner_reading import stage as reading_stage
from verify_owner_reading import FRAME
import verify_native_initial_position as task


def original(**fields):return dict(progress=0,chapterUid=0,chapterOffset=0,**fields)


def plan():
    b=no_chapter(original(),BOOK_ID);target=dict(book_id=BOOK_ID,chapter_uid='1',chapter_idx=1,chapter_offset=120,raw_percent=50,summary=PlainSource(chapter_txt(1)).excerpt(120)['text'])
    return dict(protocol=PROTOCOL,owner_sha256=digest(GRANT['vid']),grant_sha256=digest(GRANT),source_sha256='a'*64,catalog_sha256='b'*64,
                shelf_sha256='c'*64,native_shelf_sha256='d'*64,source_file_id='e'*64,baseline=dict(web=deepcopy(b),native=deepcopy(b)),target=target,
                counts=dict(readingTime=0,recordReadingTime=0,ttsTime=0),version=0)


class Web:
    vid=GRANT['vid'];book_id=BOOK_ID
    def __init__(self,server):self.server=server;self.sample=dict(record={})
    def request(self,stage,url,body=None,**options):
        if body is not None:raise AssertionError('write via Web')
        return self.server.route('GET',url,{})[1]


class Api(task.Probe):
    def __init__(self,server,store):super().__init__(GRANT,BOOK_ID);self.server=server;self.store=store
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if credentials!=GRANT:raise AssertionError('grant changed')
        if body is not None:
            if self.posts or stage!='initial_position_write' or digest(body)!=self.expected:raise ValueError('initial_position/dispatch')
            self.claim();assert self.store.read()[0]['phase']=='pending';self.posts+=1
        return self.server.route('POST' if body is not None else 'GET',url,body or {})[1]


class InitialPositionTests(unittest.TestCase):
    def run_case(self,mode='accepted',*,before=None,final_fail=False):
        server=NativeInitialServer(mode);store=NativeInitialPositionStore(Backend());api=Api(server,store);web=Web(server);p=plan()
        p['shelf_sha256']=state_hash(web.request('shelf','https://weread.qq.com/web/shelf/sync'))
        p['native_shelf_sha256']=state_hash(api.request('shelf','https://i.weread.qq.com/shelf/sync',credentials=GRANT))
        r={};store.reserve(p);preflight=Mock(side_effect=before) if before else None
        def source(_web,_plan):
            if final_fail and api.posts:raise ValueError('initial_position/source')
        try:
            with patch.object(task,'verify_source',side_effect=source),patch.object(task.time,'sleep'):
                try:task.run(web,api,GRANT,store,p,GUEST,r,apply=True,current=preflight)
                except Exception:r['stopped']=True
            return p,store,api,r
        finally:server.server_close()
    def test_no_chapter_keeps_presence_separate_from_actual_positions(self):
        absent=no_chapter(original(),BOOK_ID);present=no_chapter(original(chapterIdx=0,summary=''),BOOK_ID)
        self.assertNotIn('chapter_idx',absent);self.assertNotIn('summary',absent)
        self.assertTrue(present['index_present']);self.assertEqual(present['chapter_idx'],0);self.assertNotEqual(absent,present)
        with self.assertRaises(StoreError):point(absent)
    def test_zero_like_contradictory_and_foreign_states_are_not_baselines(self):
        for change in ({'progress':1},{'chapterUid':1},{'chapterOffset':1},{'chapterIdx':1},{'summary':'not empty'},
                       {'chapterOffset':None},{'progress':False},{'chapterUid':'00'},{'bookId':'900002'}):
            v=original();v.update(change)
            with self.subTest(change=change),self.assertRaises((ValueError,StoreError)):no_chapter(v,BOOK_ID)
    def test_baseline_presence_types_and_extra_data_are_closed(self):
        for change in ({'index_present':1},{'summary_present':0},{'summary':'fake'},{'chapter_idx':0},{'raw_percent':False},{'chapter_offset':False},{'extra':'private'}):
            p=plan();p['baseline']['native'].update(change)
            with self.assertRaises(StoreError):validate_plan(p)
    def test_target_is_always_positive_and_initial_scope_has_no_prior_time(self):
        for change in ({'chapter_uid':'0'},{'summary':''},{'raw_percent':True},{'raw_percent':1.5}):
            p=plan();p['target'].update(change)
            with self.assertRaises(StoreError):validate_plan(p)
        p=plan();p['counts']['readingTime']=1
        with self.assertRaises(StoreError):validate_plan(p)
    def test_one_claim_ack_then_independent_retirement(self):
        _p,store,api,r=self.run_case();self.assertEqual(r['result'],'NATIVE_INITIAL_POSITION_VERIFIED')
        self.assertEqual(api.posts,1);self.assertEqual(store.read()[0]['phase'],'retired');self.assertFalse(store.pending())
        self.assertFalse(r['original_no_chapter_restored'])
        with self.assertRaises(StoreError):store.reserve(plan())
    def test_delayed_readback_repeats_only_reads(self):
        _p,store,api,r=self.run_case('delayed');self.assertEqual(store.read()[0]['phase'],'retired');self.assertEqual(api.posts,1)
        self.assertEqual(r['readback_attempts'],2)
    def test_missing_or_rejected_ack_never_promotes_matching_current_state(self):
        for mode in ('noack','rejected'):
            _p,store,api,r=self.run_case(mode);self.assertTrue(r['stopped']);self.assertFalse(r['explicit_success_receipt'])
            self.assertEqual(api.posts,1);self.assertEqual(store.read()[0]['phase'],'pending');self.assertTrue(store.pending())
    def test_changed_counts_and_final_source_failure_keep_real_ack(self):
        for options in (dict(mode='changed_counts'),dict(final_fail=True)):
            _p,store,api,r=self.run_case(**options);self.assertTrue(r['stopped']);self.assertTrue(r['explicit_success_receipt'])
            self.assertEqual(api.posts,1);self.assertEqual(store.read()[0]['phase'],'acknowledged')
    def test_changed_grant_before_dispatch_never_claims(self):
        _p,store,api,r=self.run_case(before=Mock(side_effect=ValueError('initial_position/grant')))
        self.assertTrue(r['stopped']);self.assertEqual(api.posts,0);self.assertEqual(store.read()[0]['phase'],'prepared')
    def test_stale_receipt_cannot_repeat_a_durable_claim(self):
        store=NativeInitialPositionStore(Backend());receipt=store.reserve(plan());claimed=store.advance(receipt,'prepared','pending')
        for old,before,after in ((receipt,'prepared','pending'),(receipt,'pending','acknowledged'),(claimed,'pending','pending')):
            with self.assertRaises(StoreError):store.advance(old,before,after)
        self.assertEqual(store.read()[0]['posts'],1)
    def test_durable_claim_precedes_real_transport_and_network_exception_is_not_replayed(self):
        store=NativeInitialPositionStore(Backend());receipt=store.reserve(plan());api=task.Probe(GRANT,BOOK_ID)
        dto=body(GRANT,plan()['target'],0,GUEST,int(time.time()),123,'+08:00')
        api.expected=digest(dto);api.claim=lambda:store.advance(receipt,'prepared','pending')
        def sending(*_a,**_k):
            self.assertEqual(store.read()[0]['phase'],'pending');raise TimeoutError('synthetic uncertain send')
        with patch.object(task.NativeProbe,'request',side_effect=sending) as wire:
            with self.assertRaises(TimeoutError):api.request('initial_position_write','https://i.weread.qq.com/book/read',dto,GRANT)
            with self.assertRaises(ValueError):api.request('initial_position_write','https://i.weread.qq.com/book/read',dto,GRANT)
        self.assertEqual(wire.call_count,1);self.assertEqual(api.posts,1)
    def test_claim_failure_never_reaches_transport(self):
        api=task.Probe(GRANT,BOOK_ID);dto=body(GRANT,plan()['target'],0,GUEST,int(time.time()),123,'+08:00');api.expected=digest(dto)
        api.claim=Mock(side_effect=StoreError('synthetic keychain failure'))
        with patch.object(task.NativeProbe,'request') as wire,self.assertRaises(StoreError):api.request('initial_position_write','https://i.weread.qq.com/book/read',dto,GRANT)
        wire.assert_not_called();self.assertEqual(api.posts,0)
    def test_unknown_cannot_retire_and_terminal_scope_never_claims_again(self):
        store=NativeInitialPositionStore(Backend());r=store.reserve(plan());r=store.advance(r,'prepared','pending')
        with self.assertRaises(StoreError):store.advance(r,'pending','retired')
        r=store.advance(r,'pending','acknowledged');store.advance(r,'acknowledged','retired')
        with self.assertRaises(StoreError):store.advance(r,'prepared','pending')
    def test_success_receipt_matches_strict_native_rules(self):
        for good in ({'succ':1},{'succ':True,'errcode':0}):self.assertTrue(task.success(good))
        for bad in ({},{'succ':'1'},{'succ':1,'errcode':None},{'succ':1,'errcode':False},{'succ':1,'errCode':1}):self.assertFalse(task.success(bad))
    def test_no_write_grants_are_accepted_by_candidate_reader(self):
        v=unstarted_payload();v['initial_plan_preview']=v.pop('unstarted_preview');v['initial_plan_mock_port']=v.pop('unstarted_mock_port')
        validate_payload(v,12345)
        for k in ('native_grant','permit_writes','native_initial_position'):
            bad=deepcopy(v);bad[k]={}
            with self.assertRaises(ValueError):validate_payload(bad,12345)
    def test_candidate_model_checks_literal_raw_excerpt_and_explicit_index(self):
        p=plan();source=dict(book_id=BOOK_ID,chapter_uid='1',chapter_offset=120,file_id='e'*64,book_version=7,raw_sha256='a'*64,
                          render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=False)
        v=dict(source=source,candidate=p['target']);validate_private(v,raw=chapter_txt(1),chapters=[dict(chapterUid=1,chapterIdx=1)])
        v['candidate']['summary']='wrong literal summary...........'
        with self.assertRaises(ValueError):validate_private(v,raw=chapter_txt(1))
    def test_candidate_worker_frame_requires_closed_fields_and_all_flags(self):
        r=reading_stage();a={k:True for k in FLAGS};a.update(native_denied=0,failed_line=0);r['initial_plan']=a
        v=dict(report=r,cookies=dict(wr_vid='900000',wr_skey='mock_key'),candidate_private={})
        # Missing private candidate is rejected even with all reported flags.
        with self.assertRaises(ValueError):decode(FRAME+json.dumps(v).encode(),'900000')
    def test_global_barrier_can_exclude_only_the_new_scope(self):
        import verify_native_thought_trial as shared
        names=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore','NativeFinishTrialStore',
               'FlagTrialStore','NativeFlagTrialStore','TxtFullSummaryStore','TxtZeroTimeStore','NativeTxtPositionStore','NativeTxtRoundtripStore','RawTxtExcerptStore',
               'NativeReaderTrialStore','NativeCloseTrialStore','NativeTimerTrialStore','NativeInitialPositionStore','NativeInitialReaderStore','InitialMarkStyleStore','NonemptyMarksStore',
               'ReadtimeTrialStore','MarkColorStore','MarkStyleTrialStore','BookmarkTrialStore','HighlightTrialStore')
        with ExitStack() as stack:
            factories={n:stack.enter_context(patch.object(shared,n)) for n in names}
            for factory in factories.values():factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
            factories['NativeInitialPositionStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_native_timer_trial=True));self.assertFalse(shared.other_pending(exclude_native_initial_position=True))
            factories['NativeTimerTrialStore'].return_value.pending.return_value=True;self.assertTrue(shared.other_pending(exclude_native_initial_position=True))
    def test_readonly_inspection_keeps_unknown_original_and_does_not_reclassify_receipt(self):
        server=NativeInitialServer('rejected');store=NativeInitialPositionStore(Backend());api=Api(server,store);web=Web(server);p=plan()
        p['shelf_sha256']=state_hash(web.request('shelf','https://weread.qq.com/web/shelf/sync'))
        p['native_shelf_sha256']=state_hash(api.request('shelf','https://i.weread.qq.com/shelf/sync',credentials=GRANT))
        receipt=store.reserve(p);store.advance(receipt,'prepared','pending');before=store.read()[0]
        try:
            with patch.object(task,'verify_source'):
                r={};task.inspect_current(web,api,GRANT,p,r)
            self.assertEqual(r['current_state'],'original');self.assertEqual(r['independent_observations'],2)
            self.assertEqual(store.read()[0],before);self.assertEqual(api.posts,0);self.assertNotIn('explicit_success_receipt',r)
        finally:server.server_close()
    def test_retired_scope_cannot_reach_any_source_or_request_on_repeat_apply(self):
        p,store,api,_r=self.run_case();web=Mock()
        with patch.object(task,'verify_source') as source,self.assertRaisesRegex(ValueError,'intent'):
            task.run(web,api,GRANT,store,p,GUEST,{},apply=True)
        source.assert_not_called();self.assertEqual(api.posts,1)
    def test_inspection_cli_does_not_accept_a_reader_or_mock_authority(self):
        for args in (['--inspect'],['--mock','--inspect'],['--saved-session','--inspect','--lua-command','synthetic']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)
    def test_default_and_invalid_cli_never_open_credentials_or_http(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'NativeSessionStore') as native,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();native.assert_not_called();child.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for args in (['--saved-session'],['--prepare'],['--lua-command','synthetic']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

if __name__=='__main__':unittest.main()
