#!/usr/bin/env python3
"""Run the ordinary-book native task against a loopback synthetic account."""
import argparse,json,os,subprocess,sys,tempfile,threading,time
from contextlib import ExitStack,nullcontext
from copy import deepcopy
from pathlib import Path
from unittest.mock import Mock,patch
from urllib.parse import parse_qs,urlsplit

from mock_weread import MockServer
from native_time_bundle_bridge import NativeTimeBridge
from native_time_bundle_evidence import FreshShelfEvidence
from native_time_bundle_fresh_audit import FreshAuditStore
from native_time_bundle_fresh_broker import Prepared,execute
from native_time_bundle_gate import DispatchGate,day
from native_time_shelf_components import make as component_fingerprints
from native_time_bundle_preparation import SigningInputs,SigningRead
from native_time_bundle_audit_store import AuditStore as LegacyAuditStore
from native_time_bundle_readback import NativeReads,StatisticsReads,ShelfRead,run as readback
from secure_highlight_trial import Receipt
from selection_trial_mock import credentials
from shelf_flag_change_contract import state_hash
from test_native_time_bundle_accounting import example
from test_native_time_bundle_evidence import synthetic_catalog,synthetic_pairs,synthetic_scope,synthetic_trial
from test_cloud_group_nonempty_contract import TARGET
from test_native_time_bundle_supervisor import observed
from test_secure_native_session import Backend
from test_native_time_capture import capture
from txt_full_summary import digest
from cloud_group_contract import project
from test_uploaded_epub_native_reading_runtime import Opener
from verify_native_time_capture import XhtmlSource
from verify_native_statistics import period
from verify_native_time_bundle_ui_rpc import seed_evidence
from verify_native_time_fresh_dry import run as host_dry
from verify_native_time_fresh_live import run as host_live


class Capture:
    def __init__(self,bundle):self.bundle=deepcopy(bundle);self.receipt=Receipt(b'synthetic-capture')
    def read(self):return deepcopy(self.bundle),self.receipt


class Server(MockServer):
    def __init__(self,plan,raw,months):
        super().__init__(0);self.plan=plan;self.chapter_source=lambda _uid,_revision=None:raw
        self.months=deepcopy(months);self.applied=False;self.writes=0;self.fault=None;self.seen=[]
        self.shelf={'books':[{'bookId':plan['book_id'],'title':'Synthetic book','secret':0,'finishReading':0},
                             {'bookId':TARGET,'title':'Synthetic fixture','secret':0,'finishReading':0}],
                    'archive':[{'archiveId':2,'name':'合成分组','bookIds':[plan['book_id']],'updateTime':1}]}
        self.catalog=synthetic_catalog(plan)

    def route(self,method,target,data):
        url=urlsplit(target);self.seen.append((method,url.hostname,url.path))
        if url.hostname=='i.weread.qq.com':
            if url.path=='/book/getProgress' and method=='GET':
                point=dict(bookId=self.plan['book_id'],chapterUid=2,chapterIdx=2,chapterOffset=12,progress=3,
                           readingTime=20+(6 if self.applied else 0),recordReadingTime=0,ttsTime=0)
                if self.fault=='position_changed':point['chapterOffset']+=1
                return 200,dict(timestamp=int(time.time()),book=point)
            if url.path=='/book/info' and method=='GET':return 200,dict(bookId=self.plan['book_id'],bookVersion=7)
            if url.path=='/shelf/sync' and method=='GET':
                value=deepcopy(self.shelf)
                if self.applied and self.fault=='shelf_metadata_changed':value['archive'][0]['updateTime']=2
                return 200,value
            if url.path=='/readdata/detail' and method=='GET':
                month=parse_qs(url.query)['baseTime'][0];value=deepcopy(self.months[month])
                if self.applied and int(month)==period('monthly',self.plan['start_time'])[0]:
                    key=str(day(self.plan['start_time']));old=value['readTimes'].get(key,0)
                    value['readTimes'][key]=old+6;value['totalReadTime']+=6
                    if old==0:value['readDays']+=1
                return 200,value
            if url.path=='/config' and method=='GET':return 200,{'token':'synthetic-config'}
            if url.path=='/feature' and method=='GET':return 200,{'feature':{'guest_token':'synthetic-guest'}}
            if url.path=='/book/batchUploadProgress' and method=='POST':
                if self.writes:raise ValueError('synthetic_native/replay')
                self.writes+=1;self.applied=True;return 200,{} if self.fault=='missing_ack' else {'succ':1}
        if url.hostname=='weread.qq.com':
            if url.path=='/web/shelf/sync' and method=='GET':return 200,deepcopy(self.shelf)
            if url.path=='/web/book/getProgress' and method=='GET':
                point=dict(bookId=self.plan['book_id'],chapterUid=2,chapterIdx=2,chapterOffset=12,progress=3,
                           readingTime=20+(6 if self.applied else 0),recordReadingTime=0,ttsTime=0)
                if self.fault=='position_changed':point['chapterOffset']+=1
                return 200,dict(book=point)
            if url.path=='/web/book/chapterInfos' and method=='POST':return 200,{'data':[deepcopy(self.catalog)]}
        return super().route(method,target,data)


