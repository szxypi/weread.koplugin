"""Bounded readback compares the sealed fresh baseline and old trial identity."""
from contextlib import ExitStack,redirect_stderr
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch
from contextlib import redirect_stdout
import io
import json

from native_time_bundle_fresh_audit import FreshAuditStore
from native_time_bundle_readback import NativeReads,StatisticsReads,ShelfRead,run
from secure_highlight_trial import Receipt
from test_eink_login import Opener
from test_native_time_bundle_accounting import example as accounting_example
from test_native_time_bundle_evidence import synthetic_catalog,synthetic_pairs,synthetic_scope,synthetic_trial
from test_native_time_bundle_fresh_shelf import example as shelf_example
from test_native_time_bundle_gate import fixture,gate
from test_secure_native_session import Backend


class FreshReadbackTests(unittest.TestCase):
    def test_fresh_command_requires_saved_session_and_acknowledged_gate(self):
        import verify_native_time_bundle_readback as command
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):command.main(['--fresh-shelf'])
        keeper=Mock();keeper.read.return_value=({'phase':'prepared'},None)
        with patch.object(command,'DispatchGate',return_value=keeper),patch.object(command,'FreshAuditStore') as stores,\
                patch.object(command,'SessionStore') as sessions,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(command.main(['--saved-session','--fresh-shelf']),0)
        stores.assert_not_called();sessions.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'NOT_READY')

    def test_fresh_readback_requires_exact_shelves_trial_catalog_and_accounting(self):
        for mode in ('match','shelf_changed','trial_changed','catalog_changed','accounting_changed'):
            bundle,grant,evidence,observations=shelf_example();_b,_g,before,samples,now=accounting_example()
            _b,_g,body,_n=fixture();keeper=gate(now);reservation=keeper.reserve(bundle,grant)
            audit=FreshAuditStore(Backend(),clock=lambda:now);audit.seal(bundle,grant,keeper,evidence,synthetic_scope(bundle))
            claimed=keeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
            keeper.acknowledge(claimed,{'succ':1});audit_before=audit.read();gate_before=keeper.read()
            capture=Mock();capture.backend=object();capture.read.return_value=(bundle,Receipt(b'synthetic-capture'))
            p=bundle['plan'];native_shelf=observations[0]['native'];web_shelf=observations[0]['web']
            web=Mock();web.book_id=p['book_id'];web.chapter=p['chapter_uid'];web.request.return_value=web_shelf
            web._time_catalog_pair=synthetic_pairs(synthetic_catalog(p))[0]
            web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True}
            upload,upload_token,group,group_token,old,old_token=synthetic_trial(bundle)
            if mode=='trial_changed':
                old['extra']='changed'
                from annotation_experiment_model import canonical
                old_token=canonical(old)
            uploads,groups,olds=Mock(),Mock(),Mock();groups.read.return_value=(group,group_token);olds.read.return_value=(old,old_token)
            native_open=Opener(sum(([{'timestamp':now},{},native_shelf] for _ in range(3)),[]))
            months=sorted(before['months'],key=int)
            stats_open=Opener([deepcopy(sample['months'][key]) for sample in samples for key in months])
            shelf_open=Opener([native_shelf]*10)
            snapshot_values=[deepcopy(item['snapshot']) for item in samples]
            if mode=='accounting_changed':snapshot_values[-1]['counts']['ttsTime']+=1
            snapshots=iter(snapshot_values)
            def snapshot(_web,native,credentials):
                for stage,url in native.allowed:native.request(stage,url,credentials=credentials)
                return next(snapshots)
            def check_groups(*args):
                args[4]();args[4]()
                return deepcopy(observations[0]['group'])
            def check_original(*args):
                args[5]();args[5]()
                return deepcopy(observations[0]['original'])
            if mode=='shelf_changed':
                changed=deepcopy(web_shelf);changed['books'][0]['bookId']='900009'
                web.request.side_effect=[web_shelf]*5+[changed]*5
            if mode=='catalog_changed':web._time_catalog_pair[1][0]['updated'][0]['version']=1
            import native_time_bundle_readback as module
            with ExitStack() as stack:
                for name,value in [('UploadJournal',uploads),('GroupJournal',groups),('OldJournal',olds),
                                   ('TargetReceipt',Mock()),('Guard',Mock()),('Binding',Mock()),('NonemptyBinding',Mock())]:
                    stack.enter_context(patch.object(module,name,return_value=value))
                stack.enter_context(patch.object(module,'binding',return_value=(upload,upload_token)))
                stack.enter_context(patch.object(module,'inspect',side_effect=check_groups))
                stack.enter_context(patch.object(module,'inspect_original',side_effect=check_original))
                stack.enter_context(patch.object(module,'xhtml_snapshot',side_effect=snapshot))
                args=dict(saved={'vid':grant['vid']},grant=grant,store=capture,gate=keeper,audit=audit,current=lambda:True,web=web,
                          clock=lambda:now,sleep=lambda _:None,
                          native_factory=lambda grant,plan,fixture,current,clock:NativeReads(grant,plan,fixture,current,clock,opener=native_open),
                          statistics_factory=lambda grant,months,current:StatisticsReads(grant,months,current,stats_open),
                          shelf_factory=lambda grant,current:ShelfRead(grant,current,shelf_open))
                with self.subTest(mode=mode):
                    if mode=='match':
                        result=run(**args);self.assertEqual(result['result'],'READBACK_MATCH')
                        self.assertFalse(result['real_accounting_verified']);self.assertEqual(len(shelf_open.requests),10)
                    else:
                        with self.assertRaises(ValueError):run(**args)
            self.assertEqual(keeper.read(),gate_before);self.assertEqual(audit.read(),audit_before)
            self.assertTrue(all(req.data is None for req in native_open.requests+stats_open.requests+shelf_open.requests))


if __name__=='__main__':unittest.main()
