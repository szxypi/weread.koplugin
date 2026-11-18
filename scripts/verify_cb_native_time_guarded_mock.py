#!/usr/bin/env python3
"""End-to-end native CB task against a synthetic loopback account only."""
import argparse,json,os,subprocess,sys,tempfile,threading,time
from contextlib import nullcontext
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs,urlsplit

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_bridge import Bridge
from cb_native_time_bundle_broker import execute
from cb_native_time_bundle_gate import DispatchGate,day
from cb_native_time_bundle_preflight import GuardedWeb,ReadOnlyNative,run as preflight
from cb_native_time_bundle_preparation import read_inputs
from cb_native_time_bundle_readback import NativeReads,run as readback
from mock_weread import CB_READING_ID
from native_time_bundle_preparation import SigningInputs,SigningRead
from native_time_capture_bundle import CaptureBundleStore
from selection_trial_mock import credentials
from secure_weread_session import StoreError
from test_cb_native_time_bundle_preflight_runtime import Server as BaseServer
from test_native_time_capture import capture
from test_secure_native_session import Backend
from test_uploaded_epub_native_reading_runtime import Opener
from txt_full_summary import digest
from verify_cb_native_time_capture import snapshot
from verify_native_statistics import period
from verify_cb_native_time_bundle_ui_rpc import seed
from verify_cb_native_time_guarded_dry import run as host_dry
from verify_cb_native_time_guarded_live import run as host_live


class Server(BaseServer):
    def __init__(self):super().__init__();self.applied=False;self.old_month=None;self.old_day=None;self.writes=0;self.fault=None
    def route(self,method,target,data):
        url=urlsplit(target)
        if url.hostname=='i.weread.qq.com' and url.path=='/config' and method=='GET':return 200,{'token':'synthetic-config'}
        if url.hostname=='i.weread.qq.com' and url.path=='/feature' and method=='GET':return 200,{'feature':{'guest_token':'synthetic-guest'}}
        if url.hostname=='i.weread.qq.com' and url.path=='/book/batchUploadProgress' and method=='POST':
            if self.writes:raise ValueError('synthetic_cb_guarded/replay')
            self.writes+=1;self.applied=True;return 200,{} if self.fault=='missing_ack' else {'succ':1}
        status,value=super().route(method,target,data)
        if self.applied and status==200 and url.path in ('/book/getProgress','/web/book/getProgress'):
            value['book']['readingTime']+=6
        if self.applied and status==200 and url.path=='/readdata/detail':
            if int(parse_qs(url.query)['baseTime'][0])==self.old_month:
                key=str(self.old_day);previous=value['readTimes'].get(key,0)
                value['readTimes'][key]=previous+6;value['totalReadTime']+=6
                if previous==0:value['readDays']+=1
        return status,value


