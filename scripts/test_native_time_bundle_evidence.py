"""Bind private preflight evidence to the same bundle, grant and supervisor."""
from contextlib import ExitStack
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_audit_store import AuditStore
from native_time_bundle_evidence import FreshShelfEvidence,PreflightEvidence
from native_time_bundle_preparation import SigningInputs,read_evidenced_signing_inputs
from native_time_bundle_selection import expected
from native_time_bundle_supervisor import EvidenceSupervisor
from native_time_bundle_trial_scope import from_journals
from annotation_experiment_model import canonical
from personal_upload_trial import Receipt as UploadReceipt,hash_value
from secure_highlight_trial import Receipt
from test_cloud_group_nonempty_contract import TARGET,source
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


def synthetic_trial(bundle):
    owner=bundle['plan']['owner'];upload=dict(phase='imported',target=TARGET,plan={'owner':owner},attempt='a'*32)
    group=dict(owner=owner,target=TARGET,upload_attempt=upload['attempt'],upload_plan_hash=hash_value(upload['plan']),
               phase='create_claimed',dispatched=True)
    old=dict(owner=owner,phase='closed_unverified')
    return upload,UploadReceipt(canonical(upload)),group,canonical(group),old,canonical(old)


def synthetic_scope(bundle):return from_journals(bundle,*synthetic_trial(bundle))


def evidence_fixture():
    bundle,grant,before,_samples,now=example()
    report=observed(completed_at=now);report['observed_months']=len(before['months'])
    record=synthetic_catalog(bundle['plan'])
    evidence=PreflightEvidence(bundle,grant,report,before['snapshot'],before['months'],synthetic_pairs(record))
    return bundle,grant,before,report,now,evidence


def fresh_fixture():
    bundle,grant,before,report,now,_evidence=evidence_fixture()
    del report['both_positions_source_counts_and_original_shelf_exact']
    report.update(result='CAPTURE_FRESH_SHELF_READONLY_VERIFIED',
                  captured_native_shelf_positions_source_counts_exact=True,
                  fresh_native_and_web_shelf_stable=True,
                  previous_native_group_baseline_matches=False,
                  previous_web_group_baseline_matches=False)
    pairs=synthetic_pairs(synthetic_catalog(bundle['plan']))
    shelves=('a'*64,'b'*64)
    evidence=FreshShelfEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,shelves,synthetic_scope(bundle))
    return bundle,grant,before,report,now,pairs,shelves,evidence


class EvidenceTests(unittest.TestCase):
    def test_fresh_scoped_preflight_binds_the_actual_journal_receipts(self):
        bundle,grant,before,_report,now,_evidence=evidence_fixture();plan=bundle['plan']
        upload,upload_token,group,group_token,old,old_token=synthetic_trial(bundle)
        saved={'vid':plan['owner']};store=Mock();store.read.return_value=(bundle,Receipt(b'synthetic-capture'))
        groups,olds=Mock(),Mock();groups.read.return_value=(group,group_token);olds.read.return_value=(old,old_token)
        result=dict(phase='create_claimed',dispatched=True,native_fixture_present=True,web_fixture_present=True,
                    native_group_present=False,web_group_present=False)
        original=dict(native_original_state_unchanged=False,web_original_state_unchanged=False,old_group_absent=True)
        shelf=source();shelf['archive'][0]['bookIds'].remove(TARGET)
        web=Mock();web.book_id=plan['book_id'];web.chapter=plan['chapter_uid'];web.request.return_value=shelf
        web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True}
        web._time_catalog_pair=synthetic_pairs(synthetic_catalog(plan))[0]
        native=Mock();native.shelf.return_value=shelf
        stats=[before['months'][key] for key in sorted(before['months'],key=int)]*2
        with ExitStack() as stack:
            for name,value in [('UploadJournal',Mock()),('GroupJournal',groups),('OldJournal',olds),('TargetReceipt',Mock()),
                               ('ScopedNative',native),('Guard',Mock()),('Binding',Mock()),('NonemptyBinding',Mock())]:
                stack.enter_context(patch.object(preflight,name,return_value=value))
            stack.enter_context(patch.object(preflight,'binding',return_value=(upload,upload_token)))
            stack.enter_context(patch.object(preflight,'inspect',return_value=result))
            stack.enter_context(patch.object(preflight,'inspect_original',return_value=original))
            stack.enter_context(patch.object(preflight,'xhtml_snapshot',return_value=deepcopy(before['snapshot'])))
            stack.enter_context(patch.object(preflight,'project_statistics',side_effect=stats))
            evidence=preflight.run(saved,grant,store,lambda:True,web,api_factory=Mock,statistics_factory=Mock,
                clock=lambda:now,sleep=lambda _:None,baseline_includes_fixture=True,fresh_shelf=True,private_evidence=True)
        report,_snapshot,_months,_stamp,_shelves,scope=evidence.for_bundle(bundle,grant)
        self.assertEqual(scope,synthetic_scope(bundle))
        self.assertFalse(report['previous_native_group_baseline_matches'])
        self.assertFalse(report['previous_web_group_baseline_matches'])
        components=evidence.components_for_bundle(bundle,grant)
        self.assertEqual(len(components),2);self.assertNotIn('Synthetic',repr(components))
        components[0]['members']='a'*64
        self.assertNotEqual(components,evidence.components_for_bundle(bundle,grant))

    def test_fresh_evidence_is_private_copied_and_cannot_authorize_dispatch(self):
        bundle,grant,before,report,now,_pairs,shelves,evidence=fresh_fixture()
        self.assertEqual(repr(evidence),'<FreshShelfEvidence private>')
        public,snapshot,months,stamp,actual,scope=evidence.for_bundle(bundle,grant)
        self.assertEqual((public,snapshot,months,actual),(report,before['snapshot'],before['months'],shelves))
        public.clear();snapshot['counts']['readingTime']+=1;months.clear()
        self.assertEqual(evidence.for_bundle(bundle,grant),(report,before['snapshot'],before['months'],stamp,shelves,scope))
        keeper=gate(now);store=Mock();audit=AuditStore(Backend(),clock=lambda:now)
        with self.assertRaisesRegex(ValueError,'bundle_supervisor/evidence'):
            EvidenceSupervisor(keeper,store,bundle,grant,'synthetic-guest','synthetic-config',
                               lambda:True,audit_store=audit,evidence=evidence)
        self.assertEqual(keeper.read(),(None,None));store.assert_not_called()

    def test_fresh_evidence_rejects_changes_and_incomplete_observations(self):
        for mode in ('bundle','grant','report','previous','snapshot','months','catalog','shelves','internal'):
            bundle,grant,before,report,_now,pairs,shelves,evidence=fresh_fixture()
            if mode=='bundle':bundle['plan']['seconds']+=1
            elif mode=='grant':grant['accessToken']='other-synthetic-token'
            elif mode=='report':report['fresh_native_and_web_shelf_stable']=False
            elif mode=='previous':report['previous_native_group_baseline_matches']=None
            elif mode=='snapshot':before['snapshot']['counts']['ttsTime']+=1
            elif mode=='months':before['months']={}
            elif mode=='catalog':pairs[1][1][0]['updated'][0]['chapterIdx']+=1
            elif mode=='shelves':shelves=('a'*64,'invalid')
            else:evidence._value[1]['snapshot']['counts']['ttsTime']+=1
            with self.subTest(mode=mode),self.assertRaises(ValueError):
                if mode in ('bundle','grant','internal'):evidence.for_bundle(bundle,grant)
                else:FreshShelfEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,shelves,synthetic_scope(bundle))

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
