"""Cross-day CB preflight refuses early or changing inputs without writes."""
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch

from secure_highlight_trial import Receipt
from test_cb_native_time_bundle_evidence import fixture
import cb_native_time_bundle_preflight as task


class ImportedPreflightTests(unittest.TestCase):
    def setup_case(self,mode='success'):
        bundle,grant,_report,snapshot,months,pairs=fixture();plan=bundle['plan'];now=plan['not_before']+20
        saved=dict(vid=plan['owner'],cookies={'wr_vid':plan['owner'],'wr_skey':'synthetic-private-cookie'})
        class Store:
            backend=None
            def read(self):return deepcopy(bundle),Receipt(b'synthetic-capture')
        class Session:
            def load(self):return deepcopy(saved)
        class NativeStore:
            def load(self,_owner):return deepcopy(grant)
        class Gate:
            backend=None
            def read(self):return (None,None) if mode!='pending' else ({'phase':'claimed'},Receipt(b'claimed'))
        class FakeWeb:
            index=0
            def __init__(self,current):
                self.current=current;self.index=FakeWeb.index;FakeWeb.index+=1
                self.samples=[];self.progress={};self.catalogs=deepcopy(pairs[self.index]);self.authenticated=False
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def request(self,*_args):return {}
            def inspect(self,_book):return dict(chapter_uid=plan['chapter_uid'])
            def close(self):pass
        class FakeNative:
            def __init__(self,provided,book,which_months,not_before,current,clock):
                assert provided==grant and book==plan['book_id'] and not_before==plan['not_before'];self.server_times=[];self.current=current;self.count=0
            def request(self,stage,url,credentials=None):
                assert stage=='cb_preflight_stats' and credentials==grant and self.current()
                key=url.rsplit('=',1)[-1];value=deepcopy(months[key]);self.count+=1
                if mode=='statistics_changed' and self.count>len(months):value['totalReadTime']+=1
                return value
            def close(self):pass
        snapshots=[]
        def observed(_web,_sample,native,_grant):
            value=deepcopy(snapshot);native.server_times.append(now);snapshots.append(value)
            if mode=='position_changed' and len(snapshots)>1:value['native']['chapter_offset']+=1
            if mode=='chapter_changed':value['native']['chapter_idx']+=1
            return value
        gate,audit=Gate(),Gate()
        return bundle,grant,snapshot,months,plan,now,Store(),Session(),NativeStore(),gate,audit,FakeWeb,FakeNative,observed
    def test_before_midnight_does_not_open_account_or_gate(self):
        _b,_g,_s,_m,plan,now,store,session,native,gate,audit,web,api,_obs=self.setup_case()
        session.load=Mock(side_effect=AssertionError('must not open session'));native.load=Mock()
        gate.read=Mock();audit.read=Mock();web=Mock();api=Mock()
        report,packet=task.run(store,session,native,gate,audit,clock=lambda:plan['not_before']-1,sleep=lambda _s:None,
                               web_factory=web,native_factory=api)
        self.assertEqual(report['result'],'NOT_YET_HISTORICAL');self.assertIsNone(packet)
        session.load.assert_not_called();native.load.assert_not_called();gate.read.assert_not_called();audit.read.assert_not_called()
        web.assert_not_called();api.assert_not_called()
    def test_success_and_mutation_fail_closed(self):
        for mode in ('success','pending','statistics_changed','position_changed','chapter_changed'):
            with self.subTest(mode=mode):
                bundle,grant,snapshot,months,plan,now,store,session,native,gate,audit,web,api,observed=self.setup_case(mode)
                with patch.object(task,'snapshot',side_effect=observed),patch.object(task,'save_refreshed_web_session',return_value=False):
                    report,packet=task.run(store,session,native,gate,audit,clock=lambda:now,sleep=lambda _s:None,web_factory=web,native_factory=api)
                self.assertEqual(report['result'],'CB_CROSS_DAY_READONLY_VERIFIED' if mode=='success' else 'UNVERIFIED')
                self.assertEqual(report['account_data_posts'],0);self.assertEqual(report['authentication_posts'],0)
                if mode=='success':
                    self.assertEqual(repr(packet),'<CBPreparedPreflight private>')
                    self.assertEqual(packet.evidence.for_bundle(packet.bundle,packet.grant)[1],snapshot)
                    self.assertNotIn(plan['book_id'],repr(packet));packet.close();self.assertEqual(packet.grant,{})
                else:self.assertIsNone(packet)
    def test_real_keychain_disallows_injected_test_dependencies(self):
        class FakeMac:pass
        store=Mock();store.backend=FakeMac();gate=Mock();gate.backend=None;audit=Mock();audit.backend=None
        with patch.object(task,'MacKeychain',FakeMac):
            report,packet=task.run(store,Mock(),Mock(),gate,audit,clock=lambda:1)
        self.assertEqual(report['result'],'UNVERIFIED');self.assertIsNone(packet);store.read.assert_not_called()
    def test_native_transport_scope_server_clock_and_read_limit(self):
        bundle,grant,_snapshot,months,plan,now,_store,_session,_native,_gate,_audit,_web,_api,_obs=self.setup_case()
        month=next(iter(months));calls=[]
        def fake(_self,stage,_url,body=None,credentials=None,timeout=15):
            calls.append(stage);return {'timestamp':now} if stage=='cb_capture_progress' else {}
        with patch.object(task.NativeProbe,'request',new=fake):
            current={'value':True};reader=task.ReadOnlyNative(grant,plan['book_id'],{int(month)},plan['not_before'],lambda:current['value'],lambda:now)
            progress=task.BASE+'/book/getProgress?bookId='+plan['book_id']
            for _i in range(2):reader.request('cb_capture_progress',progress,credentials=grant)
            self.assertEqual(reader.server_times,[now,now])
            for args in (('cb_capture_progress',progress),('cb_capture_progress',progress+'x'),
                         ('write',task.BASE+'/book/batchUploadProgress'),('cb_preflight_stats',task.BASE+'/readdata/detail?mode=monthly&baseTime=1')):
                with self.subTest(args=args),self.assertRaises(ValueError):reader.request(*args,credentials=grant)
            self.assertEqual(len(calls),2);current['value']=False
            with self.assertRaises(ValueError):reader.request('cb_capture_shelf',task.BASE+'/shelf/sync',credentials=grant)
            reader.close();self.assertEqual(reader.grant,{})
        for stamp in (plan['not_before']-1,now+61,True):
            with self.subTest(stamp=stamp),patch.object(task.NativeProbe,'request',return_value={'timestamp':stamp}):
                reader=task.ReadOnlyNative(grant,plan['book_id'],{int(month)},plan['not_before'],lambda:True,lambda:now)
                with self.assertRaises(ValueError):reader.request('cb_capture_progress',progress,credentials=grant)


if __name__=='__main__':unittest.main()
