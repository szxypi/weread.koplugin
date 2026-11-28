"""Strict isolated CB preflight evidence and Lua-compatible catalog proof."""
from copy import deepcopy
import unittest

from cb_native_time_bundle_evidence import PreflightEvidence,catalog_check
from test_cb_native_time_bundle_accounting import example


def fixture():
    bundle,grant,before,_samples,now=example();plan=bundle['plan']
    cat=[dict(bookId=plan['book_id'],book=dict(bookId=plan['book_id'],bookVersion=plan['book_version']),
              updated=[dict(chapterUid=int(plan['chapter_uid']),chapterIdx=plan['chapter_idx'])])]
    pairs=[[deepcopy(cat),deepcopy(cat)],[deepcopy(cat),deepcopy(cat)]]
    report=dict(result='CB_CROSS_DAY_READONLY_VERIFIED',seconds=plan['seconds'],observed_months=len(before['months']),completed_at=now,
        exact_capture_and_source_bound=True,both_positions_counts_source_shelves_exact=True,two_statistics_reads_stable=True,
        server_clock_after_boundary=True,account_data_posts=0,authentication_posts=0,historical_accounting_verified=False,dispatch_capability=False)
    return bundle,grant,report,before['snapshot'],before['months'],pairs


class ImportedEvidenceTests(unittest.TestCase):
    def test_catalog_matches_independent_lua_signature(self):
        bundle,_grant,_report,_snapshot,_months,pairs=fixture()
        self.assertEqual(catalog_check(pairs[0][0],bundle['plan']),
                         (2,'60b3d8bfdc9d8f179e4712218f57aaf4eaf859ff470a713090dcfe09fc7018b5'))
    def test_sealed_private_inputs_and_bound_grant(self):
        bundle,grant,report,snapshot,months,pairs=fixture();e=PreflightEvidence(bundle,grant,report,snapshot,months,pairs)
        self.assertEqual(repr(e),'<CBPreflightEvidence private>')
        self.assertEqual(e.for_bundle(bundle,grant),(report,snapshot,months))
        self.assertEqual(e.catalog_stamp(bundle,grant),catalog_check(pairs[0][0],bundle['plan'])[1])
        changed=deepcopy(grant);changed['accessToken']='other-token'
        with self.assertRaises(ValueError):e.for_bundle(bundle,changed)
        changed=deepcopy(bundle);changed['plan']['baseline_sha256']='f'*64
        with self.assertRaises(ValueError):e.for_bundle(changed,grant)
        snapshot['native']['summary']['value']='changed'
        self.assertNotEqual(snapshot,e.for_bundle(bundle,grant)[1])
    def test_unsupported_report_and_unstable_catalog_fail(self):
        for mode in ('missing','post','freshness','authority','baseline','version','conflicting_version','index','nested_identity','changed_catalog','missing_version'):
            bundle,grant,report,snapshot,months,pairs=fixture()
            if mode=='missing':del report['server_clock_after_boundary']
            elif mode=='post':report['account_data_posts']=1
            elif mode=='freshness':report['completed_at']=bundle['plan']['not_before']-1
            elif mode=='authority':report['dispatch_capability']=True
            elif mode=='baseline':snapshot['counts']['readingTime']+=1
            elif mode=='version':pairs[0][0][0]['book']['bookVersion']=8
            elif mode=='conflicting_version':pairs[0][0][0]['version']=8
            elif mode=='index':pairs[0][0][0]['updated'][0]['chapterIdx']=3
            elif mode=='nested_identity':pairs[0][0][0]['book']['bookId']='CB_Other'
            elif mode=='missing_version':del pairs[0][0][0]['book']['bookVersion']
            else:pairs[1][1][0]['updated'][0]['version']=2
            with self.subTest(mode=mode),self.assertRaises(ValueError):PreflightEvidence(bundle,grant,report,snapshot,months,pairs)


if __name__=='__main__':unittest.main()
