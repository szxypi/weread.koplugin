"""CB readback requires an acknowledged claim and three stable observations."""
from copy import deepcopy
import tempfile,unittest
from unittest.mock import Mock,patch

import cb_native_time_bundle_readback as task
from secure_weread_session import StoreError
from test_cb_native_time_bundle_accounting import example as accounting_example
from test_cb_native_time_bundle_evidence import fixture as evidence_fixture
from test_cb_native_time_bundle_supervisor import fixture


class ImportedReadbackTests(unittest.TestCase):
    def run_case(self,directory,mode='success'):
        bundle,grant,_evidence,selection,body,record,_path,now,gate,audit,store,state,_supervisor,bridge=fixture(directory,True)
        bridge.handle(dict(kind='selection',selection=selection));bridge.handle(dict(kind='claim',body=body,selection=selection,record=record))
        if mode!='no_ack':bridge.handle(dict(kind='ack',status=200,response={'succ':1}))
        gate_before=gate.read();audit_before=audit.read();capture_before=store.read()
        _bundle,_grant,_baseline,samples,_now=accounting_example()
        _bundle,_grant,_report,_snapshot,_months,pairs=evidence_fixture()
        saved=dict(vid=bundle['plan']['owner'],cookies={'wr_vid':bundle['plan']['owner'],'wr_skey':'mock-cookie'})
        class Session:
            def load(self):return deepcopy(saved)
        class NativeStore:
            def load(self,owner):
                assert owner==saved['vid'];return deepcopy(grant)
        class Web:
            count=0
            def __init__(self,current):
                self.index=Web.count;Web.count+=1;self.current=current
                self.samples=[];self.progress={};self.catalogs=deepcopy(pairs[0]);self.authenticated=False
                if mode=='catalog' and self.index==2:self.catalogs[1][0]['book']['bookVersion']+=1
            def set_cookie(self,*_args):pass
            def verify_account(self):assert self.current()
            def request(self,*_args):assert self.current();return {}
            def inspect(self,_book):return dict(chapter_uid=bundle['plan']['chapter_uid'])
            def close(self):pass
        class Native:
            def __init__(self,provided,book,months,dispatched,current,clock):
                assert provided==grant and book==bundle['plan']['book_id'] and dispatched==now
                self.allowed=[None]*(3+len(months));self.steps=0;self.server_at=None;self.current=current
            def request(self,stage,url,credentials=None):
                assert stage=='cb_readback_stats' and credentials==grant and self.current()
                index=self.steps//len(self.allowed);self.steps+=1
                value=deepcopy(samples[index]['months'][url.rsplit('=',1)[-1]])
                if mode=='statistics' and index==2:value['totalReadTime']+=1
                return value
            def close(self):pass
        observed_count=[]
        def observed(_web,_sample,native,_grant):
            index=len(observed_count);observed_count.append(index);native.steps+=3;native.server_at=now+index
            value=deepcopy(samples[index]['snapshot'])
            if mode=='position' and index==2:value['native']['chapter_offset']+=1
            if mode=='source' and index==1:value['source']='f'*64
            if mode=='state_change' and index==1:state['current']=False;gate.backend.save(b'changed')
            return value
        with patch.object(task,'snapshot',side_effect=observed),patch.object(task,'save_refreshed_web_session',return_value=False):
            if mode=='no_ack':
                with self.assertRaisesRegex(ValueError,'no_ack'):
                    task.run(Session(),NativeStore(),store,gate,audit,clock=lambda:now,sleep=lambda _s:None,web_factory=Web,native_factory=Native)
                self.assertEqual(Web.count,0)
            elif mode=='success':
                result=task.run(Session(),NativeStore(),store,gate,audit,clock=lambda:now,sleep=lambda _s:None,web_factory=Web,native_factory=Native)
                self.assertEqual(result['result'],'CB_READBACK_MATCH');self.assertEqual(result['independent_samples'],3)
                self.assertFalse(result['real_accounting_verified']);self.assertEqual(result['account_data_posts'],0)
                self.assertEqual(observed_count,[0,1,2])
            else:
                with self.assertRaises((ValueError,StoreError)):
                    task.run(Session(),NativeStore(),store,gate,audit,clock=lambda:now,sleep=lambda _s:None,web_factory=Web,native_factory=Native)
        if mode!='state_change':self.assertEqual(gate.read(),gate_before)
        self.assertEqual(audit.read(),audit_before);self.assertEqual(store.read(),capture_before)

    def test_acknowledged_readback_and_changed_results(self):
        for mode in ('success','no_ack','position','source','statistics','catalog','state_change'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:self.run_case(directory,mode)

    def test_real_scopes_reject_injected_transports_and_clock(self):
        class FakeMac:pass
        store=Mock();store.backend=FakeMac();gate=Mock();gate.backend=None;audit=Mock();audit.backend=None
        with patch.object(task,'MacKeychain',FakeMac),self.assertRaisesRegex(ValueError,'override'):
            task.run(Mock(),Mock(),store,gate,audit,clock=lambda:1)
        gate.read.assert_not_called();store.read.assert_not_called()

    def test_native_transport_is_read_only_ordered_bounded_and_clock_checked(self):
        bundle,grant,_before,_samples,now=accounting_example();plan=bundle['plan']
        month=next(iter(_before['months']));seen=[]
        def fake(probe,stage,url,body=None,credentials=None,timeout=15):
            seen.append((stage,url));probe.report['stages'].append({'status':200})
            return {'timestamp':now} if stage=='cb_capture_progress' else {}
        with patch.object(task.NativeProbe,'request',new=fake):
            api=task.NativeReads(grant,plan['book_id'],{month},now,lambda:True,lambda:now)
            progress=api.allowed[0][1]
            with self.assertRaises(ValueError):api.request('write',task.BASE+'/book/batchUploadProgress',credentials=grant)
            for _ in range(3):
                for stage,url in api.allowed:api.request(stage,url,credentials=grant)
            self.assertEqual(len(seen),12);self.assertEqual(api.server_at,now)
            with self.assertRaises(ValueError):api.request('cb_capture_progress',progress,credentials=grant)
            api.close();self.assertEqual(api.grant,{})
        for stamp in (True,now-61,now+61):
            def bad(probe,*_args,**_kwargs):probe.report['stages'].append({'status':200});return {'timestamp':stamp}
            with self.subTest(stamp=stamp),patch.object(task.NativeProbe,'request',new=bad):
                api=task.NativeReads(grant,plan['book_id'],{month},now,lambda:True,lambda:now)
                with self.assertRaises(ValueError):api.request(*api.allowed[0],credentials=grant)


if __name__=='__main__':unittest.main()
