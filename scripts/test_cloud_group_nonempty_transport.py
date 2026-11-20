"""Only the exact claimed request and bound fixture can reach transport."""
import unittest
from unittest.mock import patch

from cloud_group_contract import digest
from cloud_group_nonempty_contract import create_request
from cloud_group_nonempty_journal import Journal
from cloud_group_nonempty_transport import ScopedNative
from personal_upload_trial import hash_value
from test_cloud_group_nonempty_trial import fixture
from test_secure_native_session import Backend, credentials
from verify_eink_login import NativeProbe, ProbeError


class TransportTest(unittest.TestCase):
    def prepare(self, pending=lambda:True, old=lambda:True):
        grant=credentials(); bound=fixture(); upload,_=bound(); journal=Journal(Backend())
        token=journal.begin(owner=grant['vid'],grant_hash=digest(grant),name='KOReader-Test-'+'a'*24,
                            target=upload['target'],upload_attempt=upload['attempt'],upload_plan_hash=hash_value(upload['plan']),
                            native_before='a'*64,web_before='b'*64)
        token=journal.advance(token,'create_claimed')
        return ScopedNative(journal,bound,grant,lambda:True,pending,old),journal,token

    def test_exact_once_even_after_transport_failure(self):
        transport,journal,_=self.prepare();state,_=journal.read();body=create_request(state['name'],state['target'])
        with patch.object(NativeProbe,'request',side_effect=TimeoutError()) as request:
            with self.assertRaises(TimeoutError):transport.post('/shelf/archive',body)
            with self.assertRaises(ProbeError):transport.post('/shelf/archive',body)
            replacement=ScopedNative(journal,transport.fixture,transport.grant,lambda:True,lambda:True,lambda:True)
            with self.assertRaises(ProbeError):replacement.post('/shelf/archive',body)
        self.assertEqual(request.call_count,1);self.assertEqual(transport.write_attempts,1)

    def test_wrong_target_unrelated_pending_or_old_group_refuses_send(self):
        for pending,old,wrong in ((lambda:False,lambda:True,False),(lambda:True,lambda:False,False),
                                  (lambda:True,lambda:True,True)):
            transport,journal,_=self.prepare(pending,old);state,_=journal.read()
            body=create_request(state['name'],'CB_other' if wrong else state['target'])
            with self.subTest(wrong=wrong), patch.object(NativeProbe,'request') as request:
                with self.assertRaises(ProbeError):transport.post('/shelf/archive',body)
                request.assert_not_called()

    def test_delete_is_bound_to_proven_group_and_preserves_books(self):
        transport,journal,token=self.prepare();token=journal.claim_dispatch(token,'create_claimed');token=journal.advance(token,'created',group_id_value='43')
        journal.advance(token,'delete_claimed')
        with patch.object(NativeProbe,'request',return_value={'succ':1}) as request:
            for body in ({'archiveId':43,'removeBooks':1},{'archiveId':44,'removeBooks':0}):
                with self.assertRaises(ProbeError):transport.post('/shelf/deleteArchive',body)
            self.assertEqual(transport.post('/shelf/deleteArchive',{'archiveId':43,'removeBooks':0}),{'succ':1})
            self.assertEqual(request.call_count,1)


if __name__=='__main__':unittest.main()
