"""Bind private preflight evidence to the same bundle, grant and supervisor."""
from contextlib import ExitStack
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_audit_store import AuditStore
from native_time_bundle_evidence import PreflightEvidence
from native_time_bundle_preparation import SigningInputs,read_evidenced_signing_inputs
from native_time_bundle_selection import expected
from native_time_bundle_supervisor import EvidenceSupervisor
from secure_highlight_trial import Receipt
from test_cloud_group_nonempty_contract import TARGET
from test_native_time_bundle_accounting import example
from test_native_time_bundle_gate import fixture,gate
from test_native_time_bundle_supervisor import observed
from test_secure_native_session import Backend
from verify_native_time_capture import XhtmlSource
from verify_owner_reading import ReadingPreflight
import verify_native_time_cross_day as preflight


def synthetic_catalog(plan):
    return {'bookId':plan['book_id'],'book':{'bookVersion':plan['book_version']},
            'updated':[{'chapterUid':plan['chapter_uid'],'chapterIdx':plan['chapter_idx']}]}


def synthetic_pairs(record):
    return [[[deepcopy(record)],[deepcopy(record)]],[[deepcopy(record)],[deepcopy(record)]]]


def evidence_fixture():
    bundle,grant,before,_samples,now=example()
    report=observed(completed_at=now);report['observed_months']=len(before['months'])
    record=synthetic_catalog(bundle['plan'])
    evidence=PreflightEvidence(bundle,grant,report,before['snapshot'],before['months'],synthetic_pairs(record))
    return bundle,grant,before,report,now,evidence


