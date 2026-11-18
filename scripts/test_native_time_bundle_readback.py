"""Only bounded authenticated reads can reach the independent time audit."""
from contextlib import ExitStack,redirect_stdout
import base64
from copy import deepcopy
import io
import json
import time
import unittest
from unittest.mock import Mock,patch
import zipfile

from native_time_bundle_audit_store import AuditStore
from native_time_bundle_readback import NativeReads,StatisticsReads,ShelfRead,run
from secure_highlight_trial import Receipt
from test_cloud_group_nonempty_contract import TARGET,source
from test_eink_login import Opener,Response
from test_native_time_bundle_accounting import example
from test_native_time_bundle_evidence import synthetic_catalog,synthetic_pairs
from test_native_time_bundle_gate import fixture,gate
from test_secure_native_session import Backend
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest as captured_digest
from verify_eink_login import BASE
import verify_native_time_bundle_readback as command


def shelf_fixture():
    value=source();value['archive'][0]['bookIds'].remove(TARGET);return value


def sealed():
    bundle,grant,before,samples,now=example();_b,_g,body,_n=fixture()
    keeper=gate(now);reservation=keeper.reserve(bundle,grant);audit=AuditStore(Backend(),clock=lambda:now)
    audit.seal(bundle,grant,keeper,before['snapshot'],before['months'],now)
    claim=keeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
    keeper.acknowledge(claim,{'succ':1})
    capture=Mock();capture.backend=object();capture.read.return_value=(bundle,Receipt(b'synthetic-capture'))
    return bundle,grant,before,samples,now,keeper,audit,capture


