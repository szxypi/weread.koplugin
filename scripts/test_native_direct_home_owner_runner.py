"""Credential audit checks for disposable real-account reader profiles."""
import unittest
from run_native_direct_home_owner import contains_private


class CredentialAuditTests(unittest.TestCase):
    def test_long_secret_detected_without_context(self):
        self.assertTrue(contains_private(b'prefix-abcdefgh-suffix','wr_skey',b'abcdefgh'))
        self.assertFalse(contains_private(b'prefix-other-suffix','wr_skey',b'abcdefgh'))

    def test_short_cookie_requires_keyed_assignment(self):
        for text in (b'{"wr_ql":"1"}',b'["wr_ql"] = "1"',b'Cookie: wr_ql=1; Path=/'):
            self.assertTrue(contains_private(text,'wr_ql',b'1'))
        for text in (b'chapter 1',b'{"other":"1"}',b'{"wr_ql":"10"}',b'not_wr_ql=1'):
            self.assertFalse(contains_private(text,'wr_ql',b'1'))


if __name__=='__main__':
    unittest.main()
