"""A fixture cannot be cleaned until the bound group is confirmed restored."""
import unittest

from cloud_group_contract import digest
from cloud_group_fixture import Journal as UploadJournal
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_upload_transport import GuardedUploadProbe
from personal_upload_trial import hash_value
from synthetic_format_trial import TargetReceipt
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials
from verify_synthetic_epub_upload import run


class UploadTransportTest(unittest.TestCase):
    def test_cleanup_requires_matching_restored_group_and_prior_guard(self):
        grant=credentials();upload=UploadJournal(Backend());target=TargetReceipt('epub',backend=Backend(),scope='group-fixture')
        run(FakeProbe(),upload,grant,lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,
            notify_receipt=target.record,cleanup_gate=lambda *_:False)
        state,receipt=upload.read();group=GroupJournal(Backend());guard_calls=[]
        probe=GuardedUploadProbe(upload,lambda _:True,group,target,lambda baseline:guard_calls.append(baseline),lambda:True)
        receipt=upload.advance(receipt,'cleanup_pending')
        with self.assertRaises(ValueError):probe.owns('cleanup_pending',grant,receipt)
        token=group.begin(owner=grant['vid'],grant_hash=digest(grant),name='KOReader-Test-'+'a'*24,
                          target=state['target'],upload_attempt=state['attempt'],upload_plan_hash=hash_value(state['plan']),
                          native_before='a'*64,web_before='b'*64)
        token=group.advance(token,'create_claimed');token=group.claim_dispatch(token,'create_claimed')
        token=group.advance(token,'created',group_id_value='43');token=group.advance(token,'delete_claimed')
        token=group.claim_dispatch(token,'delete_claimed');group.advance(token,'restored')
        self.assertEqual(probe.owns('cleanup_pending',grant,receipt)['phase'],'cleanup_pending')
        self.assertEqual(guard_calls,[False,False])
        probe.pending=lambda:False
        with self.assertRaises(ValueError):probe.owns('cleanup_pending',grant,receipt)


if __name__=='__main__':unittest.main()
