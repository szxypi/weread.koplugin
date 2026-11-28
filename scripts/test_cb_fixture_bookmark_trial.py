"""Offline point, isolation and no-replay tests for fresh CB bookmarks."""
from copy import deepcopy
import unittest

from cb_fixture_bookmark_trial import Intent,execute,prepare
from test_cb_fixture_highlight_trial import fixture
from test_secure_native_session import Backend


class Fake:
    def __init__(self,baseline,body,*,fail=None,omit_preview=False):
        self.original=deepcopy(baseline);self.value=deepcopy(baseline);self.body=body;self.fail=fail
        self.omit_preview=omit_preview;self.sent=[];self.valid=True
    def owned(self):return self.valid
    def read(self):return deepcopy(self.value)
    def send(self,phase,body,_receipt):
        self.sent.append(phase)
        if phase=='create_pending':
            assert body==self.body
            row={k:v for k,v in body.items() if k not in ('bookId','bookVersion')};row['bookmarkId']='new-bookmark'
            if self.omit_preview:row.pop('markText')
            self.value['marks']['updated']['new-bookmark']=row
        else:
            assert body=={'bookmarkIds':['new-bookmark']};self.value['marks']['updated'].pop('new-bookmark')
        if self.fail==phase:raise RuntimeError('unknown effect')


def case(**kwargs):
    sample,baseline,_plan,_body=fixture();plan,body=prepare('900000','CB_Synthetic42','a'*32,sample,1,baseline)
    fake=Fake(baseline,body,**kwargs);intent=Intent(Backend())
    def run():return execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send)
    return fake,intent,run


class BookmarkTests(unittest.TestCase):
    def test_roundtrip_with_and_without_server_preview(self):
        for omitted in (False,True):
            with self.subTest(omitted=omitted):
                fake,intent,run=case(omit_preview=omitted);result=run()
                self.assertEqual(result['writes'],2);self.assertEqual(fake.sent,['create_pending','delete_pending'])
                self.assertEqual(result['server_preview_returned'],not omitted)
                self.assertEqual(fake.value,fake.original);self.assertEqual(intent.read(),(None,None))
                self.assertEqual(fake.body['type'],0);self.assertEqual(fake.body['style'],0)

    def test_uncertain_write_never_replays(self):
        for phase in ('create_pending','delete_pending'):
            with self.subTest(phase=phase):
                fake,intent,run=case(fail=phase)
                with self.assertRaises(RuntimeError):run()
                sent=list(fake.sent);self.assertEqual(intent.read()[0]['phase'],phase)
                with self.assertRaises(ValueError):run()
                self.assertEqual(fake.sent,sent)

    def test_changed_or_unowned_fixture_never_dispatches(self):
        fake,intent,run=case();fake.value['position']['chapter']='changed'
        with self.assertRaises(ValueError):run()
        fake.value=deepcopy(fake.original);fake.valid=False
        with self.assertRaises(ValueError):run()
        self.assertEqual(fake.sent,[]);self.assertEqual(intent.read(),(None,None))

    def test_unrelated_change_stops_before_delete(self):
        fake,intent,run=case();send=fake.send
        def altered(phase,body,receipt):
            send(phase,body,receipt);fake.value['thoughts']['unrelated']={}
        with self.assertRaises(ValueError):execute(*self.plan_for(fake,intent),fake.owned,fake.read,altered)
        self.assertEqual(fake.sent,['create_pending']);self.assertEqual(intent.read()[0]['phase'],'create_pending')

    @staticmethod
    def plan_for(fake,intent):
        sample,baseline,_plan,_body=fixture();plan,body=prepare('900000','CB_Synthetic42','a'*32,sample,1,baseline)
        return plan,body,baseline,intent


if __name__=='__main__':unittest.main()
