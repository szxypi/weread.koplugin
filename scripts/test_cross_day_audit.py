"""Read-only audit and honest local closure never grant a second dispatch."""
from contextlib import redirect_stdout
from copy import deepcopy
import io,json,subprocess,unittest
from unittest.mock import patch
from annotation_experiment_model import digest
from cross_day_trial import expected_months
from secure_weread_session import StoreError
from selection_trial_mock import credentials
from test_eink_login import Opener
from test_readtime_cross_day_upload import fixture as upload_fixture
import verify_cross_day_audit as audit


def fixture():
    t,source,_op,clock,progress,_stats,count,_expected=upload_fixture()
    with patch('verify_readtime_cross_day_upload.local_zone',return_value='+08:00'),patch('verify_readtime_cross_day.reading_position',return_value=source.plan.web_position):
        t.prepare({'vid':credentials()['vid']},credentials())
    before=deepcopy(t.stats);m=next(iter(before));zeros=[str(int(m)+i*86400) for i in (1,2)]
    for key in zeros:before[m]['readTimes'][key]=0
    plan=deepcopy(t.bound);plan['statistics_sha256']=digest(before)
    after=expected_months(before,plan['capture'],plan['created_at'])[0]
    for key in zeros:del after[m]['readTimes'][key]
    r=t.store.reserve(plan);r=t.store.advance(r,'prepared','claimed');t.store.advance(r,'claimed','acknowledged')
    meta=dict(bookId=t.identity,version=plan['capture']['book_version'])
    op=Opener(deepcopy([count,after[m],count,after[m],meta]));source.prepare.reset_mock();source.baseline.reset_mock()
    task=audit.Audit(source,t.store,t.capture,opener=op,clock=lambda:clock[0],sleep=lambda n:clock.__setitem__(0,clock[0]+n))
    return task,source,op,clock


