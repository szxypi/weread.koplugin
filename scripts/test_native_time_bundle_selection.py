"""The exact native source, individual intervals and queue hashes are required."""
from copy import deepcopy
import unittest

from native_time_bundle_selection import expected,native_digest,validate_selection
from test_native_time_capture_evidence import bundle,make_fixture


def fixture():
    p,ledger,coverage=make_fixture();value={'plan':p,'evidence':bundle(ledger,coverage)}
    ledger.close();coverage.close();return value


class SelectionTests(unittest.TestCase):
    def test_exact_selection_is_required(self):
        captured=fixture();selection=expected(captured)
        self.assertEqual(validate_selection(captured,selection),selection)
        saved=deepcopy(captured);selection['rows'][0]['duration']-=1
        self.assertEqual(captured,saved);selection=expected(captured)
        for field in ('book_id','file_id','book_version','time_zone','seconds','rows_hash','parts_hash'):
            changed=deepcopy(selection);changed[field]=None
            with self.subTest(field=field),self.assertRaises(ValueError):validate_selection(captured,changed)
        for field in ('rows','parts','protocol_rows'):
            changed=deepcopy(selection);changed[field][0]['duration']-=1
            with self.subTest(field=field),self.assertRaises(ValueError):validate_selection(captured,changed)
        for field in ('rows','parts','protocol_rows'):
            changed=deepcopy(selection);changed[field][0]['duration']=True
            with self.subTest(field=field),self.assertRaises(ValueError):validate_selection(captured,changed)
        changed=deepcopy(selection);changed['extra']=1
        with self.assertRaises(ValueError):validate_selection(captured,changed)

    def test_digest_is_strict_and_empty_lua_table_is_map(self):
        self.assertEqual(native_digest([]),native_digest({}))
        self.assertNotEqual(native_digest([1]),native_digest([True]))
        self.assertNotEqual(native_digest('中'),native_digest('a'))
        for invalid in (float('nan'),float('inf'),2**54,None,{1:'x'}):
            with self.subTest(invalid=invalid),self.assertRaises(ValueError):native_digest(invalid)


if __name__=='__main__':unittest.main()
