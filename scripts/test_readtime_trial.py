"""One real transport boundary, full independent counters and no unknown replay."""
from contextlib import ExitStack,redirect_stdout
from copy import deepcopy
import io,json,unittest
from readtime_trial_model import LEGACY_PROTOCOL
from secure_weread_session import ACCOUNT
from unittest.mock import Mock,patch
from annotation_experiment_model import digest
from secure_readtime_trial import ReadtimeTrialStore
from secure_weread_session import StoreError
from test_eink_login import Opener
from test_secure_native_session import Backend
from test_selection_trial import fixture
from selection_trial_mock import credentials
from verify_native_statistics import period
import verify_native_thought_trial as shared
import verify_readtime_upload as task

NOW=1700007200


def fixture_trial():
    payload,plan=fixture();source=Mock();source.payload=payload;source.plan=plan;source.prepare.return_value=plan
    source.baseline.return_value=deepcopy(plan.baseline);source.web.cookies={}
    source.web.request.return_value=dict(bookId=plan.bound['book_id'],book=dict(bookId=plan.bound['book_id'],version=plan.context['bookVersion']),updated=plan.chapters)
    position=plan.baseline['position'];identity=plan.bound['book_id']
    progress=dict(bookId=identity,timestamp=NOW,book=dict(chapterUid=int(position['chapter_uid']),chapterIdx=position['chapter_idx'],
        chapterOffset=position['chapter_offset'],progress=position['percent'],readingTime=23,recordReadingTime=0,ttsTime=0))
    day=(NOW+28800)//86400*86400-28800
    stats=dict(baseTime=period('monthly',NOW)[0],readTimes={str(day):5},totalReadTime=5,readDays=1)
    after=deepcopy(progress);after['book']['readingTime']+=2;later=deepcopy(stats);later['totalReadTime']+=2;later['readTimes'][str(day)]+=2
    responses=[dict(token='fixture-config'),dict(feature={}),dict(bookId=identity,version=plan.context['bookVersion']),progress,stats,progress,stats,
        progress,stats,dict(succ=1),after,later]
    opener=Opener(responses);clock=[NOW]
    p=task.ReadingTimeTrial(source,ReadtimeTrialStore(Backend()),opener=opener,clock=lambda:clock[0],monotonic=lambda:clock[0],sleep=lambda n:clock.__setitem__(0,clock[0]+n))
    return p,source,opener,clock,progress,stats,after,later


