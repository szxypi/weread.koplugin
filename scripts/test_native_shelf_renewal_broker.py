"""Offline renewal brokerage: expiry, one authorization and no replay."""
from copy import deepcopy
import hashlib,time,unittest
from native_shelf_renewal_broker import Broker,shelf_projection
from secure_native_session import NativeSessionStore
from test_secure_native_session import Backend


def grant():return dict(vid='12345678',deviceId='eink334691225'+'0'*19,accessToken='synthetic-access',refreshToken='synthetic-refresh')
def body(credentials):
    stamp=int(time.time()*1000);random=123
    return dict(deviceId=credentials['deviceId'],deviceName='BOOX',deviceType=3,timestamp=stamp,random=random,trackId='',
        refreshToken=credentials['refreshToken'],inBackground=0,kickType=1,refCgi='',
        signature=hashlib.sha256(f"{stamp}{credentials['deviceId']}{random}".encode()).hexdigest())


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.grant=grant();self.store=NativeSessionStore(Backend());self.store.save(self.grant,self.grant['vid'],verified=True)
        self.raw=dict(books=[dict(bookId='42',title='Synthetic',author='Author')],archive=[dict(archiveId=3,name='Group',bookIds=['42'])])
        self.projected=shelf_projection(self.raw);self.claims=0
        def claim():self.claims+=1
        self.broker=Broker(self.grant,self.store,current=lambda:None,verify_expiry=lambda _grant:True,
            observe=lambda _grant:self.projected,claim=claim)
    def expiry(self):return self.broker.handle(dict(kind='expiry',status=401),True)
    def claim(self,armed=True):return self.broker.handle(dict(kind='claim',body=body(self.grant)),armed)
    def test_dry_does_not_claim_or_renew(self):
        self.assertTrue(self.expiry());self.assertFalse(self.claim(False))
        self.assertEqual(self.claims,0);self.assertEqual(self.store.load(self.grant['vid']),self.grant)
        with self.assertRaises(ValueError):self.claim(False)
    def test_verified_renewal_saves_same_account_and_checks_ui_shelf(self):
        self.expiry();self.assertTrue(self.claim());fresh=dict(self.grant,accessToken='synthetic-renewed')
        self.assertTrue(self.broker.handle(dict(kind='verified',credentials=fresh,book_count=1),True))
        self.assertTrue(self.broker.handle(dict(kind='shelf',snapshot=dict(books=self.raw['books'],archives=self.raw['archive'])),True))
        self.assertEqual(self.store.load(self.grant['vid']),fresh);self.assertEqual(self.broker.phase,'complete');self.assertEqual(self.claims,1)
        with self.assertRaises(ValueError):self.claim()
    def test_unconfirmed_result_retains_pending_and_cannot_replay(self):
        self.expiry();self.claim()
        with self.assertRaises(Exception):self.store.load(self.grant['vid'])
        with self.assertRaises(ValueError):self.claim()
        self.assertEqual(self.claims,1)
    def test_wrong_expiry_request_or_new_owner_is_rejected(self):
        self.broker.verify_expiry=lambda _grant:False
        with self.assertRaises(ValueError):self.expiry()
        self.broker.verify_expiry=lambda _grant:True;self.expiry();bad=body(self.grant);bad['signature']='0'*64
        with self.assertRaises(ValueError):self.broker.handle(dict(kind='claim',body=bad),True)
        self.assertEqual(self.claims,0);self.claim()
        fresh=dict(self.grant,vid='900001')
        with self.assertRaises(ValueError):self.broker.handle(dict(kind='verified',credentials=fresh,book_count=1),True)
        self.assertEqual(self.broker.phase,'claimed')
    def test_changed_shelf_after_save_is_not_accepted(self):
        self.expiry();self.claim();fresh=dict(self.grant,accessToken='synthetic-renewed')
        self.broker.handle(dict(kind='verified',credentials=fresh,book_count=1),True)
        changed=deepcopy(self.raw);changed['books'][0]['title']='Different'
        with self.assertRaises(ValueError):self.broker.handle(dict(kind='shelf',snapshot=changed),True)
        self.assertEqual(self.broker.phase,'verified');self.assertEqual(self.store.load(self.grant['vid']),fresh)
    def test_duplicate_ids_or_ambiguous_group_are_rejected(self):
        for change in ('book','group'):
            raw=deepcopy(self.raw)
            if change=='book':raw['books'].append(deepcopy(raw['books'][0]))
            else:raw['archive'].append(deepcopy(raw['archive'][0]))
            with self.assertRaises(ValueError):shelf_projection(raw)


if __name__=='__main__':unittest.main()
