#!/usr/bin/env python3
"""Synthetic ReaderUI time menu through an isolated RPC one-shot guard."""
import argparse,base64,json,os,secrets,signal,subprocess,tempfile,time
from pathlib import Path

from native_time_bundle_gate import DispatchGate
from native_time_bundle_audit_store import AuditStore
from native_time_bundle_evidence import PreflightEvidence
from native_time_bundle_supervisor import NativeBoundSupervisor
from native_trial_pipe import Frames,reply,stop,write_initial
from run_persistent_ui_probe import extract_candidate
from process_loss_runtime import enable_subreaper,kill_reader_session,session_members
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import StoreError
from test_native_time_bundle_accounting import example
from test_native_time_bundle_gate import FileBackend
from test_native_time_bundle_supervisor import observed
from test_native_time_bundle_evidence import synthetic_catalog,synthetic_pairs
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest as captured_digest
from verify_native_statistics import period


class Capture:
    def __init__(self,value):self.value=value;self.receipt=Receipt(b'synthetic-capture')
    def read(self):return self.value,self.receipt


def reap_session(session):
    deadline=time.monotonic()+5
    while True:
        members=session_members(session)
        if not members:return
        for pid in members:
            try:
                if os.getsid(pid)==session:os.kill(pid,signal.SIGKILL)
            except ProcessLookupError:pass
            try:os.waitpid(pid,os.WNOHANG)
            except ChildProcessError:pass
        if time.monotonic()>=deadline:raise ValueError('synthetic_ui/workers')
        time.sleep(.01)


