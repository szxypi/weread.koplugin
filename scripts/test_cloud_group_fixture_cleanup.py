"""Owned group fixture cleanup: isolated target, stable reads and no replay."""
from copy import deepcopy
import unittest
from unittest.mock import patch

from cloud_group_contract import digest
from cloud_group_fixture_cleanup import Intent,execute,make_plan,project_before,project_after
from secure_weread_session import StoreError
from test_cloud_group_contract import shelf
from test_secure_native_session import Backend,credentials
from verify_cloud_group_fixture_cleanup import ScopedNative
from verify_eink_login import NativeProbe

TARGET='CB_synthetic123'
NAMES=('KOReader-Test-'+'a'*24,'KOReader-Test-'+'b'*24)


class Fake:
    def __init__(self):
        self.value=shelf();self.value['books'].append(dict(bookId=TARGET,title='Synthetic import',finishReading=0))
        self.valid=True;self.sent=[];self.notes={'empty':True,'unstarted':True,'native_state':'a'*64,'web_state':'b'*64}
        self.lag=0;self.ack=True;self.fail=False
    def current(self):return self.valid
    def read_pair(self):
        native=deepcopy(self.value);web=deepcopy(self.value)
        if self.lag:
            web['books'].append(dict(bookId=TARGET,title='Synthetic import',finishReading=0));self.lag-=1
        return dict(native=native,web=web)
    def read_notes(self):return deepcopy(self.notes)
    def send(self,target,receipt,plan):
        assert target==TARGET;self.sent.append((receipt,plan));self.value['books']=[x for x in self.value['books'] if x['bookId']!=target]
        if self.fail:raise TimeoutError()
        return self.ack


def case():
    fake=Fake();intent=Intent(Backend());grant=credentials();group={'synthetic':'group'};upload={'synthetic':'upload'}
    def run(apply=False):return execute('900000',grant,TARGET,group,upload,NAMES,intent,fake.current,fake.read_pair,fake.read_notes,fake.send,apply=apply,sleep=lambda _:None)
    return fake,intent,run


class Tests(unittest.TestCase):
    def test_preview_then_one_cleanup(self):
        fake,intent,run=case();self.assertEqual(run()['result'],'READ_ONLY_PREVIEW');self.assertEqual(intent.read(),(None,None))
        self.assertEqual(run(True)['result'],'FIXTURE_CLEANED');self.assertEqual(len(fake.sent),1)
        self.assertEqual(intent.read()[0]['phase'],'verified');self.assertNotIn(TARGET,str(intent.read()[0]))
        with self.assertRaises(ValueError):run(True)
        self.assertEqual(len(fake.sent),1)

    def test_unknown_or_lost_ack_is_never_replayed(self):
        for lost in (False,True):
            fake,intent,run=case();fake.ack=False;fake.fail=lost
            with self.assertRaises((ValueError,TimeoutError)):run(True)
            self.assertEqual(intent.read()[0]['phase'],'claimed');self.assertEqual(len(fake.sent),1)
            with self.assertRaises(ValueError):run(True)
            self.assertEqual(len(fake.sent),1)

    def test_other_groups_or_notes_block_before_any_write(self):
        for kind in ('group','pending_group','notes','position','owner'):
            fake,intent,run=case()
            if kind=='group':fake.value['archive'][0]['bookIds'].append(TARGET)
            elif kind=='pending_group':fake.value['archive'].append(dict(archiveId=7,name=NAMES[0],bookIds=[],albumIds=[]))
            elif kind=='notes':fake.notes['empty']=False
            elif kind=='position':fake.notes['unstarted']=False
            else:fake.valid=False
            with self.assertRaises(ValueError):run(True)
            self.assertEqual(fake.sent,[]);self.assertEqual(intent.read(),(None,None))

    def test_current_shelf_change_after_send_is_never_confirmed(self):
        fake,intent,run=case();send=fake.send
        def modified(*args):
            result=send(*args);fake.value['books'][0]['secret']=1;return result
        with self.assertRaises(ValueError):execute('900000',credentials(),TARGET,{'synthetic':'group'},{'synthetic':'upload'},NAMES,
            intent,fake.current,fake.read_pair,fake.read_notes,modified,apply=True,sleep=lambda _:None)
        self.assertEqual(intent.read()[0]['phase'],'claimed');self.assertEqual(len(fake.sent),1)

    def test_delayed_web_readback_does_not_repeat_write(self):
        fake,intent,run=case();send=fake.send
        def delayed(*args):result=send(*args);fake.lag=1;return result
        result=execute('900000',credentials(),TARGET,{'synthetic':'group'},{'synthetic':'upload'},NAMES,
                       intent,fake.current,fake.read_pair,fake.read_notes,delayed,apply=True,sleep=lambda _:None)
        self.assertEqual(result['result'],'FIXTURE_CLEANED');self.assertEqual(len(fake.sent),1)

    def test_transport_requires_same_exact_claim_and_only_target(self):
        fake,intent,_=case();grant=credentials();group={'synthetic':'group'};upload={'synthetic':'upload'}
        full,without=project_before(fake.read_pair(),TARGET,NAMES)
        plan=make_plan('900000',grant,TARGET,group,upload,fake.notes,full,without)
        receipt=intent.advance(intent.reserve(plan),'claimed')
        probe=ScopedNative(grant,fake.current,intent,group,upload,TARGET)
        with patch('verify_cloud_group_fixture_cleanup.no_other_pending',return_value=True),patch.object(NativeProbe,'request',return_value={'succ':1}) as req:
            with self.assertRaises(ValueError):probe.delete('CB_other',receipt,plan)
            self.assertTrue(probe.delete(TARGET,receipt,plan))
            with self.assertRaises(ValueError):probe.delete(TARGET,receipt,plan)
            self.assertEqual(req.call_count,1)
            self.assertEqual(req.call_args.kwargs['body'],dict(bookIds=[TARGET],albumIds=[],archiveIds=[]))

    def test_intent_corruption_and_changed_tokens_fail_closed(self):
        fake,intent,_=case();full,without=project_before(fake.read_pair(),TARGET,NAMES)
        plan=make_plan('900000',credentials(),TARGET,{}, {},fake.notes,full,without);old=intent.reserve(plan)
        claimed=intent.advance(old,'claimed')
        with self.assertRaises(StoreError):intent.advance(old,'claimed')
        with self.assertRaises(StoreError):intent.advance(claimed,'claimed')
        intent.backend.save(b'{"schema":true}')
        with self.assertRaises(StoreError):intent.read()


if __name__=='__main__':unittest.main()
