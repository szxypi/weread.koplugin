#!/usr/bin/env python3
"""Exercise independent CB readback against synthetic in-process responses."""
from contextlib import nullcontext
from copy import deepcopy
import json,time
from unittest.mock import patch
from urllib.parse import parse_qs,urlsplit

from cb_native_readtime_model import batch
from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_gate import DispatchGate,day
from cb_native_time_bundle_preflight import GuardedWeb,ReadOnlyNative,run as preflight
from cb_native_time_bundle_readback import NativeReads,run
from mock_weread import CB_READING_ID
from native_time_capture_bundle import CaptureBundleStore
from selection_trial_mock import credentials
from test_cb_native_time_bundle_preflight_runtime import Server as BaseServer
from test_native_time_capture import capture
from test_native_time_capture_evidence import bundle as evidence_bundle,make_fixture
from test_secure_native_session import Backend
from test_uploaded_epub_native_reading_runtime import Opener
from txt_full_summary import digest
from verify_cb_native_time_capture import snapshot
from verify_native_statistics import period


class Server(BaseServer):
    def __init__(self):super().__init__();self.applied=False;self.captured_day=None;self.old_month=None
    def route(self,method,target,data):
        url=urlsplit(target);status,value=super().route(method,target,data)
        if self.applied and status==200 and url.path in ('/book/getProgress','/web/book/getProgress'):
            value['book']['readingTime']+=6
        if self.applied and status==200 and url.path=='/readdata/detail':
            month=int(parse_qs(url.query)['baseTime'][0])
            if month==self.old_month:
                key=str(self.captured_day);value['readTimes'][key]=value['readTimes'].get(key,0)+6
                value['totalReadTime']+=6
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
    server.captured_day=day(plan['start_time']);server.old_month=period('monthly',plan['start_time'])[0]
    saved=dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'})
    class Session:
        def load(self):return deepcopy(saved)
    class NativeStore:
        def load(self,owner):assert owner=='900000';return deepcopy(grant)
    class Web(GuardedWeb):
        def __init__(self,current):super().__init__(current);self.opener=Opener(server)
    class BeforeNative(ReadOnlyNative):
        def __init__(self,credentials_,book,months,boundary,current,clock):
            super().__init__(credentials_,book,months,boundary,current,clock,opener=Opener(server))
    class AfterNative(NativeReads):
        def __init__(self,credentials_,book,months,dispatched,current,clock):
            super().__init__(credentials_,book,months,dispatched,current,clock,opener=Opener(server))
    try:
        months={period('monthly',plan['start_time'])[0],period('monthly',int(time.time()))[0]}
        web=Web(lambda:True);web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.allowed={plan['book_id']};web.request('shelf','https://weread.qq.com/web/shelf/sync')
        sample=web.inspect(plan['book_id']);web.verify_account()
        native=BeforeNative(grant,plan['book_id'],months,plan['not_before'],lambda:True,time.time)
        original=snapshot(web,sample,native,grant);plan['baseline_sha256']=digest(original);native.close();web.close()
        parts={};store=CaptureBundleStore(Backend(),chunks=lambda index:parts.setdefault(index,Backend()),lock=nullcontext,imported=True)
        store.capture(plan,proof);gate=DispatchGate(Backend(),clock=time.time,zone=lambda:'+08:00');audit=AuditStore(Backend(),clock=time.time)
        with patch('cb_native_time_bundle_preflight.save_refreshed_web_session',return_value=False):
            report,prepared=preflight(store,Session(),NativeStore(),gate,audit,clock=time.time,sleep=lambda _s:None,
                                      web_factory=Web,native_factory=BeforeNative)
        if report['result']!='CB_CROSS_DAY_READONLY_VERIFIED' or prepared is None:raise ValueError('synthetic_cb_readback/preflight')
        _report,before,statistics=prepared.evidence.for_bundle(prepared.bundle,prepared.grant)
        stamp=int(time.time());rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in plan['rows']]
        body=batch(grant,plan['book_id'],rows,'synthetic-guest','synthetic-config',stamp,123,stamp*1000,456,
                   current_zone='+08:00',summary=before['native']['summary']['value'])
        reserved=gate.reserve(prepared.bundle,grant,before);audit.seal(prepared.bundle,grant,gate,before,statistics,report['completed_at'])
        claimed=gate.claim(reserved,prepared.bundle,grant,before,body,'synthetic-guest','synthetic-config')
        gate.acknowledge(claimed,{'succ':1});server.applied=True
        with patch('cb_native_time_bundle_readback.save_refreshed_web_session',return_value=False):
            result=run(Session(),NativeStore(),store,gate,audit,clock=time.time,sleep=lambda _s:None,
                       web_factory=Web,native_factory=AfterNative)
        if result['result']!='CB_READBACK_MATCH' or result['independent_samples']!=3:raise ValueError('synthetic_cb_readback/result')
        if any(path in ('/web/book/read','/login','/book/batchUploadProgress') for _method,_host,path in server.seen):
            raise ValueError('synthetic_cb_readback/write')
        prepared.close()
        print(json.dumps(dict(result='SYNTHETIC_CB_READBACK_VERIFIED',independent_samples=3,
                              account_data_posts=0,authentication_posts=0)))
    finally:server.server_close()


if __name__=='__main__':main()