def scenario(runtime,source,candidate,root,mode,width,height,dpi):
    captured,grant,before,_samples,_now=example();p=captured['plan']
    if (p['owner'],p['book_id'],grant['accessToken'],grant['refreshToken'])!=('900000','900001','mock-native-access','mock-native-refresh'):
        raise ValueError('synthetic_ui/input')
    folder=root/mode;folder.mkdir(mode=0o700);home=folder/'profile';plugins=home/'plugins';plugins.mkdir(parents=True)
    extract_candidate(candidate,plugins)
    html=folder/'synthetic.html';html.write_text('<html><body>'+'<p>Synthetic text for native UI.</p>'*120+'</body></html>')
    epub=folder/'source.epub';epub.write_bytes(base64.b64decode(p['archive_base64'],validate=True))
    ledger=folder/'ledger';ledger.mkdir(mode=0o700)
    journal=folder/'gate';lock=folder/'gate.lock'
    gate=DispatchGate(FileBackend(journal),lambda:project_lock(lock),clock=time.time,zone=lambda:'+08:00')
    month=period('monthly',int(time.time()))[0]
    old_month=str(period('monthly',p['start_time'])[0])
    before['months']={old_month:before['months'][old_month]}
    before['months'].setdefault(str(month),dict(baseTime=month,readTimes={},totalReadTime=0,readDays=0))
    if mode=='optional_text':
        for key in ('point','web_point'):
            before['snapshot'][key]['summary']={'present':True,'value':'合成摘要😀'}
            before['snapshot'][key]['chapterTitle']={'present':True,'value':'合成章节'}
    before['snapshot']['shelf']=state_hash({'books':[{'bookId':p['book_id'],'secret':0,'finishReading':0}],'archive':[]})
    p['baseline_sha256']=captured_digest(before['snapshot'])
    audit=AuditStore(FileBackend(folder/'audit'),lambda:project_lock(folder/'audit.lock'),clock=time.time)
    preflight=observed(completed_at=int(time.time()));preflight['observed_months']=len(before['months'])
    catalog=synthetic_catalog(p)
    evidence=PreflightEvidence(captured,grant,preflight,before['snapshot'],before['months'],synthetic_pairs(catalog))
    guard=NativeBoundSupervisor(gate,Capture(captured),captured,grant,'synthetic-guest','synthetic-config',lambda:True,
        audit_store=audit,evidence=evidence);guard.prepare()
    token=secrets.token_hex(16);payload={k:v for k,v in p.items() if k!='archive_base64'}
    payload.update(grant=grant,guest='synthetic-guest',config='synthetic-config',mode=mode,token=token,months=before['months'])
    env=dict(os.environ,KO_HOME=str(home),TZ='Asia/Shanghai',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
             EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi))
    command=[str(runtime/'luajit'),str(source/'spec/koreader/native_time_bundle_ui_rpc.lua'),str(source),str(html),str(ledger),str(epub)]
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True,cwd=runtime,env=env)
    pending=None;events=[];result=None
    try:
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=100)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':result=event;break
            pending=event;name=event.get('kind');allowed=False;reason=None
            try:
                if name=='selection' and set(event)=={'kind','selection'} and not events:
                    guard.select(event['selection']);allowed=True
                elif name=='claim' and set(event)=={'kind','body','selection','record'} and events and events[0]==('selection',True,None):
                    guard.claim(event['body'],event['selection'],event['record'],epub);allowed=True
                elif name=='ack' and set(event)=={'kind','response'} and events and events[-1]==('claim',True,None):
                    guard.acknowledge(event['response']);allowed=True
                else:raise ValueError('synthetic_ui/order')
            except (ValueError,StoreError) as error:reason=str(error)
            events.append((name,allowed,reason));reply(child.stdin,{'kind':name,'ok':allowed});pending=None
        status=child.wait(timeout=10)
        if status!=0 or not isinstance(result,dict) or result.get('result')!='PASS':
            raise ValueError('synthetic_ui/child_'+str(result.get('failed_module','unknown') if isinstance(result,dict) else 'unknown')+'_'+str(result.get('failed_line',0) if isinstance(result,dict) else 0))
    finally:
        if pending is not None:
            try:reply(child.stdin,{'kind':pending.get('kind'),'ok':False})
            except Exception:pass
        if child.poll() is None:
            try:kill_reader_session(child)
            except (ProcessLookupError,RuntimeError):pass
        stop(child)
        reap_session(child.pid)
    state,_=gate.read();phase=state['phase'] if state else 'none'
    audit_state,audit_receipt=audit.read()
    if (audit_state is not None)!=(phase!='none') or (audit_receipt is not None)!=(phase!='none'):
        raise ValueError('synthetic_ui/audit')
    if audit_state:
        saved,_,audit_gate,_=audit.inspect(captured,grant,gate)
        if saved['snapshot']!=before['snapshot'] or saved['months']!=before['months'] or audit_gate['phase']!=phase:
            raise ValueError('synthetic_ui/audit')
    expected_events={
        'success':[('selection',True,None),('claim',True,None),('ack',True,None)],
        'optional_text':[('selection',True,None),('claim',True,None),('ack',True,None)],
        'tamper_selection':[('selection',False,'bundle_selection/mismatch')],
        'tamper_body':[('selection',True,None),('claim',False,'native_record/baseline')],
        'tamper_native_point':[('selection',True,None),('claim',False,'native_record/baseline')],
        'tamper_native_web':[('selection',True,None),('claim',False,'native_record/baseline')],
        'tamper_native_rows':[('selection',True,None),('claim',False,'native_record/rows')],
        'tamper_native_counts':[('selection',True,None),('claim',False,'native_record/baseline')],
        'tamper_native_months':[('selection',True,None),('claim',False,'native_record/baseline')],
        'tamper_native_shelf':[('selection',True,None),('claim',False,'native_record/baseline')],
        'tamper_native_source':[('selection',True,None),('claim',False,'native_record/source')],
        'tamper_native_catalog':[('selection',True,None),('claim',False,'native_record/source')],
        'lost_reply':[('selection',True,None),('claim',True,None)],
        'no_ack':[('selection',True,None),('claim',True,None)],
        'kill_worker':[('selection',True,None),('claim',True,None)],
        'no_delta':[('selection',True,None),('claim',True,None),('ack',True,None)],
        'duplicate':[('selection',True,None),('claim',True,None),('claim',False,'bundle_supervisor/state')],
    }[mode]
    rejected=('tamper_body','tamper_native_point','tamper_native_web','tamper_native_rows','tamper_native_counts','tamper_native_months','tamper_native_shelf','tamper_native_source','tamper_native_catalog')
    expected_phase='none' if mode in rejected else {'success':'acknowledged','optional_text':'acknowledged','tamper_selection':'none','lost_reply':'claimed','duplicate':'claimed','no_ack':'claimed','kill_worker':'claimed','no_delta':'acknowledged'}[mode]
    expected_local='claimed' if mode in rejected else {'success':'none','optional_text':'none','tamper_selection':'none','lost_reply':'claimed','duplicate':'claimed','no_ack':'unknown','kill_worker':'claimed','no_delta':'acknowledged'}[mode]
    if (set(result)!={'result','mode','native_menu','background_service','dialog_correct','workers_reaped','recovery_checked','source_reads','local_phase','local_confirmed'}
            or events!=expected_events or phase!=expected_phase or result.get('mode')!=mode or result.get('local_phase')!=expected_local
            or result.get('native_menu') is not True or result.get('dialog_correct') is not True or result.get('workers_reaped') is not True
            or result.get('background_service') is not (mode!='tamper_selection')
            or result.get('recovery_checked') is not (mode=='no_delta')
            or type(result.get('source_reads')) is not int or result['source_reads']<(0 if mode=='tamper_selection' else 2 if mode in ('success','optional_text','no_delta') else 1)
            or result.get('local_confirmed')!=(p['seconds'] if mode in ('success','optional_text') else 0)):
        raise ValueError('synthetic_ui/result')
    if state:
        reopened=DispatchGate(FileBackend(journal),lambda:project_lock(lock),clock=time.time,zone=lambda:'+08:00')
        try:reopened.reserve(captured,grant)
        except StoreError as error:
            if str(error)!='bundle_gate/consumed':raise
        else:raise ValueError('synthetic_ui/replay')
    return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path);parser.add_argument('--source',type=Path);parser.add_argument('--candidate',type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv)
    if any((args.koreader,args.source,args.candidate)) and not all((args.koreader,args.source,args.candidate)):
        parser.error('runtime, source and candidate required together')
    report={'result':'OFFLINE_ONLY','synthetic_only':True,'account_data_posts':0,'authentication_posts':0,
            'historical_accounting_verified':False,'profile_removed':False};root=None;mode='setup'
    try:
        if args.koreader:
            runtime=args.koreader.resolve();source=args.source.resolve();candidate=args.candidate.resolve()
            if (not (runtime/'luajit').is_file() or not candidate.is_file() or not 1<=min(args.width,args.height,args.dpi)
                    or max(args.width,args.height,args.dpi)>4096 or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
                raise ValueError('synthetic_ui/environment')
            enable_subreaper()
            with tempfile.TemporaryDirectory(prefix='weread-native-ui-rpc-',dir='/dev/shm') as directory:
                root=Path(directory)
                for mode in ('success','optional_text','tamper_selection','tamper_body','tamper_native_point','tamper_native_web','tamper_native_rows','tamper_native_counts','tamper_native_months','tamper_native_shelf','tamper_native_source','tamper_native_catalog','lost_reply','no_ack','kill_worker','no_delta','duplicate'):
                    scenario(runtime,source,candidate,root,mode,args.width,args.height,args.dpi)
                report.update(result='SYNTHETIC_NATIVE_UI_RPC_VERIFIED',native_menu=True,background_service=True,correct_dialogs=True,workers_reaped=True,archive_verified=True,
                              durable_claim_before_reply=True,modified_selection_blocked=True,modified_body_blocked=True,
                              lost_and_duplicate_not_replayed=True,no_ack_and_worker_death_not_replayed=True,ack_readonly_recovery_not_replayed=True,
                              baseline_sealed_before_claim=True,preflight_evidence_bound=True,native_baseline_mismatch_blocked=True,catalog_stamp_mismatch_blocked=True,optional_text_parity=True,scenarios=17)
    except Exception as error:
        report.update(result='UNVERIFIED',synthetic_failure_mode=mode,synthetic_failure_type=type(error).__name__)
        if isinstance(error,ValueError) and str(error).startswith('synthetic_ui/child_'):
            suffix=str(error).removeprefix('synthetic_ui/child_')
            module,_,line=suffix.rpartition('_')
            if line.isdigit() and module and all(c.isalnum() or c in '_.-' for c in module):
                report['synthetic_failed_module']=module;report['synthetic_failed_line']=int(line)
    finally:report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
