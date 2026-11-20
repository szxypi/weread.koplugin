"""Isolated lectureBookIds trial: transport scope, durability and readback."""
import unittest
from unittest.mock import patch

from cloud_group_contract import digest
from cloud_group_journal import Journal
from cloud_group_trial import Trial
from test_cloud_group_trial import Fake, Memory
from test_secure_native_session import credentials
from verify_cloud_group_lecture_field import DispatchClaims, ScopedNative, create_request
from verify_eink_login import NativeProbe


class LectureFieldTest(unittest.TestCase):
    def setup_trial(self,mode=None):
        fake=Fake();fake.mode=mode;grant=credentials();journal=Journal(backend=Memory());claims=DispatchClaims(Memory())
        transport=ScopedNative(journal,claims,grant,lambda:True)
        trial=Trial(journal,fake.read,transport.post,lambda:True,sleep=lambda _:None,request_builder=create_request)
        def request(_self,_stage,url,body=None,credentials=None,timeout=15):
            self.assertEqual(credentials,grant)
            return fake.post(url.removeprefix('https://i.weread.qq.com'),body)
        return fake,grant,journal,claims,transport,trial,request

    def test_exact_shape_and_successful_roundtrip(self):
        fake,grant,journal,claims,transport,trial,request=self.setup_trial()
        with patch('verify_cloud_group_lecture_field.no_other_pending',return_value=True),patch.object(NativeProbe,'request',request):
            result=trial.run(grant['vid'],digest(grant))
            self.assertEqual(result['result'],'PASS');self.assertEqual(transport.posts,2)
            self.assertEqual(set(fake.posts[0][1]),{'bookIds','lectureBookIds','archiveId','name'})
            self.assertEqual(fake.posts[0][1]['lectureBookIds'],[])
            self.assertEqual(fake.posts[1][1],{'archiveId':42,'removeBooks':0})
            self.assertEqual(journal.read()[0]['phase'],'restored')
            self.assertEqual(trial.run(grant['vid'],digest(grant))['data_posts'],0)
            self.assertEqual(len(fake.posts),2)

    def test_unknown_response_and_interruption_never_replay(self):
        for mode,phase,count in (('create_lost','create_claimed',1),('delete_lost','delete_claimed',2)):
            fake,grant,journal,claims,transport,trial,request=self.setup_trial(mode)
            with self.subTest(mode=mode),patch('verify_cloud_group_lecture_field.no_other_pending',return_value=True),patch.object(NativeProbe,'request',request):
                result=trial.run(grant['vid'],digest(grant))
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(journal.read()[0]['phase'],phase)
                state,_=journal.read();replacement=ScopedNative(journal,claims,grant,lambda:True)
                path='/shelf/archive' if phase=='create_claimed' else '/shelf/deleteArchive'
                body=create_request(state['name']) if phase=='create_claimed' else {'archiveId':42,'removeBooks':0}
                with self.assertRaises(ValueError):replacement.post(path,body)
                self.assertEqual(len(fake.posts),count)

    def test_dispatch_claim_persists_before_sending_and_blocks_invalid_requests(self):
        fake,grant,journal,claims,transport,_trial,request=self.setup_trial()
        token=journal.begin(grant['vid'],digest(grant),'KOReader-Test-'+'a'*24,'a'*64,'b'*64)
        journal.advance(token,'create_claimed');state,_=journal.read()
        body=create_request(state['name'])
        with patch('verify_cloud_group_lecture_field.no_other_pending',return_value=True),patch.object(NativeProbe,'request',request):
            with self.assertRaises(ValueError):transport.post('/shelf/archive',dict(body,albumIds=[]))
            self.assertEqual(fake.posts,[])
            claims.claim(journal,grant,'create_claimed')  # Simulates a crash before the HTTP call.
            with self.assertRaises(ValueError):transport.post('/shelf/archive',body)
            self.assertEqual(fake.posts,[])

    def test_unrelated_shelf_change_stops_before_delete(self):
        fake,grant,journal,_claims,transport,trial,request=self.setup_trial('unrelated')
        with patch('verify_cloud_group_lecture_field.no_other_pending',return_value=True),patch.object(NativeProbe,'request',request):
            result=trial.run(grant['vid'],digest(grant))
            self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(transport.posts,1)
            self.assertEqual(journal.read()[0]['phase'],'create_claimed')

    def test_malformed_claims_and_other_pending_block_dispatch(self):
        fake,grant,journal,claims,transport,_trial,request=self.setup_trial()
        token=journal.begin(grant['vid'],digest(grant),'KOReader-Test-'+'b'*24,'a'*64,'b'*64)
        journal.advance(token,'create_claimed');state,_=journal.read();body=create_request(state['name'])
        with patch('verify_cloud_group_lecture_field.no_other_pending',return_value=False),patch.object(NativeProbe,'request',request):
            with self.assertRaises(ValueError):transport.post('/shelf/archive',body)
        claims.backend.raw=b'{}'
        with patch('verify_cloud_group_lecture_field.no_other_pending',return_value=True),patch.object(NativeProbe,'request',request):
            with self.assertRaises(ValueError):transport.post('/shelf/archive',body)
        self.assertEqual(fake.posts,[])


if __name__=='__main__':unittest.main()