class ReadbackTests(unittest.TestCase):
    def test_partial_readback_has_nonzero_exit_and_keeps_accounting_unverified(self):
        keeper=Mock();keeper.read.return_value=({'phase':'acknowledged'},Receipt(b'synthetic'))
        saved={'vid':'900000','cookies':{'wr_vid':'900000','wr_skey':'synthetic'}};grant={'vid':'900000'}
        session=Mock();session.load.return_value=saved;native=Mock();native.load.return_value=grant
        web=Mock();web.shards={};web._time_catalog_pair=[]
        partial=dict(result='READBACK_PARTIAL',independent_samples=3,accounting_and_core_state_exact=True,
                     full_shelf_exact=False,real_accounting_verified=False,account_data_posts=0,authentication_posts=0)
        with ExitStack() as stack:
            for name,value in [('DispatchGate',keeper),('SessionStore',session),('NativeSessionStore',native),('XhtmlSource',web),
                               ('CaptureBundleStore',Mock()),('FreshAuditStore',Mock())]:
                stack.enter_context(patch.object(command,name,return_value=value))
            stack.enter_context(patch.object(command.resource,'setrlimit'))
            stack.enter_context(patch.object(command,'run',return_value=partial))
            output=stack.enter_context(redirect_stdout(io.StringIO()))
            self.assertEqual(command.main(['--saved-session','--fresh-shelf']),1)
        self.assertEqual(json.loads(output.getvalue()),partial)

    def test_command_is_offline_by_default_and_unacknowledged_scope_stays_offline(self):
        with patch.object(command,'DispatchGate') as gates,patch.object(command,'SessionStore') as sessions,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(command.main([]),0)
        gates.assert_not_called();sessions.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for state in (None,{'phase':'prepared'},{'phase':'claimed'}):
            gate=Mock();gate.read.return_value=(state,None)
            with self.subTest(state=state),patch.object(command,'DispatchGate',return_value=gate),patch.object(command,'SessionStore') as sessions,patch.object(command.resource,'setrlimit'),redirect_stdout(io.StringIO()) as out:
                self.assertEqual(command.main(['--saved-session']),0)
            sessions.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'NOT_READY')

    def test_command_hides_errors_and_clears_temporary_session_copies(self):
        gate=Mock();gate.read.return_value=({'phase':'acknowledged'},Receipt(b'synthetic'))
        saved={'vid':'900000','cookies':{'wr_vid':'synthetic'}};grant={'vid':'900000','accessToken':'synthetic-secret'}
        session=Mock();session.load.return_value=saved;native=Mock();native.load.return_value=grant
        web=Mock();web.shards={'synthetic':'synthetic'};web._time_catalog_pair=[{},{}]
        with ExitStack() as stack:
            for name,value in [('DispatchGate',gate),('SessionStore',session),('NativeSessionStore',native),('XhtmlSource',web),
                               ('CaptureBundleStore',Mock()),('AuditStore',Mock())]:
                stack.enter_context(patch.object(command,name,return_value=value))
            stack.enter_context(patch.object(command.resource,'setrlimit'))
            stack.enter_context(patch.object(command,'run',side_effect=ValueError('synthetic-secret')))
            output=stack.enter_context(redirect_stdout(io.StringIO()))
            self.assertEqual(command.main(['--saved-session']),1)
        self.assertEqual(json.loads(output.getvalue())['result'],'UNVERIFIED')
        self.assertNotIn('synthetic-secret',output.getvalue());self.assertEqual(saved,{})
        self.assertEqual(grant,{});self.assertEqual(web.shards,{})
        self.assertEqual(web._time_catalog_pair,[]);web.close.assert_called_once()

    def test_real_scope_refuses_clock_or_transport_overrides_before_reading(self):
        import native_time_bundle_readback as module
        class FakeMac:pass
        capture=Mock();capture.backend=FakeMac();keeper=Mock();audit=Mock();web=Mock()
        args=dict(saved={},grant={},store=capture,gate=keeper,audit=audit,current=lambda:True,web=web)
        with patch.object(module,'MacKeychain',FakeMac):
            with self.assertRaisesRegex(ValueError,'clock_override'):
                run(**args,clock=lambda:0,sleep=time.sleep)
            with self.assertRaisesRegex(ValueError,'transport_override'):
                run(**args,clock=time.time,sleep=time.sleep,native_factory=Mock())
        capture.read.assert_not_called();web.prepare.assert_not_called()

    def test_non_200_and_ambiguous_api_receipts_are_rejected(self):
        bundle,grant,_before,_samples,now,_gate,_audit,_capture=sealed();p=bundle['plan']
        for mode in ('http','false_error','false_success'):
            response={'timestamp':now}
            if mode=='false_error':response['errcode']=False
            if mode=='false_success':response['succ']=False
            opener=Opener([response])
            if mode=='http':
                def open_with_wrong_status(request,timeout):
                    opener.requests.append(request);value=Response(response);value.status=201;return value
                opener.open=open_with_wrong_status
            task=NativeReads(grant,p,TARGET,lambda:True,clock=lambda:now,opener=opener)
            with self.subTest(mode=mode),self.assertRaises(Exception):
                task.request('native_capture_progress',BASE+'/book/getProgress?bookId='+p['book_id'],credentials=grant)
            self.assertEqual(len(opener.requests),1)
        opener=Opener([{'timestamp':now,'succ':'1'}])
        task=NativeReads(grant,p,TARGET,lambda:True,clock=lambda:now,opener=opener)
        self.assertEqual(task.request('native_capture_progress',BASE+'/book/getProgress?bookId='+p['book_id'],credentials=grant)['succ'],'1')

    def test_native_reads_are_ordered_fixed_gets_without_cookies_or_retries(self):
        bundle,grant,_before,_samples,now,_gate,_audit,_capture=sealed();p=bundle['plan']
        responses=[{'timestamp':now},{},shelf_fixture()]*3;opener=Opener(responses)
        task=NativeReads(grant,p,TARGET,lambda:True,clock=lambda:now,opener=opener)
        routes=(('native_capture_progress',BASE+'/book/getProgress?bookId='+p['book_id']),
                ('native_capture_metadata',BASE+'/book/info?bookId='+p['book_id']),('native_capture_shelf',BASE+'/shelf/sync'))
        for _ in range(3):
            for stage,url in routes:task.request(stage,url,credentials=grant)
        self.assertEqual(task.steps,9);self.assertEqual(len(opener.requests),9)
        self.assertTrue(all(req.data is None and req.get_header('Cookie') is None for req in opener.requests))
        with self.assertRaises(ValueError):task.request(*routes[0],credentials=grant)
        self.assertEqual(len(opener.requests),9)
        for mode in ('wrong_stage','wrong_url','post','foreign_grant','session','timeout'):
            opener=Opener([TimeoutError()] if mode=='timeout' else [{}]);current=Mock(return_value=mode!='session')
            task=NativeReads(grant,p,TARGET,current,clock=lambda:now,opener=opener);stage,url=routes[0];body=None;credential=grant
            if mode=='wrong_stage':stage='other'
            elif mode=='wrong_url':url=BASE+'/book/batchUploadProgress'
            elif mode=='post':body={}
            elif mode=='foreign_grant':credential=dict(grant,vid='900001')
            with self.subTest(mode=mode),self.assertRaises(Exception):task.request(stage,url,body=body,credentials=credential)
            self.assertEqual(len(opener.requests),1 if mode=='timeout' else 0)
            if mode=='timeout':
                with self.assertRaises(ValueError):task.request(stage,url,credentials=credential)
                self.assertEqual(len(opener.requests),1)

    def test_statistics_and_fixture_shelf_are_bounded_and_read_only(self):
        bundle,grant,before,_samples,_now,_gate,_audit,_capture=sealed();month=next(iter(before['months']))
        opener=Opener([before['months'][month]]*3);task=StatisticsReads(grant,before['months'],lambda:True,opener)
        url=BASE+'/readdata/detail?mode=monthly&baseTime='+month
        for _ in range(3):task.request('statistics_monthly',url,credentials=grant)
        with self.assertRaises(ValueError):task.request('statistics_monthly',url,credentials=grant)
        self.assertTrue(all(req.data is None for req in opener.requests));self.assertEqual(len(opener.requests),3)
        other=Opener([{}]);task=StatisticsReads(grant,before['months'],lambda:True,other)
        with self.assertRaises(ValueError):task.request('statistics_monthly',url+'&extra=1',credentials=grant)
        self.assertEqual(len(other.requests),0)
        other=Opener([shelf_fixture()]);shelf=ShelfRead(grant,lambda:True,other);shelf.shelf()
        with self.assertRaises(ValueError):shelf.request('group_shelf',BASE+'/shelf/archive',body={},credentials=grant)
        self.assertEqual(len(other.requests),1);self.assertIsNone(other.requests[0].data)

    def test_receipt_is_required_before_any_network_or_web_read(self):
        bundle,grant,before,_samples,now,_keeper,_audit,capture=sealed();keeper=gate(now)
        reservation=keeper.reserve(bundle,grant);audit=AuditStore(Backend(),clock=lambda:now)
        audit.seal(bundle,grant,keeper,before['snapshot'],before['months'],now)
        web=Mock()
        with self.assertRaisesRegex(ValueError,'bundle_readback/no_ack'):
            run(saved={'vid':grant['vid']},grant=grant,store=capture,gate=keeper,audit=audit,current=lambda:True,
                web=web,clock=lambda:now,sleep=lambda _:None)
        web.prepare.assert_not_called();self.assertEqual(keeper.read()[0]['phase'],'prepared')

    def test_three_readbacks_compare_real_adapters_and_never_modify_journals(self):
        for mode in ('match','changed_final','catalog_changed','stale_session','expired','cross_day'):
            bundle,grant,before,samples,now,keeper,audit,capture=sealed();p=bundle['plan']
            receipt_before=keeper.read();audit_before=audit.read();current=Mock(return_value=True)
            web=Mock();web.book_id=p['book_id'];web.chapter=p['chapter_uid'];web._time_catalog_pair=synthetic_pairs(synthetic_catalog(p))[0]
            web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True}
            web.request.return_value=shelf_fixture()
            upload={'target':TARGET,'plan':{'owner':p['owner']}};group={'target':TARGET};old={'phase':'closed_unverified'}
            uploads,groups,olds,target=Mock(),Mock(),Mock(),Mock()
            groups.read.return_value=(group,'g');olds.read.return_value=(old,'o')
            native_open=Opener(sum(([{'timestamp':now},{},shelf_fixture()] for _ in range(3)),[]))
            months=sorted(before['months'],key=int);stats_values=[]
            for sample in samples:
                stats_values.extend(deepcopy(sample['months'][key]) for key in months)
            stats_open=Opener(stats_values);shelf_open=Opener([shelf_fixture()]*8)
            native_factory=lambda grant,plan,fixture,current,clock:NativeReads(grant,plan,fixture,current,clock,opener=native_open)
            stat_factory=lambda grant,months,current:StatisticsReads(grant,months,current,stats_open)
            shelf_factory=lambda grant,current:ShelfRead(grant,current,shelf_open)
            snapshot_values=[deepcopy(item['snapshot']) for item in samples]
            if mode=='changed_final':snapshot_values[-1]['counts']['ttsTime']+=1
            counter=[0]
            def snapshot(_web,native,credentials):
                for stage,url in native.allowed:native.request(stage,url,credentials=credentials)
                index=counter[0];counter[0]+=1
                if mode=='catalog_changed' and index==1:
                    web._time_catalog_pair=synthetic_pairs(synthetic_catalog(p))[0]
                    web._time_catalog_pair[1][0]['updated'][0]['version']=1
                if mode=='stale_session' and index==1:current.return_value=False
                return snapshot_values[index]
            def check_groups(*args):
                pair=args[4];pair();pair()
                return {'phase':'create_claimed','dispatched':True,'native_fixture_present':True,'web_fixture_present':True,
                        'native_group_present':False,'web_group_present':False}
            def check_original(*args):
                pair=args[5];pair();pair()
                return {'native_original_state_unchanged':True,'web_original_state_unchanged':True,'old_group_absent':True}
            with ExitStack() as stack:
                import native_time_bundle_readback as module
                for name,value in [('UploadJournal',uploads),('GroupJournal',groups),('OldJournal',olds),('TargetReceipt',target),
                                   ('Guard',Mock()),('Binding',Mock()),('NonemptyBinding',Mock())]:
                    stack.enter_context(patch.object(module,name,return_value=value))
                stack.enter_context(patch.object(module,'binding',return_value=(upload,'u')))
                stack.enter_context(patch.object(module,'inspect',side_effect=check_groups))
                stack.enter_context(patch.object(module,'inspect_original',side_effect=check_original))
                stack.enter_context(patch.object(module,'xhtml_snapshot',side_effect=snapshot))
                observed_now=now+181 if mode=='expired' else now+86400 if mode=='cross_day' else now
                args=dict(saved={'vid':grant['vid']},grant=grant,store=capture,gate=keeper,audit=audit,current=current,web=web,
                          clock=lambda:observed_now,sleep=lambda _:None,native_factory=native_factory,statistics_factory=stat_factory,shelf_factory=shelf_factory)
                with self.subTest(mode=mode):
                    if mode=='match':
                        result=run(**args);self.assertEqual(result['result'],'READBACK_MATCH');self.assertFalse(result['real_accounting_verified'])
                        self.assertEqual(result['independent_samples'],3);self.assertEqual(len(native_open.requests),9)
                        self.assertEqual(len(stats_open.requests),3*len(months));self.assertEqual(len(shelf_open.requests),8)
                    else:
                        with self.assertRaises(ValueError):run(**args)
                        if mode in ('expired','cross_day'):
                            self.assertEqual(len(native_open.requests)+len(stats_open.requests)+len(shelf_open.requests),0)
            self.assertEqual(keeper.read(),receipt_before);self.assertEqual(audit.read(),audit_before)
            self.assertTrue(all(req.data is None for req in native_open.requests+stats_open.requests+shelf_open.requests))

    def test_full_snapshot_projection_flows_through_three_guarded_reads(self):
        bundle,grant,before,samples,now=example();p=bundle['plan'];record=synthetic_catalog(p)
        shelf=shelf_fixture();shelf['books'][0]['bookId']=p['book_id'];shelf['archive'][0]['bookIds']=[p['book_id']]
        before['snapshot']['shelf']=state_hash(shelf)
        before['snapshot']['catalog']=captured_digest({'book_id':p['book_id'],
            'versions':[p['book_version'],p['book_version']],'chapters':record['updated']})
        p['baseline_sha256']=captured_digest(before['snapshot'])
        for sample in samples:
            sample['snapshot']['shelf']=before['snapshot']['shelf'];sample['snapshot']['catalog']=before['snapshot']['catalog']
        _b,_g,body,_n=fixture();keeper=gate(now);reservation=keeper.reserve(bundle,grant)
        audit=AuditStore(Backend(),clock=lambda:now);audit.seal(bundle,grant,keeper,before['snapshot'],before['months'],now)
        claim=keeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config');keeper.acknowledge(claim,{'succ':1})
        capture=Mock();capture.backend=object();capture.read.return_value=(bundle,Receipt(b'synthetic-capture'))
        progress={'timestamp':now,'book':{'bookId':p['book_id'],'chapterUid':int(p['chapter_uid']),
            'chapterIdx':p['chapter_idx'],'chapterOffset':12,'progress':3,'readingTime':20+p['seconds'],
            'recordReadingTime':0,'ttsTime':0}}
        native_open=Opener(sum(([deepcopy(progress),{'bookId':p['book_id'],'bookVersion':p['book_version']},deepcopy(shelf)] for _ in range(3)),[]))
        months=sorted(before['months'],key=int);stats_open=Opener([deepcopy(sample['months'][key]) for sample in samples for key in months])
        shelf_open=Opener([deepcopy(shelf)]*8)
        web=Mock();web.book_id=p['book_id'];web.chapter=p['chapter_uid'];web.record=record;web.chapters=record['updated']
        web.shards={'e_0':'synthetic','e_1':'synthetic','e_3':'synthetic'};web._time_catalog_pair=synthetic_pairs(record)[0]
        web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True}
        web.request.side_effect=lambda stage,*args,**kwargs:deepcopy(progress if stage=='progress_after' else shelf)
        upload={'target':TARGET,'plan':{'owner':p['owner']}};group={'target':TARGET};old={'phase':'closed_unverified'}
        uploads,groups,olds,target=Mock(),Mock(),Mock(),Mock();groups.read.return_value=(group,'g');olds.read.return_value=(old,'o')
        with zipfile.ZipFile(io.BytesIO(base64.b64decode(p['archive_base64']))) as archive:
            raw=archive.read('OEBPS/weread-position/raw-'+p['raw_sha256']+'.txt').decode()
        def check_groups(*args):
            args[4]();args[4]()
            return {'phase':'create_claimed','dispatched':True,'native_fixture_present':True,'web_fixture_present':True,
                    'native_group_present':False,'web_group_present':False}
        def check_original(*args):
            args[5]();args[5]()
            return {'native_original_state_unchanged':True,'web_original_state_unchanged':True,'old_group_absent':True}
        import native_time_bundle_readback as module
        import verify_native_time_capture as capture_module
        with ExitStack() as stack:
            for name,value in [('UploadJournal',uploads),('GroupJournal',groups),('OldJournal',olds),('TargetReceipt',target),
                               ('Guard',Mock()),('Binding',Mock()),('NonemptyBinding',Mock())]:
                stack.enter_context(patch.object(module,name,return_value=value))
            stack.enter_context(patch.object(module,'binding',return_value=(upload,'u')))
            stack.enter_context(patch.object(module,'inspect',side_effect=check_groups))
            stack.enter_context(patch.object(module,'inspect_original',side_effect=check_original))
            stack.enter_context(patch.object(capture_module,'decode_content_shards',return_value=raw))
            result=run(saved={'vid':grant['vid']},grant=grant,store=capture,gate=keeper,audit=audit,current=lambda:True,web=web,
                       clock=lambda:now,sleep=lambda _:None,
                       native_factory=lambda grant,plan,fixture,current,clock:NativeReads(grant,plan,fixture,current,clock,opener=native_open),
                       statistics_factory=lambda grant,months,current:StatisticsReads(grant,months,current,stats_open),
                       shelf_factory=lambda grant,current:ShelfRead(grant,current,shelf_open))
        self.assertEqual(result['result'],'READBACK_MATCH');self.assertFalse(result['real_accounting_verified'])
        self.assertEqual(len(native_open.requests),9);self.assertEqual(len(stats_open.requests),3*len(months))
        self.assertEqual(keeper.read()[0]['phase'],'acknowledged')


if __name__=='__main__':unittest.main()