class AuditTests(unittest.TestCase):
    def invoke(self,t,**kwargs):
        with patch.object(audit,'reading_position',return_value=t.source.plan.web_position):
            return t.run({'vid':credentials()['vid']},credentials(),**kwargs)

    def test_offline_and_incomplete_modes_never_open_accounts(self):
        for args in ([],['--close-unverified'],['--lua-command','command']):
            with patch.object(audit,'SessionStore') as session,patch.object(audit,'Audit') as api,redirect_stdout(io.StringIO()) as out:
                self.assertEqual(audit.main(args),bool(args))
            session.assert_not_called();api.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)

    def test_two_independent_reads_reconstruct_digest_without_changing_scope(self):
        t,s,op,_c=fixture();original=t.store.read();capture=t.capture.read();r=self.invoke(t)
        self.assertEqual(r['result'],'PASS_READONLY_ZERO_REMOVAL_AUDIT');self.assertTrue(r['historical_duration_attribution_verified'])
        self.assertFalse(r['original_trial_verified']);self.assertEqual(r['removed_zero_buckets'],2)
        self.assertEqual(t.store.read(),original);self.assertEqual(t.capture.read(),capture)
        self.assertEqual(len(op.requests),5);self.assertTrue(all(x.data is None for x in op.requests));s.writer.request.assert_not_called()

    def test_local_closure_keeps_original_ack_plan_and_count_without_reuse(self):
        t,_s,op,_c=fixture();before,r=t.store.read();result=self.invoke(t,close=True);after,final=t.store.read()
        self.assertEqual(result['result'],'UNVERIFIED_TRIAL_CLOSED');self.assertFalse(result['original_trial_verified'])
        self.assertEqual((after['phase'],after['posts']),('closed_unverified',1));self.assertEqual(after['plan'],before['plan'])
        self.assertEqual(after['closure']['prior_record_sha256'],digest(before));self.assertTrue(after['closure']['was_acknowledged'])
        self.assertTrue(after['closure']['original_trial_unverified']);self.assertNotEqual(final,r)
        for action in (lambda:t.store.reserve(after['plan']),lambda:t.store.advance(final,'closed_unverified','verified'),lambda:t.store.close_unverified(final,after['closure'])):
            with self.assertRaises(StoreError):action()
        self.assertTrue(all(x.data is None for x in op.requests))

    def test_scope_capture_owner_and_device_must_match_before_source_work(self):
        for kind in ('claimed','retired','capture','owner','device'):
            t,source,op,_c=fixture();grant=credentials();saved={'vid':grant['vid']}
            if kind in ('claimed','retired'):
                v,_r=t.store.read();v['phase']=kind;t.store.backend.data=json.dumps(v).encode()
            elif kind=='capture':t.capture.backend.data=None
            elif kind=='owner':saved['vid']='other-owner'
            else:grant['deviceId']='other-device'
            with self.subTest(kind=kind),self.assertRaises(ValueError):t.run(saved,grant,close=True)
            source.prepare.assert_not_called();self.assertEqual(len(op.requests),0)

    def test_changed_counters_statistics_clock_positions_or_versions_never_close(self):
        for kind in ('counter','ttsTime','statistics','clock','position','version'):
            t,_s,op,_c=fixture();before=t.store.read()
            if kind=='counter':op.responses[2]['book']['readingTime']+=1
            elif kind=='ttsTime':op.responses[2]['book']['ttsTime']+=1
            elif kind=='statistics':op.responses[3]['totalReadTime']+=1
            elif kind=='clock':op.responses[2]['timestamp']-=100
            elif kind=='position':op.responses[2]['book']['chapterOffset']+=1
            else:op.responses[4]['version']+=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):self.invoke(t,close=True)
            self.assertEqual(t.store.read(),before);self.assertTrue(all(x.data is None for x in op.requests))

    def test_catalog_web_source_callback_and_replacement_stop_closure(self):
        for kind in ('catalog','web','source','callback','replace'):
            t,s,_op,_c=fixture();before=t.store.read()
            if kind=='catalog':s.web.request.return_value['book']['version']+=1
            elif kind=='source':s.baseline.side_effect=ValueError('selection_trial/changed')
            def final():
                if kind=='callback':raise OSError('synthetic')
                if kind=='replace':t.store.backend.data=None
            with self.subTest(kind=kind),patch.object(audit,'reading_position',return_value={} if kind=='web' else s.plan.web_position),self.assertRaises(Exception):
                t.run({'vid':credentials()['vid']},credentials(),close=True,on_final=final)
            if kind!='replace':self.assertEqual(t.store.read(),before)

    def test_lua_agreement_is_required_for_each_private_observation(self):
        for mismatch in (False,True):
            t,_s,_op,_c=fixture();before=t.store.read()
            with patch.object(audit,'lua_compare',return_value=dict(removed_zero_buckets=1 if mismatch else 2,read_days_delta=0)) as lua:
                if mismatch:
                    with self.assertRaisesRegex(ValueError,'lua_mismatch'):self.invoke(t,close=True,lua_command=['private-command'])
                    self.assertEqual(t.store.read(),before)
                else:
                    self.assertTrue(self.invoke(t,lua_command=['private-command'])['python_lua_agree']);self.assertEqual(lua.call_count,2)

    def test_lua_frames_reject_private_fields_duplicates_and_invalid_fixed_counts(self):
        good=dict(matching_candidates=1,removed_zero_buckets=2,read_days_delta=0)
        for kind in ('ok','private','duplicate','count','boolean','exit','timeout'):
            v=deepcopy(good)
            if kind=='private':v['title']='private title'
            elif kind=='count':v['matching_candidates']=2
            elif kind=='boolean':v['read_days_delta']=False
            stdout=b'\nWEREAD_READTIME_STATISTICS='+json.dumps(v).encode()
            if kind=='duplicate':stdout+=stdout
            with self.subTest(kind=kind),patch.object(audit.subprocess,'run') as run:
                if kind=='timeout':run.side_effect=subprocess.TimeoutExpired('private-command',45)
                else:run.return_value=subprocess.CompletedProcess([],1 if kind=='exit' else 0,stdout,b'private diagnostic')
                if kind=='ok':self.assertEqual(audit.lua_compare(['private-command'],[],{}),dict(removed_zero_buckets=2,read_days_delta=0))
                else:
                    with self.assertRaises((ValueError,subprocess.TimeoutExpired)):audit.lua_compare(['private-command'],[],{})

    def test_closure_tampering_and_failed_readback_never_reopen_or_delete_record(self):
        t,_s,_op,_c=fixture();self.invoke(t,close=True);original,r=t.store.read()
        for key,value in [('posts',0),('attempt','a'*32),('plan_sha256','a'*64),('original_trial_unverified',False),('read_days_delta',True)]:
            v=deepcopy(original)
            if key in ('posts','attempt'):v[key]=value
            else:v['closure'][key]=value
            t.store.backend.data=json.dumps(v).encode()
            with self.subTest(key=key),self.assertRaises(StoreError):t.store.read()
        t.store.backend.data=r.raw
        t,_s,_op,_c=fixture();before=t.store.read();t.store.backend.save=lambda _value:None
        with self.assertRaises(StoreError):self.invoke(t,close=True)
        self.assertEqual(t.store.read(),before)

    def test_rotated_grant_same_owner_device_can_read_without_editing_original_plan(self):
        t,s,_op,_c=fixture();before=t.store.read();grant=credentials();grant['accessToken']='new-current-grant'
        with patch.object(audit,'reading_position',return_value=s.plan.web_position):
            self.assertEqual(t.run({'vid':grant['vid']},grant)['result'],'PASS_READONLY_ZERO_REMOVAL_AUDIT')
        self.assertEqual(t.store.read(),before)

    def test_transport_rejects_all_writes_and_timeout_is_not_retried(self):
        t,_s,op,_c=fixture()
        with self.assertRaises(ValueError):t.request('outside',audit.BASE+'/config?token=1',credentials=credentials())
        op.responses[1]=TimeoutError()
        with self.assertRaises(Exception):self.invoke(t,close=True)
        self.assertEqual(len(op.requests),2)
        for url,body in ((audit.BASE+'/book/batchUploadProgress',{}),(audit.BASE+'/login',{}),('https://foreign.invalid/config',None)):
            with self.assertRaises(ValueError):t.request('outside',url,body,credentials())
        self.assertEqual(len(op.requests),2)


if __name__=='__main__':unittest.main()