def scenario(args,mode):
    armed=mode not in ('dry','host_dry','malicious_approval')
    raw=('<html><body>'+''.join('<p>Chapter %03d contains a unique synthetic passage through distant forests and rivers.</p>'%i
                                for i in range(30))+'</body></html>').encode()
    plan=capture('web_xhtml',CB_READING_ID,raw_override=raw);grant=credentials();plan['device_sha256']=digest(grant['deviceId'])
    with tempfile.TemporaryDirectory(prefix='weread-cb-guarded-seed-',dir='/dev/shm') as directory:
        proof=seed(args.koreader,args.source,Path(directory),plan)
    server=Server();server.progress[CB_READING_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=10,progress=1,summary='Synthetic full summary')
    server.chapter_source=lambda _uid,_revision=None:raw.decode();server.old_month=period('monthly',plan['start_time'])[0];server.old_day=day(plan['start_time'])
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    saved=dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'})
    class Session:
        def load(self):return deepcopy(saved)
    class NativeStore:
        def load(self,owner):assert owner=='900000';return deepcopy(grant)
    class Web(GuardedWeb):
        def __init__(self,current):super().__init__(current);self.opener=Opener(server)
    class Native(ReadOnlyNative):
        def __init__(self,provided,book,months,boundary,current,clock):
            super().__init__(provided,book,months,boundary,current,clock,opener=Opener(server))
    class AfterNative(NativeReads):
        def __init__(self,provided,book,months,dispatched,current,clock):
            super().__init__(provided,book,months,dispatched,current,clock,opener=Opener(server))
    class Signer(SigningRead):
        def __init__(self,provided,current):super().__init__(provided,current,opener=Opener(server))
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
            report,prepared=preflight(store,Session(),NativeStore(),gate,audit,clock=time.time,sleep=lambda _s:None,
                                      web_factory=Web,native_factory=Native)
        if report['result']!='CB_CROSS_DAY_READONLY_VERIFIED' or prepared is None:raise ValueError('synthetic_cb_guarded/preflight')
        server.fault='missing_ack' if mode=='host_live_missing_ack' else mode
        if mode=='source_changed':server.chapter_source=lambda _uid,_revision=None:(raw+b'changed').decode()
        if mode=='position_changed':server.progress[CB_READING_ID]['chapterOffset']+=1
        runner='run_cb_native_time_guarded_dry.py' if not armed else 'run_cb_native_time_guarded_live.py'
        command=[sys.executable,str(args.source/'scripts'/runner),
                 '--koreader',str(args.koreader),'--source',str(args.source),'--candidate',str(args.candidate),'--mock-port',str(server.server_port)]
        before_roots={item.name for item in Path('/dev/shm').glob('weread-cb-*')}
        original_popen=subprocess.Popen
        def visible(*pos,**kwargs):kwargs['stderr']=None;return original_popen(*pos,**kwargs)
        original_handle=Bridge.handle
        def malicious(bridge,event):
            return True if event.get('kind')=='claim' else original_handle(bridge,event)
        def change_archive_after_claim(bridge,event):
            allowed=original_handle(bridge,event)
            if event.get('kind')=='claim' and allowed:
                Path(bridge.source_path).write_bytes(b'synthetic replacement after claim')
            return allowed
        def interrupt_after_claim(bridge,event):
            allowed=original_handle(bridge,event)
            if event.get('kind')=='claim' and allowed:raise RuntimeError('synthetic interruption')
            return allowed
        overrides={'malicious_approval':malicious,'archive_changed_after_claim':change_archive_after_claim,
                   'broker_interrupted_after_claim':interrupt_after_claim}
        with patch('cb_native_time_bundle_broker.subprocess.Popen',side_effect=visible) if os.getenv('WEREAD_CB_SYNTHETIC_DEBUG')=='1' else nullcontext(),\
             patch.object(Bridge,'handle',new=overrides[mode]) if mode in overrides else nullcontext():
            if mode in ('host_dry','host_live_success','host_live_missing_ack'):
                def observed(*items):
                    with patch('cb_native_time_bundle_preflight.save_refreshed_web_session',return_value=False):
                        return preflight(*items,clock=time.time,sleep=lambda _s:None,web_factory=Web,native_factory=Native)
                def signing(packet,s,g,a,current):return read_inputs(packet,s,g,a,current,probe_factory=Signer)
                if mode=='host_dry':
                    result=host_dry(store,Session(),NativeStore(),gate,audit,attest=lambda:command,preflight=observed,prepare=signing)
                else:
                    dry_command=command.copy()
                    dry_command[1]=str(args.source/'scripts'/'run_cb_native_time_guarded_dry.py')
                    def rehearsal(*items):
                        return host_dry(*items,attest=lambda:dry_command,preflight=observed,prepare=signing)
                    def independent(*items):
                        with patch('cb_native_time_bundle_readback.save_refreshed_web_session',return_value=False):
                            return readback(*items,clock=time.time,sleep=lambda _s:None,web_factory=Web,native_factory=AfterNative)
                    result=host_live(store,Session(),NativeStore(),gate,audit,attest=lambda:command,rehearsal=rehearsal,
                                     preflight=observed,prepare=signing,readback=independent)
            else:
                result=execute(prepared,SigningInputs('synthetic-guest','synthetic-config'),saved['cookies'],store,gate,audit,lambda:True,command,armed=armed)
        if {item.name for item in Path('/dev/shm').glob('weread-cb-*')}-before_roots:raise ValueError('synthetic_cb_guarded/cleanup')
        expected={'dry':'CB_NATIVE_DRY_RUN_VERIFIED','host_dry':'CB_NATIVE_DRY_RUN_VERIFIED','success':'CB_NATIVE_ACKNOWLEDGED',
                  'source_changed':'UNVERIFIED','position_changed':'UNVERIFIED','missing_ack':'UNVERIFIED',
                  'malicious_approval':'UNVERIFIED','archive_changed_after_claim':'UNVERIFIED',
                  'broker_interrupted_after_claim':'UNVERIFIED','host_live_success':'CB_NATIVE_TRANSFER_READBACK_MATCH',
                  'host_live_missing_ack':'UNVERIFIED'}[mode]
        writes=int(mode in ('success','missing_ack','host_live_success','host_live_missing_ack'))
        if result['result']!=expected or server.writes!=writes:
            stages=[method+' '+path for method,_host,path in server.seen[-20:]]
            raise ValueError('synthetic_cb_guarded/result '+json.dumps({'broker':result,'stages':stages,'writes':server.writes}))
        state,_=gate.read()
        phase={'dry':None,'host_dry':None,'success':'acknowledged','source_changed':None,'position_changed':None,
               'missing_ack':'claimed','malicious_approval':None,'archive_changed_after_claim':'claimed',
               'broker_interrupted_after_claim':'claimed','host_live_success':'acknowledged','host_live_missing_ack':'claimed'}[mode]
        if (state['phase'] if state else None)!=phase or result['dispatch_may_have_occurred'] is not (phase is not None):
            raise ValueError('synthetic_cb_guarded/gate')
        if state:
            try:gate.reserve(prepared.bundle,grant,original)
            except StoreError:pass
            else:raise ValueError('synthetic_cb_guarded/replay')
        if mode=='success':
            with patch('cb_native_time_bundle_readback.save_refreshed_web_session',return_value=False):
                checked=readback(Session(),NativeStore(),store,gate,audit,clock=time.time,sleep=lambda _s:None,
                                 web_factory=Web,native_factory=AfterNative)
            if checked['result']!='CB_READBACK_MATCH' or checked['independent_samples']!=3:
                raise ValueError('synthetic_cb_guarded/readback')
        prepared.close()
    finally:server.shutdown();thread.join();server.server_close()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('koreader','source','candidate'):parser.add_argument('--'+name,required=True,type=Path)
    args=parser.parse_args(argv)
    try:
        for mode in ('dry','host_dry','success','source_changed','position_changed','missing_ack','malicious_approval',
                     'archive_changed_after_claim','broker_interrupted_after_claim','host_live_success','host_live_missing_ack'):scenario(args,mode)
        report=dict(result='SYNTHETIC_CB_GUARDED_TASK_VERIFIED',scenarios=11,real_account_posts=0,
                    synthetic_posts=4,source_reads_guarded=True,independent_readbacks_per_success=3,no_automatic_replay=True,
                    dry_approval_override_blocked=True,archive_rechecked_after_claim=True,interrupted_claim_not_replayed=True,
                    full_host_rehearsal_dispatch_readback=True)
    except Exception as error:
        report=dict(result='UNVERIFIED',failure_type=type(error).__name__)
        if isinstance(error,ValueError) and str(error).startswith('synthetic_cb_guarded/result '):
            report['diagnostic']=json.loads(str(error).removeprefix('synthetic_cb_guarded/result '))
    print(json.dumps(report));return int(report['result']!='SYNTHETIC_CB_GUARDED_TASK_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
