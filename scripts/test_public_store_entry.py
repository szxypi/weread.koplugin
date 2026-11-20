import unittest

from run_public_store_entry import valid_stage


class PublicStoreReportTests(unittest.TestCase):
    def test_requires_guarded_online_and_offline_native_stages(self):
        live = dict(result='PASS', phase='complete', mode='live', requests=2, forbidden=0,
                    first=20, second=20, guest=True, native_host=True, offline=False)
        offline = dict(live, mode='reopen', requests=0, offline=True)
        self.assertTrue(valid_stage(live, 0, False, 'live'))
        self.assertTrue(valid_stage(offline, 0, False, 'reopen'))
        for changed in ({'forbidden': 1}, {'requests': 3}, {'guest': False}, {'native_host': False},
                        {'first': 0}, {'second': True}, {'offline': True}, {'extra': 'unexpected'}):
            with self.subTest(changed=changed):
                self.assertFalse(valid_stage(dict(live, **changed), 0, False, 'live'))
        self.assertFalse(valid_stage(dict(offline, requests=1), 0, False, 'reopen'))
        self.assertFalse(valid_stage(live, 1, False, 'live'))
        self.assertFalse(valid_stage(live, 0, True, 'live'))
        self.assertFalse(valid_stage(live, 0, False, 'reopen'))
        self.assertFalse(valid_stage(None, 0, False, 'live'))


if __name__ == '__main__':
    unittest.main()
