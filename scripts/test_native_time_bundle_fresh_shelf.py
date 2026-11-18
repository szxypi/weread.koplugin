"""Fresh shelf readback comparison remains distinct from old trial recovery."""
from copy import deepcopy
import unittest

from cloud_group_contract import project
from native_time_bundle_evidence import FreshShelfEvidence
from native_time_bundle_fresh_shelf import compare
from test_cloud_group_nonempty_contract import TARGET,source
from test_native_time_bundle_evidence import fresh_fixture
from txt_full_summary import digest


def example():
    bundle,grant,before,report,_now,pairs,_shelves,_evidence=fresh_fixture()
    native=source();native['archive'][0]['bookIds'].remove(TARGET)
    web=deepcopy(native)
    # Keep different full channel projections to ensure comparison is per channel.
    web['books'][0]['bookId']='900008'
    shelves=(digest(project(native)),digest(project(web)))
    evidence=FreshShelfEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,shelves)
    group=dict(phase='create_claimed',dispatched=True,native_fixture_present=True,web_fixture_present=True,
               native_group_present=False,web_group_present=False)
    original=dict(native_original_state_unchanged=False,web_original_state_unchanged=False,old_group_absent=True)
    row=dict(native=native,web=web,group=group,original=original)
    return bundle,grant,evidence,[deepcopy(row),deepcopy(row)]


class FreshShelfTests(unittest.TestCase):
    def test_two_exact_independent_observations_are_read_only(self):
        bundle,grant,evidence,observations=example()
        result=compare(evidence,bundle,grant,TARGET,observations)
        self.assertEqual(result,dict(result='FRESH_SHELF_MATCH',compared_observations=2,
                                     historical_accounting_verified=False,dispatch_capability=False))

    def test_any_changed_or_missing_state_rejects_comparison(self):
        for mode in ('one','extra','channel','swapped','removed_fixture','grouped_fixture',
                     'old_flag','old_group','new_group','identity','evidence'):
            bundle,grant,evidence,observations=example()
            if mode=='one':observations.pop()
            elif mode=='extra':observations[0]['unexpected']=True
            elif mode=='channel':observations[1]['web']['books'][0]['bookId']='900009'
            elif mode=='swapped':observations[1]['native'],observations[1]['web']=observations[1]['web'],observations[1]['native']
            elif mode=='removed_fixture':observations[0]['native']['books'].pop()
            elif mode=='grouped_fixture':observations[0]['web']['archive'][0]['bookIds'].append(TARGET)
            elif mode=='old_flag':observations[1]['original']['native_original_state_unchanged']=True
            elif mode=='old_group':observations[0]['original']['old_group_absent']=False
            elif mode=='new_group':observations[1]['group']['web_group_present']=True
            elif mode=='identity':grant['accessToken']='different-synthetic-token'
            else:evidence._value=(*evidence._value[:3],('a'*64,'b'*64))
            with self.subTest(mode=mode),self.assertRaises(ValueError):
                compare(evidence,bundle,grant,TARGET,observations)


if __name__=='__main__':unittest.main()
