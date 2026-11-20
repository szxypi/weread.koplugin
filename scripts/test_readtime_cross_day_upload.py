"""Exact historical accounting, ACK durability and permanently consumed scope."""
from contextlib import redirect_stdout
from copy import deepcopy
import io,json,unittest
from unittest.mock import patch
from cross_day_trial import TrialStore,day,expected_months,validate
from secure_weread_session import StoreError
from selection_trial_mock import credentials
from test_eink_login import Opener
from test_readtime_cross_day import fixture as preflight_fixture
from test_readtime_trial import fixture_trial
from test_secure_native_session import Backend
import verify_readtime_cross_day_upload as upload


def fixture():
    with patch('verify_readtime_history_capture.local_zone',return_value='+08:00'):
        preflight,source,_reader,clock=preflight_fixture()
    p=preflight.store.read()[0]['plan'];_t,_s,_o,_c,progress,stats,*_rest=fixture_trial()
    progress['timestamp']=int(clock[0]);metadata=dict(bookId=p['source']['book_id'],version=p['book_version'])
    count=deepcopy(progress);count['book']['readingTime']+=2
    expected=expected_months({str(stats['baseTime']):stats},p,int(clock[0]))[0][str(stats['baseTime'])]
    responses=[dict(token='fixture-config'),dict(feature={}),metadata,progress,stats,
        metadata,progress,stats,dict(succ=1),count,expected,count,expected,metadata]
    opener=Opener(deepcopy(responses));task=upload.Trial(preflight=preflight,capture=preflight.store,store=TrialStore(Backend()),opener=opener,
        clock=lambda:clock[0],sleep=lambda n:clock.__setitem__(0,clock[0]+n))
    return task,source,opener,clock,progress,stats,count,expected


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.zone=patch.object(upload,'local_zone',return_value='+08:00');self.zone.start();self.addCleanup(self.zone.stop)

    def prepare(self,t):
        with patch('verify_readtime_cross_day.reading_position',return_value=t.source.plan.web_position):
            t.prepare({'vid':credentials()['vid']},credentials())

    def run_trial(self,t,**kwargs):
        with patch.object(upload,'reading_position',return_value=t.source.plan.web_position):return t.run(credentials(),**kwargs)

    def test_default_and_apply_without_saved_session_never_touch_accounts(self):
        for args in ([],['--apply'],['--status']):
            with patch.object(upload,'SessionStore') as session,patch.object(upload,'TrialStore') as store,redirect_stdout(io.StringIO()) as out:
                self.assertEqual(upload.main(args),bool(args))
            session.assert_not_called();store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)

    def test_exact_original_window_one_post_two_target_reads_and_retired_receipt(self):
        t,source,op,_clock,*_rest=fixture();capture=t.capture.read();self.prepare(t);result=self.run_trial(t,apply=True)
        self.assertEqual(result['result'],'PASS_HISTORICAL_ACCOUNTING');self.assertEqual(result['independent_target_reads'],2)
        state,r=t.store.read();self.assertEqual((state['phase'],state['posts']),('retired',1));self.assertEqual(t.capture.read(),capture)
        posts=[x for x in op.requests if x.data is not None];self.assertEqual(len(posts),1);self.assertIsNone(posts[0].get_header('Cookie'))
        body=json.loads(posts[0].data);p=capture[0]['plan'];hour=body['books'][0]['hours'][0]
        self.assertEqual(hour['startOfHour'],p['start_time']//3600*3600);self.assertEqual(hour['readingTime'],2)
        self.assertEqual(hour['timeZone'],p['time_zone']);self.assertNotEqual(day(body['books'][0]['timestamp']),day(p['start_time']))
        self.assertFalse(hasattr(t.store,'finish'));self.assertFalse(hasattr(t.store,'delete'));source.writer.request.assert_not_called()
        for action in (lambda:t.store.reserve(t.bound),lambda:t.store.advance(r,'retired','prepared'),lambda:self.run_trial(t,apply=True)):
            with self.assertRaises((ValueError,StoreError)):action()
        self.assertEqual(len([x for x in op.requests if x.data is not None]),1)

    def test_readonly_has_no_claim_and_can_precede_same_plan_apply(self):
        t,_s,op,_clock,progress,stats,*_rest=fixture();self.prepare(t);before=deepcopy(t.bound)
        # Read-only final checks precede the already queued apply preflight.
        meta=dict(bookId=t.identity,version=t.original[0]['plan']['book_version'])
        op.responses[:0]=deepcopy([meta,progress,stats,meta])
        dry=self.run_trial(t);self.assertEqual(dry['account_data_posts'],0);self.assertEqual(t.store.read(),(None,None));self.assertFalse(dry['scope_retained'])
        self.assertEqual(t.bound,before);self.assertEqual(self.run_trial(t,apply=True)['result'],'PASS_HISTORICAL_ACCOUNTING')

    def test_ack_saved_before_first_independent_read_and_claim_saved_before_transport(self):
        t,_s,op,_clock,*_rest=fixture();self.prepare(t);original=op.open;phases=[]
        def observe(req,timeout):
            state,_r=t.store.read();phases.append((req.data is not None,state['phase'] if state else 'absent'))
            return original(req,timeout)
        op.open=observe;self.run_trial(t,apply=True)
        at=next(i for i,row in enumerate(phases) if row[0]);self.assertEqual(phases[at],(True,'claimed'))
        self.assertTrue(all(phase=='acknowledged' for _post,phase in phases[at+1:]))

    def test_missing_rejected_and_timeout_receipts_never_become_success_or_retry(self):
        for ack in ({},dict(succ='1'),dict(succ=0),TimeoutError()):
            t,_s,op,_clock,*_rest=fixture();op.responses[8]=ack;self.prepare(t)
            with self.subTest(ack=type(ack).__name__),self.assertRaises(ValueError):self.run_trial(t,apply=True)
            self.assertEqual(t.store.read()[0]['phase'],'claimed');self.assertEqual(t.posts,1)
            self.assertEqual(t.target_reads,1);self.assertFalse(t.ack)
            n=len(op.requests)
            with self.assertRaises(ValueError):self.run_trial(t,apply=True)
            self.assertEqual(len(op.requests),n)

    def test_current_day_or_unrelated_bucket_cannot_count_as_historical_success(self):
        for kind in ('current_day','other_bucket','total','recordReadingTime','ttsTime','position','readDays'):
            t,_s,op,clock,_progress,stats,_count,_expected=fixture();self.prepare(t)
            if kind=='current_day':
                wrong=deepcopy(stats);wrong['readTimes'][str(day(int(clock[0])))]=2;wrong['totalReadTime']+=2;op.responses[5]=wrong
            elif kind=='other_bucket':op.responses[5]['readTimes'][str(day(int(clock[0]))-10*86400)]=1
            elif kind=='total':op.responses[5]['totalReadTime']+=1
            elif kind=='readDays':op.responses[5]['readDays']+=2
            elif kind=='position':op.responses[4]['book']['chapterOffset']+=1
            else:op.responses[4]['book'][kind]+=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):self.run_trial(t,apply=True)
            self.assertEqual((t.store.read()[0]['phase'],t.posts),('acknowledged',1))

    def test_delayed_accounting_retries_only_reads_then_requires_two_targets(self):
        t,_s,op,_clock,progress,stats,*_rest=fixture();self.prepare(t)
        op.responses[4:4]=deepcopy([progress,stats])
        result=self.run_trial(t,apply=True);self.assertEqual(result['independent_target_reads'],2);self.assertEqual(t.posts,1)

    def test_one_target_only_regression_or_no_delta_stays_acknowledged(self):
        for kind in ('regression','none','one'):
            t,_s,op,_clock,progress,stats,*_rest=fixture();self.prepare(t)
            if kind=='regression':op.responses[6:8]=deepcopy([progress,stats])
            elif kind=='none':op.responses[4:]=deepcopy([v for _i in range(4) for v in (progress,stats)])
            else:op.responses[6]=TimeoutError()
            with self.subTest(kind=kind),self.assertRaises(Exception):self.run_trial(t,apply=True)
            self.assertEqual((t.posts,t.store.read()[0]['phase']),(1,'acknowledged'))

    def test_preflight_changes_or_expired_envelope_never_claim(self):
        for kind in ('counter','statistics','version','clock','grant','capture','body','source','zone'):
            t,source,op,clock,*_rest=fixture();self.prepare(t)
            grant=credentials()
            if kind=='counter':op.responses[1]['book']['readingTime']+=1
            elif kind=='statistics':op.responses[2]['totalReadTime']+=1
            elif kind=='version':op.responses[0]['version']+=1
            elif kind=='clock':clock[0]+=30
            elif kind=='grant':grant['accessToken']='different-grant'
            elif kind=='capture':t.capture.backend.data=None
            elif kind=='body':t.body['books'][0]['hours'][0]['readingTime']=3
            elif kind=='source':source.current.side_effect=ValueError('selection_trial/changed')
            else:upload.local_zone.return_value='+00:00'
            with self.subTest(kind=kind),self.assertRaises(Exception):t.run(grant,apply=True)
            self.assertEqual(t.store.read(),(None,None));self.assertEqual(t.posts,0);upload.local_zone.return_value='+08:00'

    def test_persistence_failure_before_transport_after_transport_and_after_readback_keeps_consumed_state(self):
        for phase in ('prepared','claimed','acknowledged','verified','retired'):
            t,_s,op,_clock,*_rest=fixture();self.prepare(t);original=t.store.backend.save
            def fail(data):
                if json.loads(data)['phase']==phase:raise OSError('synthetic persistence failure')
                original(data)
            t.store.backend.save=fail
            with self.subTest(phase=phase),self.assertRaises(OSError):self.run_trial(t,apply=True)
            self.assertEqual(t.posts,int(phase in ('acknowledged','verified','retired')))
            state,_r=t.store.read()
            self.assertEqual(state['phase'] if state else None,{'prepared':None,'claimed':'prepared','acknowledged':'claimed','verified':'acknowledged','retired':'verified'}[phase])
            self.assertLessEqual(len([x for x in op.requests if x.data is not None]),1)

    def test_model_rejects_timestamp_duration_source_and_digest_edits(self):
        t,_s,_op,_clock,*_rest=fixture();self.prepare(t)
        for kind in ('duration','time_zone','created_at','protocol','request_sha256','extra'):
            p=deepcopy(t.bound)
            if kind=='duration':p['capture']['duration']=3
            elif kind=='time_zone':p['capture']['time_zone']='+00:00'
            elif kind=='created_at':p[kind]=p['capture']['not_before']-1
            elif kind=='protocol':p[kind]='old-trial'
            elif kind=='request_sha256':p[kind]=False
            else:p[kind]=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):validate(p)

    def test_store_tampering_cas_skips_and_terminal_reuse_are_rejected(self):
        t,_s,_op,_clock,*_rest=fixture();self.prepare(t);r=t.store.reserve(t.bound)
        with self.assertRaises(StoreError):t.store.advance(r,'prepared','verified')
        claimed=t.store.advance(r,'prepared','claimed')
        with self.assertRaises(StoreError):t.store.advance(r,'claimed','acknowledged')
        value=t.store.read()[0]
        for k,v in [('schema',True),('posts',True),('scope','other'),('phase','absent'),('attempt','wrong')]:
            bad=deepcopy(value);bad[k]=v;t.store.backend.data=json.dumps(bad).encode()
            with self.subTest(k=k),self.assertRaises(StoreError):t.store.read()
        t.store.backend.data=claimed.raw
        with self.assertRaises(StoreError):t.store.reserve(t.bound)

    def test_request_guard_rejects_all_unprepared_foreign_and_unclaimed_posts(self):
        t,_s,op,_clock,*_rest=fixture()
        with self.assertRaises(ValueError):t.request('outside',upload.BASE+'/config?token=1',credentials=credentials())
        self.prepare(t);n=len(op.requests)
        for url,body in ((upload.BASE+'/login',{}),(upload.BASE+'/book/batchUploadProgress',t.body),('https://foreign.invalid/config?token=1',None)):
            with self.assertRaises(ValueError):t.request('outside',url,body,credentials())
        self.assertEqual(len(op.requests),n)

    def test_capture_and_source_must_still_match_after_final_callback(self):
        for kind in ('callback','capture','web','catalog'):
            t,source,op,_clock,*_rest=fixture();self.prepare(t)
            if kind=='catalog':source.web.request.return_value['book']['version']+=1
            def final():
                if kind=='callback':raise OSError('synthetic')
                if kind=='capture':t.capture.backend.data=None
            with self.subTest(kind=kind),patch.object(upload,'reading_position',return_value={} if kind=='web' else source.plan.web_position),self.assertRaises(Exception):
                t.run(credentials(),apply=True,on_final=final)
            self.assertEqual((t.posts,t.store.read()[0]['phase']),(1,'acknowledged'))

    def test_previous_month_changes_only_captured_month_and_current_month_is_fixed(self):
        for changed in (False,True):
            t,_source,op,clock,progress,stats,count,expected=fixture();clock[0]+=40*86400
            progress['timestamp']=count['timestamp']=int(clock[0])
            for i in (1,4):t.preflight.opener.responses[i]['timestamp']=int(clock[0])
            current=dict(baseTime=upload.period('monthly',clock[0])[0],readTimes={str(day(int(clock[0]))):19},totalReadTime=19,readDays=1)
            meta=dict(bookId=t.capture.read()[0]['plan']['source']['book_id'],version=t.capture.read()[0]['plan']['book_version'])
            op.responses=deepcopy([dict(token='fixture-config'),dict(feature={}),meta,progress,stats,current,meta,progress,stats,current,
                dict(succ=1),count,expected,current,count,expected,current,meta])
            self.prepare(t)
            if changed:
                op.responses[7]=deepcopy(op.responses[7]);op.responses[7]['totalReadTime']+=2
            with self.subTest(changed=changed):
                if changed:
                    with self.assertRaises(ValueError):self.run_trial(t,apply=True)
                    self.assertEqual(t.store.read()[0]['phase'],'acknowledged')
                else:self.assertTrue(self.run_trial(t,apply=True)['historical_accounting_verified'])
            self.assertEqual(t.posts,1)

    def test_midnight_during_readback_stops_without_another_request(self):
        t,_source,op,clock,*_rest=fixture();self.prepare(t)
        t.sleep=lambda _n:clock.__setitem__(0,day(int(clock[0]))+86400)
        with self.assertRaisesRegex(ValueError,'cross_upload/day_changed'):self.run_trial(t,apply=True)
        self.assertEqual(t.target_reads,1);self.assertEqual(t.store.read()[0]['phase'],'acknowledged');self.assertEqual(t.posts,1)

    def test_main_adopts_each_verified_rotated_web_session_before_next_handoff(self):
        from unittest.mock import Mock
        p=Mock();p.posts=0;p.ack=False;p.target_reads=0;p.store.read.return_value=(None,None)
        for api in (p,p.preflight,p.source.notes,p.source.web):api.report={'stages':[]}
        p.prepare.side_effect=lambda _saved,_grant,on_final:on_final()
        def run(_grant,apply,on_final):
            self.assertFalse(apply);on_final();return dict(result='PASS_READONLY',account_data_posts=0)
        p.run.side_effect=run;versions=[]
        def handoff(_store,saved,_source):
            versions.append(saved['version']);return dict(vid='fixture-owner',version=saved['version']+1)
        with patch.object(upload,'SessionStore') as session,patch.object(upload,'NativeSessionStore') as native,patch.object(upload,'Trial',return_value=p),patch.object(upload,'TrialStore'),patch.object(upload,'prepare_web_handoff',side_effect=handoff),patch('verify_native_thought_trial.other_pending',return_value=False),patch('secure_native_thought_trial.NativeThoughtTrialStore') as thoughts,patch('secure_selection_trial.SelectionTrialStore') as selection,redirect_stdout(io.StringIO()):
            session.return_value.load.return_value=dict(vid='fixture-owner',version=0);native.return_value.load.return_value=credentials()
            thoughts.return_value.pending.return_value=selection.return_value.pending.return_value=False
            self.assertEqual(upload.main(['--saved-session']),0)
        self.assertEqual(versions,[0,1])


if __name__=='__main__':unittest.main()