class TrialTests(unittest.TestCase):
    def invoke(self,p,**kwargs):
        with patch.object(task,'reading_position',return_value=p.source.plan.web_position):return p.run(credentials(),**kwargs)

    def test_exact_two_seconds_confirmed_twice_and_originals_preserved(self):
        p,s,op,_c,*_rest=fixture_trial();p.prepare({},{**credentials()});value=self.invoke(p,apply=True)
        self.assertEqual(value['result'],'PASS_PROTOCOL');self.assertEqual(value['book_counter_delta'],2);self.assertEqual(value['daily_bucket_delta'],2)
        self.assertEqual(p.store.read(),(None,None));self.assertEqual(len([r for r in op.requests if r.data is not None]),1)
        request=next(r for r in op.requests if r.data is not None);self.assertEqual(json.loads(request.data),p.body);self.assertIsNone(request.get_header('Cookie'))
        s.writer.request.assert_not_called();self.assertTrue(value['web_and_native_positions_unchanged'])

    def test_same_plan_read_only_then_one_dispatch(self):
        p,_s,op,_c,before,stats,*_r=fixture_trial();op.responses[9:9]=[deepcopy(before),deepcopy(stats)]
        p.prepare({},credentials());original=digest(p.bound);dry=deepcopy(self.invoke(p,apply=False));actual=self.invoke(p,apply=True)
        self.assertEqual(dry['account_data_posts'],0);self.assertEqual(actual['account_data_posts'],1)
        self.assertEqual(digest(p.bound),original);self.assertEqual(p.store.read(),(None,None))

    def test_read_only_has_no_claim_or_write(self):
        p,_s,op,_c,*_r=fixture_trial();p.prepare({},credentials());value=self.invoke(p,apply=False)
        self.assertEqual(value['result'],'PASS_READONLY');self.assertEqual(p.store.read(),(None,None));self.assertTrue(all(r.data is None for r in op.requests))

    def test_reference_success_receipt_alone_is_not_confirmation(self):
        p,_s,op,_c,before,stats,_after,_later=fixture_trial();op.responses=op.responses[:10]+[deepcopy(x) for _i in range(4) for x in (before,stats)]
        p.prepare({},credentials())
        with self.assertRaises(ValueError):self.invoke(p,apply=True)
        self.assertTrue(p.success_receipt);self.assertEqual(p.posts,1);self.assertEqual(p.store.read()[0]['phase'],'claimed')
        count=len(op.requests)
        with self.assertRaises(ValueError):self.invoke(p,apply=True)
        self.assertEqual(len(op.requests),count)

    def test_missing_or_timed_out_receipt_is_unknown_even_if_totals_match(self):
        for receipt in ({},dict(succ='1'),TimeoutError()):
            p,_s,op,_c,*_r=fixture_trial();op.responses[9]=receipt;p.prepare({},credentials())
            with self.subTest(receipt=type(receipt).__name__),self.assertRaises(ValueError):self.invoke(p,apply=True)
            self.assertEqual(p.posts,1);self.assertEqual(p.store.read()[0]['phase'],'claimed');self.assertFalse(p.success_receipt)

    def test_lagged_readback_only_retries_reads(self):
        p,_s,op,_c,before,stats,*_r=fixture_trial();op.responses[10:10]=[deepcopy(before),deepcopy(stats)];p.prepare({},credentials());value=self.invoke(p,apply=True)
        self.assertEqual(value['result'],'PASS_PROTOCOL');self.assertEqual(p.posts,1);self.assertEqual(len([r for r in op.requests if r.data is not None]),1)

    def test_unrelated_counter_or_day_change_stops_unknown(self):
        for field in ('readingTime','recordReadingTime','ttsTime','statistics','readDays'):
            p,_s,op,_c,*_r=fixture_trial()
            if field=='statistics':op.responses[11]['totalReadTime']+=1
            elif field=='readDays':op.responses[11]['readDays']+=2
            else:op.responses[10]['book'][field]+=1
            p.prepare({},credentials())
            with self.subTest(field=field),self.assertRaises(ValueError):self.invoke(p,apply=True)
            self.assertEqual(p.store.read()[0]['phase'],'claimed');self.assertEqual(p.posts,1)

    def test_changed_source_version_counter_clock_stops_before_any_claim(self):
        for case in ('version','counter','clock','catalog'):
            p,s,op,_clock,*_r=fixture_trial()
            if case=='version':op.responses[2]['version']+=1
            elif case=='counter':op.responses[5]=deepcopy(op.responses[5]);op.responses[5]['book']['readingTime']+=1
            elif case=='clock':op.responses[3]['timestamp']-=100
            else:s.web.request.return_value['book']['version']+=1
            with self.subTest(case=case),self.assertRaises(ValueError):p.prepare({},credentials())
            self.assertEqual(p.posts,0);self.assertEqual(p.store.read(),(None,None))

    def test_stale_plan_and_changed_payload_cannot_claim(self):
        for case in ('clock','body','grant'):
            p,_s,_op,clock,*_r=fixture_trial();p.prepare({},credentials());grant=credentials()
            if case=='clock':clock[0]+=31
            elif case=='body':p.body['books'][0]['readingTime']+=1
            else:grant['accessToken']='other-valid-token'
            with self.subTest(case=case),self.assertRaises(ValueError):p.run(grant,apply=True)
            self.assertEqual(p.store.read(),(None,None));self.assertEqual(p.posts,0)

    def test_failure_after_verified_server_state_retains_intent(self):
        p,_s,_op,_c,*_r=fixture_trial();p.prepare({},credentials())
        with self.assertRaises(OSError):self.invoke(p,apply=True,on_final=lambda:(_i for _i in ()).throw(OSError()))
        self.assertEqual(p.posts,1);self.assertEqual(p.store.read()[0]['phase'],'claimed')

    def test_whitelist_blocks_login_foreign_book_and_extra_methods(self):
        p,_s,op,_c,*_r=fixture_trial();p.prepare({},credentials());count=len(op.requests)
        for url,body in [('https://i.weread.qq.com/login',{}),('https://i.weread.qq.com/book/getProgress?bookId=42',None),('https://evil.invalid/config?token=1',None),('https://i.weread.qq.com/book/batchUploadProgress',p.body)]:
            with self.assertRaises(ValueError):p.request('outside',url,body,credentials())
        self.assertEqual(len(op.requests),count);self.assertEqual(p.posts,0)

    def test_cas_and_corruption_reject_replay_or_skip(self):
        p,_s,_op,_c,*_r=fixture_trial();p.prepare({},credentials());store=p.store;r=store.reserve(p.bound)
        with self.assertRaises(StoreError):store.advance(r,'verified')
        claimed=store.advance(r,'claimed')
        for action in (lambda:store.advance(r,'claimed'),lambda:store.finish(claimed),lambda:store.reserve(p.bound)):
            with self.assertRaises(StoreError):action()
        value=json.loads(claimed.raw);value['reserved_posts']=True;store.backend.data=json.dumps(value).encode()
        with self.assertRaises(StoreError):store.read()

    def test_pending_time_trial_blocks_all_old_scope_exclusions(self):
        factories=('AnnotationExperimentStore','FinishExperimentStore','ShelfExperimentStore','PositionExperimentStore','NativeShelfTrialStore','NativeFinishTrialStore','FlagTrialStore','NativeFlagTrialStore','TxtFullSummaryStore','TxtZeroTimeStore','NativeTxtPositionStore','MarkStyleTrialStore','HighlightTrialStore','BookmarkTrialStore','InitialMarkStyleStore','MarkColorStore','NonemptyMarksStore','ReadtimeTrialStore')
        with ExitStack() as stack:
            mocks={name:stack.enter_context(patch.object(shared,name)) for name in factories}
            for factory in mocks.values():factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
            self.assertFalse(shared.other_pending());mocks['ReadtimeTrialStore'].return_value.read.return_value=({'phase':'claimed'},None)
            self.assertTrue(shared.other_pending(exclude_native_highlight=True,exclude_bookmark=True,exclude_native_bookmark=True,exclude_native_shelf=True,exclude_native_finish=True,exclude_mark_color=True))

    def test_stats_baseline_and_zone_are_bound_before_claim(self):
        for kind in ('statistics','zone'):
            p,_s,_op,_c,*_r=fixture_trial();p.prepare({},credentials())
            if kind=='statistics':p.stats['totalReadTime']+=1
            else:p.rows[0]['time_zone']='+03:00'
            with self.assertRaises(ValueError):self.invoke(p,apply=True)
            self.assertEqual(p.store.read(),(None,None));self.assertEqual(p.posts,0)

    def test_explicit_captured_zone_attributes_previous_calendar_date(self):
        p,_s,op,clock,_before,_stats,_after,_later=fixture_trial();clock[0]=1700000000
        for raw in op.responses:
            if isinstance(raw,dict) and 'timestamp' in raw:raw['timestamp']=1700000000
        op.responses[11]=task.expected_statistics(_stats,1700000000,2,time_zone='+00:00')
        with patch.object(task,'local_zone',return_value='+00:00'):p.prepare({},credentials())
        report=self.invoke(p,apply=True)
        self.assertEqual(report['statistics_calendar_attribution'],'captured_calendar_day')
        self.assertEqual(report['monthly_total_delta'],2);self.assertEqual(p.posts,1)

    def test_returned_read_day_qualification_is_independent_of_exact_seconds(self):
        p,_s,op,_c,*_r=fixture_trial();op.responses[11]['readDays']+=1;p.prepare({},credentials())
        report=self.invoke(p,apply=True);self.assertEqual(report['read_days_delta_observed'],1)
        self.assertEqual(report['book_counter_delta'],2);self.assertEqual(report['daily_bucket_delta'],2)

    def test_other_calendar_date_is_not_accepted_as_attribution(self):
        p,_s,op,clock,_before,_stats,_after,_later=fixture_trial();clock[0]=1700000000
        for raw in op.responses:
            if isinstance(raw,dict) and 'timestamp' in raw:raw['timestamp']=1700000000
        bad=task.expected_statistics(_stats,1700000000-86400,2,time_zone='+00:00');op.responses[11]=bad
        with patch.object(task,'local_zone',return_value='+00:00'):p.prepare({},credentials())
        with self.assertRaises(ValueError):self.invoke(p,apply=True)
        self.assertEqual(p.store.read()[0]['phase'],'claimed');self.assertEqual(p.posts,1)

    def test_consumed_legacy_is_retained_and_can_never_be_rearmed(self):
        p,_s,_op,_c,*_r=fixture_trial();p.prepare({},credentials());plan=deepcopy(p.bound)
        plan.pop('statistics_sha256');plan.pop('time_zone');plan['protocol']=LEGACY_PROTOCOL
        backend=Backend();backend.data=json.dumps(dict(schema=1,scope=ACCOUNT,attempt='a'*32,phase='claimed',plan=plan,reserved_posts=1)).encode()
        store=ReadtimeTrialStore(backend,version=1);state,r=store.read();self.assertEqual(state['phase'],'claimed')
        audit=dict.fromkeys(('explicit_success_receipt','original_records_exact','web_and_native_positions_exact','independent_counters_stable',
            'book_counter_delta_verified','monthly_baseline_missing','original_trial_unverified','no_replay'),True)
        retired=store.retire_legacy(r,audit);self.assertEqual(store.read()[0]['phase'],'retired');self.assertIsNotNone(backend.data)
        empty=ReadtimeTrialStore(Backend())
        with patch.object(shared,'ReadtimeTrialStore',side_effect=lambda version:store if version==1 else empty):self.assertFalse(shared.readtime_pending())
        for action in (lambda:store.reserve(plan),lambda:store.advance(retired,'verified'),lambda:store.finish(retired),lambda:store.retire_legacy(r,audit)):
            with self.assertRaises(StoreError):action()
        with self.assertRaises(ValueError):ReadtimeTrialStore(Backend()).reserve(plan)
        value=json.loads(retired.raw);value['retirement']['original_trial_unverified']=False;backend.data=json.dumps(value).encode()
        with self.assertRaises(StoreError):store.read()

    def test_default_does_not_load_accounts_and_illegal_apply_is_offline(self):
        for argv in ([],['--apply']):
            with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:code=task.main(argv)
            store.assert_not_called();self.assertEqual(code,bool(argv));self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