class EvidenceTests(unittest.TestCase):
    def test_reader_keeps_full_before_and_after_catalog_responses_in_memory(self):
        bundle,_grant,_before,_report,_now,_evidence=evidence_fixture();record=synthetic_catalog(bundle['plan'])
        before={'data':[deepcopy(record),deepcopy(record)]};after={'data':[deepcopy(record)]}
        web=XhtmlSource.__new__(XhtmlSource);web.book_id=bundle['plan']['book_id']
        with patch.object(ReadingPreflight,'request',side_effect=[before,after]):
            web.request('catalog_before','synthetic');web.request('catalog_after','synthetic')
        before['data'].pop();after['data'].clear()
        self.assertEqual(len(web._time_catalog_pair[0]['data']),2)
        self.assertEqual(len(web._time_catalog_pair[1]['data']),1)
        fresh=XhtmlSource.__new__(XhtmlSource);fresh.book_id=bundle['plan']['book_id']
        with patch.object(ReadingPreflight,'request',return_value={'data':[record]}),self.assertRaisesRegex(ValueError,'catalog_order'):
            fresh.request('catalog_after','synthetic')

    def test_copy_and_representation_do_not_expose_private_observations(self):
        bundle,grant,before,report,_now,evidence=evidence_fixture()
        self.assertEqual(repr(evidence),'<PreflightEvidence private>')
        public,snapshot,months=evidence.for_bundle(bundle,grant)
        self.assertEqual((public,snapshot,months),(report,before['snapshot'],before['months']))
        snapshot['counts']['readingTime']+=1;months.clear();public.clear()
        self.assertEqual(evidence.for_bundle(bundle,grant),(report,before['snapshot'],before['months']))

    def test_foreign_bundle_grant_bad_report_or_mutation_is_rejected(self):
        for mode in ('bundle','grant','report','snapshot','months','internal'):
            bundle,grant,before,report,_now,evidence=evidence_fixture()
            if mode=='bundle':bundle['plan']['seconds']+=1
            elif mode=='grant':grant['accessToken']='other-synthetic-token'
            elif mode=='report':report['two_statistics_reads_stable']=False
            elif mode=='snapshot':before['snapshot']['counts']['ttsTime']+=1
            elif mode=='months':before['months']={}
            else:evidence._value[1]['snapshot']['counts']['ttsTime']+=1
            with self.subTest(mode=mode),self.assertRaises(ValueError):
                if mode in ('report','snapshot','months'):
                    record=synthetic_catalog(bundle['plan'])
                    PreflightEvidence(bundle,grant,report,before['snapshot'],before['months'],synthetic_pairs(record))
                else:evidence.for_bundle(bundle,grant)

    def test_catalog_requires_two_matching_records_and_original_chapter_index(self):
        for mode in ('missing','missing_inner','changed_version','changed_index','wrong_book','duplicate_chapter','duplicate_book','error_response','changed_stamp'):
            bundle,grant,before,report,_now,_evidence=evidence_fixture();record=synthetic_catalog(bundle['plan'])
            records=synthetic_pairs(record)
            if mode=='missing':records=records[:1]
            elif mode=='missing_inner':records[0]=records[0][:1]
            elif mode=='changed_version':records[1][1][0]['book']['bookVersion']+=1
            elif mode=='changed_index':records[1][1][0]['updated'][0]['chapterIdx']+=1
            elif mode=='wrong_book':records[0][0][0]['bookId']='900002'
            elif mode=='duplicate_chapter':records[1][1][0]['updated']*=2
            elif mode=='duplicate_book':records[0][0].append(deepcopy(record))
            elif mode=='error_response':records[0][0]={'errcode':1,'data':[record]}
            else:records[1][1][0]['updated'][0]['version']=1
            with self.subTest(mode=mode),self.assertRaisesRegex(ValueError,'bundle_evidence/catalog'):
                PreflightEvidence(bundle,grant,report,before['snapshot'],before['months'],records)

    def test_supervisor_preserves_evidence_through_claim(self):
        bundle,grant,before,_report,now,evidence=evidence_fixture();_b,_g,body,_n=fixture()
        keeper=gate(now);store=Mock();store.read.return_value=(bundle,Receipt(b'synthetic-capture'))
        audit=AuditStore(Backend(),clock=lambda:now)
        supervisor=EvidenceSupervisor(keeper,store,bundle,grant,'synthetic-guest','synthetic-config',
                                      lambda:True,audit_store=audit,evidence=evidence)
        supervisor.prepare();supervisor.select(expected(bundle));supervisor.claim(body,expected(bundle))
        self.assertEqual(keeper.read()[0]['phase'],'claimed')
        saved,_,_,_=audit.inspect(bundle,grant,keeper)
        self.assertEqual((saved['snapshot'],saved['months']),(before['snapshot'],before['months']))

    def test_signing_inputs_require_unchanged_evidence_and_do_not_claim(self):
        for changed in (False,True):
            bundle,grant,_before,_report,now,evidence=evidence_fixture()
            receipt=Receipt(b'synthetic-capture');store=Mock();store.backend=object();store.read.return_value=(bundle,receipt)
            keeper=gate(now);probe=Mock()
            def read():
                if changed:evidence._value[1]['snapshot']['counts']['ttsTime']+=1
                return SigningInputs('synthetic-guest','synthetic-config')
            probe.read.side_effect=read
            args=dict(bundle=bundle,receipt=receipt,grant=grant,store=store,gate=keeper,current=lambda:True,
                      evidence=evidence,probe=probe,clock=lambda:now)
            with self.subTest(changed=changed):
                if changed:
                    with self.assertRaises(ValueError):read_evidenced_signing_inputs(**args)
                else:self.assertEqual(read_evidenced_signing_inputs(**args),SigningInputs('synthetic-guest','synthetic-config'))
            self.assertEqual(keeper.read(),(None,None))

    def test_evidence_changes_before_and_after_claim_never_release_permission(self):
        for stage in ('before','after'):
            bundle,grant,_before,_report,now,evidence=evidence_fixture();_b,_g,body,_n=fixture()
            keeper=gate(now);store=Mock();store.read.return_value=(bundle,Receipt(b'synthetic-capture'))
            audit=AuditStore(Backend(),clock=lambda:now)
            supervisor=EvidenceSupervisor(keeper,store,bundle,grant,'synthetic-guest','synthetic-config',
                                          lambda:True,audit_store=audit,evidence=evidence)
            supervisor.prepare();supervisor.select(expected(bundle));claim=keeper.claim
            if stage=='before':evidence._value[1]['snapshot']['counts']['ttsTime']+=1
            def change(*args,**kwargs):
                result=claim(*args,**kwargs)
                evidence._value[1]['snapshot']['counts']['ttsTime']+=1
                return result
            with self.subTest(stage=stage),patch.object(keeper,'claim',side_effect=change if stage=='after' else claim):
                with self.assertRaises(ValueError):supervisor.claim(body,expected(bundle))
            self.assertEqual(keeper.read()[0]['phase'],'prepared' if stage=='before' else 'claimed')

    def test_scoped_preflight_returns_the_observations_it_actually_read(self):
        bundle,grant,before,_report,now,_evidence=evidence_fixture();plan=bundle['plan']
        saved={'vid':plan['owner']};store=Mock();store.read.return_value=(bundle,Receipt(b'synthetic-capture'))
        upload={'target':TARGET,'plan':{'owner':plan['owner']}};group={'target':TARGET};old={'phase':'closed_unverified'}
        group_result=dict(phase='create_claimed',dispatched=True,native_fixture_present=True,web_fixture_present=True,
                          native_group_present=False,web_group_present=False)
        original=dict(native_original_state_unchanged=True,web_original_state_unchanged=True,old_group_absent=True)
        web=Mock();web.book_id=plan['book_id'];web.chapter=plan['chapter_uid'];web.record=synthetic_catalog(plan)
        web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True}
        web._time_catalog_pair=synthetic_pairs(web.record)[0]
        uploads,groups,olds,receipt=Mock(),Mock(),Mock(),Mock()
        groups.read.return_value=(group,'g');olds.read.return_value=(old,'o')
        observations=[before['months'][key] for key in sorted(before['months'],key=int)]*2
        with ExitStack() as stack:
            for name,value in [('UploadJournal',uploads),('GroupJournal',groups),('OldJournal',olds),
                               ('TargetReceipt',receipt),('ScopedNative',Mock()),('Guard',Mock()),('Binding',Mock()),('NonemptyBinding',Mock())]:
                stack.enter_context(patch.object(preflight,name,return_value=value))
            stack.enter_context(patch.object(preflight,'binding',return_value=(upload,'u')))
            stack.enter_context(patch.object(preflight,'inspect',return_value=group_result))
            stack.enter_context(patch.object(preflight,'inspect_original',return_value=original))
            snapshots=stack.enter_context(patch.object(preflight,'xhtml_snapshot',return_value=deepcopy(before['snapshot'])))
            projection=stack.enter_context(patch.object(preflight,'project_statistics',side_effect=observations))
            result=preflight.run(saved,grant,store,lambda:True,web,api_factory=lambda *args:Mock(),
                                 statistics_factory=Mock,clock=lambda:now,sleep=lambda _:None,
                                 baseline_includes_fixture=True,private_evidence=True)
            self.assertEqual(snapshots.call_count,2)
            projection.side_effect=observations
            def change_catalog(_book):
                web.record=synthetic_catalog(plan);web.record['updated'][0]['version']=1
                web._time_catalog_pair=synthetic_pairs(web.record)[0]
                return {'cloud_position_stable':True,'catalog_stable':True}
            web.inspect.side_effect=change_catalog
            with self.assertRaisesRegex(ValueError,'bundle_evidence/catalog'):
                preflight.run(saved,grant,store,lambda:True,web,api_factory=lambda *args:Mock(),
                              statistics_factory=Mock,clock=lambda:now,sleep=lambda _:None,
                              baseline_includes_fixture=True,private_evidence=True)
        report,snapshot,months=result.for_bundle(bundle,grant)
        self.assertEqual((snapshot,months),(before['snapshot'],before['months']))
        self.assertEqual(report['completed_at'],now)
        self.assertFalse(report['dispatch_capability']);self.assertFalse(report['historical_accounting_verified'])
        keeper=gate(now);probe=Mock();probe.read.return_value=SigningInputs('synthetic-guest','synthetic-config')
        inputs=read_evidenced_signing_inputs(bundle=bundle,receipt=store.read()[1],grant=grant,store=store,
                    gate=keeper,current=lambda:True,evidence=result,probe=probe,clock=lambda:now)
        audit=AuditStore(Backend(),clock=lambda:now)
        supervisor=EvidenceSupervisor(keeper,store,bundle,grant,inputs.guest,inputs.config_token,
                                      lambda:True,audit_store=audit,evidence=result)
        _b,_g,body,_n=fixture();supervisor.prepare();supervisor.select(expected(bundle));supervisor.claim(body,expected(bundle))
        self.assertEqual(keeper.read()[0]['phase'],'claimed')
        self.assertEqual(audit.inspect(bundle,grant,keeper)[0]['months'],months)


if __name__=='__main__':unittest.main()
