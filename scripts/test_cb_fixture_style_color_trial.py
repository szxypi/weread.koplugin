"""Imported style/color matrix: exact scope, claims, readback and no replay."""
from copy import deepcopy
import hashlib
import threading
import unittest
from unittest.mock import patch

from annotation_experiment_model import digest
from cb_fixture_style_color_trial import Intent, STEPS, execute, prepare
from secure_weread_session import StoreError
from test_cb_fixture_highlight_trial import fixture
from test_secure_native_session import Backend
from verify_cb_fixture_style_color_trial import ScopedNative
from verify_eink_login import NativeProbe


class Fake:
    def __init__(self, baseline, fail=None): self.value=deepcopy(baseline); self.fail=fail; self.sent=[]; self.valid=True
    def owned(self): return self.valid
    def read(self): return deepcopy(self.value)
    def send(self, index, body, _receipt):
        self.sent.append(index); operation,_ = STEPS[index]
        if operation == 'create':
            row={k:v for k,v in body.items() if k not in ('bookId','bookVersion')}
            row['bookmarkId']='fresh-'+str(index); self.value['marks']['updated'][row['bookmarkId']]=row
        elif operation == 'delete': del self.value['marks']['updated'][body['bookmarkIds'][0]]
        else: self.value['marks']['updated'][body['bookmarkId']].update(style=body['style'],colorStyle=body['colorStyle'])
        if index == self.fail: raise RuntimeError('unknown dispatch outcome')


def case(fail=None):
    sample,baseline,_,_=fixture();plan,body=prepare('900000',sample['book_id'],'a'*32,sample,1,baseline)
    return plan,body,baseline,Intent(Backend()),Fake(baseline,fail)


class MatrixTests(unittest.TestCase):
    def test_full_matrix_and_transitions(self):
        plan,body,baseline,intent,fake=case(); result=execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send)
        self.assertEqual(result['writes'],72);self.assertEqual(fake.sent,list(range(72)))
        self.assertEqual({choice for op,choice in STEPS if op=='create'}, {(s,c) for s in (0,2) for c in range(6)})
        for style in (0,2): self.assertEqual({choice[1] for op,choice in STEPS if op=='color' and choice[0]==style},set(range(6)))
        transitions=set();current=None
        for operation,choice in STEPS:
            if operation=='create':current=choice
            elif operation=='delete':current=None
            else:
                if operation=='style':transitions.add((current[0],choice[0],choice[1]))
                current=choice
        self.assertEqual(transitions,{(a,b,c) for a in range(3) for b in range(3) if a!=b for c in range(6)})
        self.assertEqual(intent.read(),(None,None));self.assertEqual(fake.value,baseline)

    def test_each_uncertain_dispatch_remains_claimed_and_never_replays(self):
        for index in range(len(STEPS)):
            with self.subTest(index=index):
                plan,body,baseline,intent,fake=case(index)
                with self.assertRaises(RuntimeError):execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send)
                state,_=intent.read();self.assertEqual((state['step'],state['phase']),(index,'claimed'));sent=list(fake.sent)
                with self.assertRaises((ValueError,StoreError)):execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send)
                self.assertEqual(fake.sent,sent)

    def test_unrelated_change_stops(self):
        plan,body,baseline,intent,fake=case();send=fake.send
        def changed(index,value,receipt): send(index,value,receipt);fake.value['thoughts']['other']={}
        with self.assertRaises(ValueError):execute(plan,body,baseline,intent,fake.owned,fake.read,changed)
        self.assertEqual(fake.sent,[0]);self.assertEqual(intent.read()[0]['phase'],'claimed')

    def test_transport_rejects_tampering_and_replay(self):
        plan,body,_baseline,intent,fake=case();grant={'vid':'900000','accessToken':'synthetic'}
        native=ScopedNative(body['bookId'],grant,fake.owned,intent);native.body=body
        first=dict(body,style=0);receipt=intent.claim(intent.reserve(plan),digest(first))
        with patch.object(NativeProbe,'request',return_value={'succ':1}) as request:
            with self.assertRaises(ValueError):native.send(0,dict(first,bookId='CB_Other'),receipt,grant)
            native.send(0,first,receipt,grant)
            with self.assertRaises(ValueError):native.send(0,first,receipt,grant)
            self.assertEqual(request.call_count,1)

    def test_real_scoped_loopback_transport_and_get_budget(self):
        from mock_weread import CB_READING_ID,CHAPTERS
        from selection_trial_mock import Opener,credentials
        from test_cb_fixture_highlight_native_runtime import Server
        from urllib.parse import urlencode,urlsplit
        from urllib.request import Request
        class MatrixOpener(Opener):
            def open(self,request,timeout):
                if (request.get_header('Vid')!='900000' or request.get_header('Accesstoken')!='mock-native-access'
                        or urlsplit(request.full_url).hostname!='i.weread.qq.com' or request.get_method() not in ('GET','POST')):
                    raise ValueError('synthetic scope')
                if request.data is not None and urlsplit(request.full_url).path not in ('/book/addBookmark','/book/updateBookmark','/book/removeBookmark'):
                    raise ValueError('synthetic scope')
                url='http://127.0.0.1:'+str(self.server.server_port)+'/__proxy?'+urlencode(dict(url=request.full_url))
                return self.opener.open(Request(url,data=request.data,headers=dict(request.header_items()),method=request.get_method()),timeout=timeout)
        server=Server('normal');server.max_highlight_posts=len(STEPS)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            grant=credentials();intent=Intent(Backend());native=ScopedNative(CB_READING_ID,grant,lambda:True,intent,opener=MatrixOpener(server))
            baseline=native.observe(grant);version=native.version(grant);raw=server.chapter_source(2)
            sample=dict(book_id=CB_READING_ID,chapter_uid='2',chapters=CHAPTERS,source_format='web_xhtml',source=raw,
                        source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
            plan,body=prepare('900000',CB_READING_ID,'a'*32,sample,version,baseline);native.body=body
            result=execute(plan,body,baseline,intent,lambda:True,lambda:native.observe(grant),lambda index,value,receipt:native.send(index,value,receipt,grant))
            self.assertEqual(result['writes'],72);self.assertEqual(server.highlight_posts,72)
            self.assertEqual(native.observe(grant),baseline);self.assertGreater(native.gets,200);self.assertLessEqual(native.gets,640)
            self.assertEqual(intent.read(),(None,None))
        finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':unittest.main()
