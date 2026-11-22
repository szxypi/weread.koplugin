import unittest
from unittest.mock import patch
from secure_pin_trial import PinTrialStore
from test_pin_trial_contract import Fixture
from verify_pin_preflight import fingerprint
from resolve_pin_added_book import cleanup,RemovalProbe
from verify_eink_login import BASE


class CleanupTests(unittest.TestCase):
    def test_unknown_add_receipt_cannot_authorize_removal(self):
        f=Fixture(False);_,raw=f.store.reserve(f.plan,fingerprint(f.progress),'c'*64)
        f.store.advance(raw,'add_pending');f.present=True
        with self.assertRaises(ValueError):cleanup(f.store,f.current,f.read,lambda:f.write('remove'),apply=True)
        self.assertEqual(f.writes,[])

    def setup_trial(self):
        f=Fixture(False);_,raw=f.store.reserve(f.plan,fingerprint(f.progress),'c'*64)
        _,raw=f.store.advance(raw,'add_pending');f.store.advance(raw,'add_acknowledged');f.present=True
        return f
    def test_preview_then_one_cleanup_and_restore(self):
        f=self.setup_trial()
        result=cleanup(f.store,f.current,f.read,lambda:f.write('remove'))
        self.assertEqual(result['result'],'CLEANUP_PREVIEW_VERIFIED');self.assertEqual(f.writes,[])
        result=cleanup(f.store,f.current,f.read,lambda:f.write('remove'),apply=True)
        self.assertEqual(result['result'],'ADDED_BOOK_REMOVED_AND_ORIGINAL_VERIFIED')
        self.assertEqual(f.writes,['remove']);self.assertEqual(f.store.read()[0]['phase'],'add_cleanup_restored')
        self.assertFalse(f.store.pending())
        with self.assertRaises(ValueError):cleanup(f.store,f.current,f.read,lambda:f.write('remove'),apply=True)
    def test_ambiguous_removal_is_not_retried(self):
        f=self.setup_trial();f.bad='receipt'
        with self.assertRaises(ValueError):cleanup(f.store,f.current,f.read,lambda:f.write('remove'),apply=True)
        self.assertEqual(f.writes,['remove']);self.assertEqual(f.store.read()[0]['phase'],'add_cleanup_pending')
        with self.assertRaises(ValueError):cleanup(f.store,f.current,f.read,lambda:f.write('remove'),apply=True)
    def test_change_or_pinned_prevents_removal(self):
        for kind in ('unrelated','pinned'):
            f=self.setup_trial()
            if kind=='unrelated':f.bad=kind
            else:f.visible=True;f.pinned=True
            with self.subTest(kind=kind),self.assertRaises(ValueError):cleanup(f.store,f.current,f.read,lambda:f.write('remove'),apply=True)
            self.assertEqual(f.writes,[]);self.assertEqual(f.store.read()[0]['phase'],'add_acknowledged')
    def test_progress_not_restored_preserves_pending(self):
        f=self.setup_trial();original=f.write
        def remove():
            result=original('remove');f.bad='progress';return result
        with self.assertRaisesRegex(ValueError,'cleanup/progress'):cleanup(f.store,f.current,f.read,remove,apply=True)
        self.assertEqual(f.writes,['remove']);self.assertEqual(f.store.read()[0]['phase'],'add_cleanup_pending')
    def test_removal_transport_is_one_shot(self):
        p=RemovalProbe();p.target='42';creds={'vid':'123','accessToken':'synthetic'};p.grant=fingerprint(creds)
        with patch('verify_eink_login.NativeProbe.request',return_value={'succ':1}) as request:
            p.remove(creds)
            with self.assertRaises(ValueError):p.remove(creds)
        self.assertEqual(request.call_count,1);self.assertEqual(p.attempts,1)
        self.assertEqual(request.call_args.args[0:3],('cleanup_remove',BASE+'/shelf/delete',{'bookIds':['42']}))


if __name__=='__main__':unittest.main()