def scenario(args,mode):
    bundle,grant,before,_samples,_old_now=example();now=int(time.time())
    raw=('<html><body>'+''.join('<p>Unique chapter passage %03d passes through forests and rivers.</p>'%i
                                for i in range(30))+'</body></html>')
    p=capture('web_xhtml',raw_override=raw.encode());p['device_sha256']=digest(grant['deviceId']);bundle['plan']=p
    with tempfile.TemporaryDirectory(prefix='weread-native-fresh-seed-',dir='/dev/shm') as directory:
        bundle['evidence']=seed_evidence(args.koreader,args.source,Path(directory))
    old_month=period('monthly',p['start_time'])[0];current_month=period('monthly',now)[0];old_day=day(p['start_time'])
    months={str(old_month):dict(baseTime=old_month,readTimes={str(old_day):10,str(old_month):0},totalReadTime=10,readDays=1)}
    if current_month!=old_month:months[str(current_month)]=dict(baseTime=current_month,readTimes={},totalReadTime=0,readDays=0)
    server=Server(p,raw,months);before['snapshot']['shelf']=state_hash(server.shelf)
    before['snapshot']['source']=p['raw_sha256']
    before['snapshot']['catalog']=digest(dict(book_id=p['book_id'],versions=[7,7],chapters=server.catalog['updated']))
    p['baseline_sha256']=digest(before['snapshot']);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    report=observed(completed_at=now);report['observed_months']=len(months)
    report.pop('both_positions_source_counts_and_original_shelf_exact')
    report.update(result='CAPTURE_FRESH_SHELF_READONLY_VERIFIED',captured_native_shelf_positions_source_counts_exact=True,
                  fresh_native_and_web_shelf_stable=True,previous_native_group_baseline_matches=False,previous_web_group_baseline_matches=False)
    shelf_digest=digest(project(server.shelf))
    evidence=FreshShelfEvidence(bundle,grant,report,before['snapshot'],months,synthetic_pairs(server.catalog),
                                (shelf_digest,shelf_digest),synthetic_scope(bundle),
                                components=(component_fingerprints(project(server.shelf)),component_fingerprints(project(server.shelf))))
    store=Capture(bundle);gate=DispatchGate(Backend(),clock=time.time,zone=lambda:'+08:00');audit=FreshAuditStore(Backend(),clock=time.time)
    prepared=Prepared(bundle,store.receipt,grant,evidence);armed=mode not in ('dry','host_dry','malicious_approval')
    server.fault=('missing_ack' if mode=='host_live_missing_ack' else
                  'shelf_metadata_changed' if mode=='host_live_shelf_changed' else mode)
    if mode=='source_changed':server.chapter_source=lambda _uid,_revision=None:raw+'changed'
    command=[sys.executable,str(args.source/'scripts/run_native_time_guarded_worker.py'),'--koreader',str(args.koreader),
             '--source',str(args.source),'--candidate',str(args.candidate),'--mock-port',str(server.server_port)]
    existing={item.name for item in Path('/dev/shm').glob('weread-native-time-*')}
    original_handle=NativeTimeBridge.handle
    def change_archive(bridge,event):
        allowed=original_handle(bridge,event)
        if event.get('kind')=='claim' and allowed:Path(bridge.source_path).write_bytes(b'synthetic replacement')
        return allowed
    def interrupt(bridge,event):
        allowed=original_handle(bridge,event)
        if event.get('kind')=='claim' and allowed:raise RuntimeError('synthetic interruption')
        return allowed
    def malicious(bridge,event):
        return True if event.get('kind')=='claim' else original_handle(bridge,event)
    override={'archive_changed':change_archive,'interrupted':interrupt,'malicious_approval':malicious}.get(mode)
    original_popen=subprocess.Popen
    def visible(*pos,**kwargs):kwargs['stderr']=None;return original_popen(*pos,**kwargs)
    class Web(XhtmlSource):
        def __init__(self):super().__init__();self.opener=Opener(server)
        def select_shelf_book(self):
            value=self.request('shelf','https://weread.qq.com/web/shelf/sync')
            self.book_id=p['book_id'];self.report['shelf_book_count']=len(value['books']);return self.book_id
    def synthetic_readback(**kwargs):
        import native_time_bundle_readback as readback_module
        upload,upload_raw,group,group_raw,old,old_raw=synthetic_trial(bundle)
        groups,olds=Mock(),Mock();groups.read.return_value=(group,group_raw);olds.read.return_value=(old,old_raw)
        group_result=dict(phase='create_claimed',dispatched=True,native_fixture_present=True,web_fixture_present=True,
                          native_group_present=False,web_group_present=False)
        old_result=dict(native_original_state_unchanged=False,web_original_state_unchanged=False,old_group_absent=True)
        with ExitStack() as stack:
            for name,value in [('UploadJournal',Mock()),('GroupJournal',groups),('OldJournal',olds),
                               ('TargetReceipt',Mock()),('Guard',Mock()),('Binding',Mock()),('NonemptyBinding',Mock())]:
                stack.enter_context(patch.object(readback_module,name,return_value=value))
            stack.enter_context(patch.object(readback_module,'binding',return_value=(upload,upload_raw)))
            stack.enter_context(patch.object(readback_module,'inspect',return_value=group_result))
            stack.enter_context(patch.object(readback_module,'inspect_original',return_value=old_result))
            return readback(**kwargs,clock=time.time,sleep=lambda _:None,
                native_factory=lambda grant,plan,fixture,current,clock:NativeReads(grant,plan,fixture,current,clock,opener=Opener(server)),
                statistics_factory=lambda grant,months,current:StatisticsReads(grant,months,current,Opener(server)),
                shelf_factory=lambda grant,current:ShelfRead(grant,current,Opener(server)))
    try:
        with patch.object(NativeTimeBridge,'handle',new=override) if override else nullcontext(),\
                patch('native_time_bundle_fresh_broker.subprocess.Popen',side_effect=visible) if os.getenv('WEREAD_NATIVE_SYNTHETIC_DEBUG')=='1' else nullcontext():
            if mode in ('host_dry','host_live_success','host_live_missing_ack','host_live_shelf_changed'):
                saved={'vid':'900000','cookies':{'wr_vid':'900000','wr_skey':'mock_key'}}
                session=Mock();session.load.side_effect=lambda:deepcopy(saved)
                native=Mock();native.load.side_effect=lambda _owner:deepcopy(grant)
                legacy=LegacyAuditStore(Backend(),clock=time.time)
                def rehearsal(*items):
                    return host_dry(*items,attest=lambda:command,preflight=lambda *_args,**_kwargs:evidence,web_factory=Web,
                        signer=lambda grant,current:SigningRead(grant,current,opener=Opener(server)),
                        trial_factory=lambda bundle,_current:lambda:synthetic_scope(bundle),save_web=lambda *_:False)
                if mode=='host_dry':result=rehearsal(store,session,native,gate,audit,legacy)
                else:
                    result=host_live(store,session,native,gate,audit,legacy,attest=lambda:command,rehearsal=rehearsal,
                        preflight=lambda *_args,**_kwargs:evidence,web_factory=Web,
                        signer=lambda grant,current:SigningRead(grant,current,opener=Opener(server)),
                        trial_factory=lambda bundle,_current:lambda:synthetic_scope(bundle),save_web=lambda *_:False,
                        readback=synthetic_readback)
            else:
                result=execute(prepared,SigningInputs('synthetic-guest','synthetic-config'),{'wr_vid':'900000','wr_skey':'mock_key'},
                               store,gate,audit,lambda:True,lambda:synthetic_scope(bundle),command,armed=armed)
        if {item.name for item in Path('/dev/shm').glob('weread-native-time-*')}-existing:raise ValueError('synthetic_native/cleanup')
        expected={'dry':('NATIVE_FRESH_DRY_RUN_VERIFIED',None,0),'host_dry':('NATIVE_FRESH_DRY_RUN_VERIFIED',None,0),
                  'host_live_success':('NATIVE_FRESH_TRANSFER_READBACK_MATCH','acknowledged',1),
                  'host_live_missing_ack':('UNVERIFIED','claimed',1),
                  'host_live_shelf_changed':('NATIVE_FRESH_ACKNOWLEDGED_READBACK_UNVERIFIED','acknowledged',1),
                  'malicious_approval':('UNVERIFIED',None,0),'success':('NATIVE_FRESH_ACKNOWLEDGED','acknowledged',1),
                  'source_changed':('UNVERIFIED',None,0),'position_changed':('UNVERIFIED',None,0),
                  'missing_ack':('UNVERIFIED','claimed',1),'archive_changed':('UNVERIFIED','claimed',0),
                  'interrupted':('UNVERIFIED','claimed',0)}[mode]
        state,_=gate.read();phase=state['phase'] if state else None
        if (result['result'],phase,server.writes)!=expected:
            raise ValueError('synthetic_native/result '+json.dumps({'mode':mode,'broker':result,'phase':phase,
                                  'writes':server.writes,'routes':[m+' '+p for m,_h,p in server.seen[-20:]]}))
        if result['dispatch_may_have_occurred'] is not (phase is not None):raise ValueError('synthetic_native/gate')
        if mode=='host_live_success' and (result.get('independent_readback') is not True
                or result.get('historical_date_matched') is not True or result.get('real_accounting_verified') is not False):
            raise ValueError('synthetic_native/host_readback')
        if mode=='host_live_shelf_changed' and (result.get('accounting_and_core_state_observed') is not True
                or result.get('full_shelf_exact') is not False or result.get('real_accounting_verified') is not False
                or result.get('component_diagnosis_available') is not True
                or result.get('native_shelf_change',{}).get('group_fields_changed')!=['updateTime']
                or result.get('web_shelf_change',{}).get('group_fields_changed')!=[]):
            raise ValueError('synthetic_native/partial_readback')
        if mode=='success':
            web=Web();web.vid='900000'
            for key,value in {'wr_vid':'900000','wr_skey':'mock_key'}.items():web.set_cookie(key,value)
            checked=synthetic_readback(saved={'vid':'900000'},grant=grant,store=store,gate=gate,audit=audit,current=lambda:True,web=web)
            web.shards.clear();web.close()
            if checked['result']!='READBACK_MATCH' or checked['independent_samples']!=3 or server.writes!=1:
                raise ValueError('synthetic_native/readback')
    finally:
        server.shutdown();thread.join();server.server_close();prepared.close()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('koreader','source','candidate'):parser.add_argument('--'+name,required=True,type=Path)
    args=parser.parse_args(argv)
    try:
        for mode in ('dry','host_dry','malicious_approval','success','source_changed','position_changed','missing_ack',
                     'archive_changed','interrupted','host_live_success','host_live_missing_ack','host_live_shelf_changed'):
            scenario(args,mode)
        report=dict(result='SYNTHETIC_NATIVE_GUARDED_TASK_VERIFIED',scenarios=12,real_account_posts=0,
                    synthetic_posts=5,independent_readbacks_on_success=3,host_dry_run=True,dry_override_blocked=True,
                    changed_shelf_records_partial_only=True,changed_group_field_identified_without_ids=True,
                    archive_rechecked=True,uncertain_claims_not_replayed=True,full_host_rehearsal_dispatch_readback=True)
    except Exception as error:
        if os.getenv('WEREAD_NATIVE_SYNTHETIC_DEBUG')=='1':
            import traceback;traceback.print_exc()
        report=dict(result='UNVERIFIED',failure_type=type(error).__name__)
        if isinstance(error,ValueError) and str(error).startswith('synthetic_native/result '):
            report['diagnostic']=json.loads(str(error).removeprefix('synthetic_native/result '))
    print(json.dumps(report));return int(report['result']!='SYNTHETIC_NATIVE_GUARDED_TASK_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
