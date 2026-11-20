"""The restored bundle is inspected only on its actual captured day."""
from copy import deepcopy
import unittest

from test_native_time_capture_evidence import bundle,make_fixture
from run_native_time_bundle_inspect import validate_input


class BundleInspectTests(unittest.TestCase):
    def test_requires_complete_evidence_and_actual_day_bounds(self):
        plan,ledger,coverage=make_fixture();proof=bundle(ledger,coverage)
        value={'plan':plan,'evidence':proof}
        self.assertEqual(validate_input(value,plan['ended_at']),value)
        self.assertEqual(validate_input(value,plan['not_before']-1),value)
        for now in (plan['ended_at']-1,plan['not_before']):
            with self.subTest(now=now),self.assertRaises(ValueError):validate_input(value,now)
        broken=deepcopy(value);broken['evidence']['coverage_sha256']='0'*64
        with self.assertRaises(ValueError):validate_input(broken,plan['ended_at'])
        ledger.close();coverage.close()


if __name__=='__main__':unittest.main()
