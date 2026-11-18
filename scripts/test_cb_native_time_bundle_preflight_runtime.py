#!/usr/bin/env python3
"""End-to-end CB read-only preflight against synthetic loopback responses."""
from contextlib import nullcontext
from copy import deepcopy
import json,time
from unittest.mock import patch
from urllib.parse import urlsplit

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_gate import DispatchGate
from cb_native_time_bundle_preflight import GuardedWeb,ReadOnlyNative,run
from mock_weread import CB_READING_ID
from native_time_capture_bundle import CaptureBundleStore
from selection_trial_mock import credentials
from test_native_time_capture import capture
from test_native_time_capture_evidence import bundle as evidence_bundle,make_fixture
from test_secure_native_session import Backend
from test_uploaded_epub_native_reading_runtime import Opener
from test_verify_cb_native_time_capture_runtime import Server as BaseServer
from txt_full_summary import digest
from verify_cb_native_time_capture import snapshot
from verify_native_statistics import period


class Server(BaseServer):
    def __init__(self):super().__init__(0);self.cb_reading=True;self.seen=[]
    def route(self,method,target,data):
        url=urlsplit(target);self.seen.append((method,url.hostname,url.path))
        status,value=super().route(method,target,data)
        if url.hostname=='i.weread.qq.com' and url.path=='/book/getProgress' and status==200:value['timestamp']=int(time.time())
        return status,value


def main():
    raw=('<html><body>'+''.join('<p>Chapter %03d contains a unique synthetic passage through distant forests and rivers.</p>'%i
                                for i in range(30))+'</body></html>').encode()
    plan=capture('web_xhtml',CB_READING_ID,raw_override=raw);grant=credentials();plan['device_sha256']=digest(grant['deviceId'])
    _old,ledger,coverage=make_fixture()
    ledger.execute('UPDATE windows SET book_id=?,file_id=?',(plan['book_id'],plan['file_id']));ledger.commit()
    proof=evidence_bundle(ledger,coverage);ledger.close();coverage.close()
    server=Server();server.progress[CB_READING_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=10,progress=1,summary='Synthetic full summary')
    server.chapter_source=lambda _uid,_revision=None:raw.decode()
    saved=dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'})
    class Session:
        def load(self):return deepcopy(saved)
    class NativeStore:
        def load(self,owner):assert owner=='900000';return deepcopy(grant)
    class Web(GuardedWeb):
        def __init__(self,current):super().__init__(current);self.opener=Opener(server)
    class Native(ReadOnlyNative):
        def __init__(self,credentials_,book,months,not_before,current,clock):
            super().__init__(credentials_,book,months,not_before,current,clock,opener=Opener(server))
    try:
        months={period('monthly',plan['start_time'])[0],period('monthly',int(time.time()))[0]}
        web=Web(lambda:True);web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.allowed={plan['book_id']};web.request('shelf','https://weread.qq.com/web/shelf/sync')
        sample=web.inspect(plan['book_id']);web.verify_account()
        native=Native(grant,plan['book_id'],months,plan['not_before'],lambda:True,time.time)
        original=snapshot(web,sample,native,grant);plan['baseline_sha256']=digest(original);native.close();web.close()
        parts={};store=CaptureBundleStore(Backend(),chunks=lambda index:parts.setdefault(index,Backend()),lock=nullcontext,imported=True)
        store.capture(plan,proof);gate=DispatchGate(Backend(),clock=time.time,zone=lambda:'+08:00');audit=AuditStore(Backend(),clock=time.time)
        with patch('cb_native_time_bundle_preflight.save_refreshed_web_session',return_value=False):
            report,prepared=run(store,Session(),NativeStore(),gate,audit,clock=time.time,sleep=lambda _seconds:None,
                                web_factory=Web,native_factory=Native)
        if report['result']!='CB_CROSS_DAY_READONLY_VERIFIED' or prepared is None:raise ValueError('synthetic_cb_preflight/result '+repr(report))
        assert prepared.evidence.for_bundle(prepared.bundle,prepared.grant)[1]==original
        assert gate.read()==audit.read()==(None,None) and report['account_data_posts']==report['authentication_posts']==0
        assert not any(path in ('/web/book/read','/login','/book/batchUploadProgress') for _method,_host,path in server.seen)
        prepared.close()
        print(json.dumps({'result':'SYNTHETIC_CB_PREFLIGHT_VERIFIED','account_data_posts':0,'authentication_posts':0,
                          'two_stable_snapshots':True,'two_stable_statistics':True,'gate_and_audit_unchanged':True}))
    finally:server.server_close()


if __name__=='__main__':main()
