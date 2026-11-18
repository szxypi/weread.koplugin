#!/usr/bin/env python3
"""Synthetic CB ReaderUI, background time sender and isolated parent RPC gate."""
import argparse,json,os,secrets,subprocess,tempfile,time
from copy import deepcopy
from pathlib import Path

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_bridge import Bridge
from cb_native_time_bundle_evidence import PreflightEvidence
from cb_native_time_bundle_gate import DispatchGate,day
from cb_native_time_bundle_remote_archive import Relay
from cb_native_time_bundle_supervisor import Supervisor
from native_time_bundle_workspace import restore
from native_time_capture_evidence import PROTOCOL,account_key,validate_evidence
from native_time_sqlite_snapshot import snapshot as sqlite_snapshot
from native_trial_pipe import Frames,reply,stop,write_initial
from process_loss_runtime import enable_subreaper,kill_reader_session
from run_persistent_ui_probe import extract_candidate
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import StoreError
from shelf_flag_change_contract import state_hash
from test_cb_native_time_bundle_evidence import fixture
from test_native_time_bundle_gate import FileBackend
from txt_full_summary import digest
from verify_native_statistics import period
from verify_native_time_bundle_ui_rpc import reap_session


class Capture:
    def __init__(self,bundle):self.bundle=deepcopy(bundle);self.receipt=Receipt(b'synthetic-capture')
    def read(self):return deepcopy(self.bundle),self.receipt


def seed(runtime,source,root,plan):
    folder=root/'seed';folder.mkdir(mode=0o700)
    command=[str(runtime/'luajit'),str(source/'spec/koreader/native_time_bundle_seed.lua'),str(source),str(folder),'cb']
    child=subprocess.run(command,input=json.dumps(plan,separators=(',',':')).encode(),stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL,cwd=runtime,env=dict(os.environ,LD_LIBRARY_PATH=str(runtime/'libs')),timeout=30)
    if child.returncode or child.stdout.count(b'\nWEREAD_SYNTHETIC_BUNDLE_SEED=PASS')!=1:raise ValueError('cb_ui/seed')
    ledger,lh=sqlite_snapshot(folder/('offline-time-'+account_key(plan['owner'])+'.db'),root/'seed-ledger.db')
    coverage,ch=sqlite_snapshot(folder/'reading-time-coverage.db',root/'seed-coverage.db')
    evidence=dict(protocol=PROTOCOL,ledger_base64=ledger,ledger_sha256=lh,coverage_base64=coverage,coverage_sha256=ch)
    validate_evidence(plan,evidence,imported=True);return evidence


def scenario(runtime,source,candidate,root,mode,width,height,dpi,seeded):
    bundle,grant,_report,snapshot,_months,_pairs=fixture();plan=bundle['plan'];bundle['evidence']=deepcopy(seeded)
    now=int(time.time());old=period('monthly',plan['start_time'])[0];current=period('monthly',now)[0];old_day=day(plan['start_time'])
    months={str(old):dict(baseTime=old,readTimes={str(old_day):10,str(old):0},totalReadTime=10,readDays=1)}
    if current!=old:months[str(current)]=dict(baseTime=current,readTimes={},totalReadTime=0,readDays=0)
    for channel in ('native','web'):
        snapshot[channel].update(chapter_offset=12,raw_percent=3,summary={'present':True,'value':'合成摘要😀'},
                                 chapterTitle={'present':True,'value':'合成章节'})
    snapshot['counts']=dict(readingTime=20,recordReadingTime=0,ttsTime=0)
    snapshot['native_shelf']=state_hash({'books':[{'bookId':plan['book_id'],'secret':0,'finishReading':0}],'archive':[]})
    plan['baseline_sha256']=digest(snapshot)
    catalog=[[dict(bookId=plan['book_id'],book=dict(bookVersion=plan['book_version']),
                   updated=[dict(chapterUid=plan['chapter_uid'],chapterIdx=plan['chapter_idx'])])]]
    # Each pair contains the exact two observations surrounding one source read.
    pairs=[[deepcopy(catalog[0]),deepcopy(catalog[0])],[deepcopy(catalog[0]),deepcopy(catalog[0])]]
    report=dict(result='CB_CROSS_DAY_READONLY_VERIFIED',seconds=plan['seconds'],observed_months=len(months),completed_at=now,
                exact_capture_and_source_bound=True,both_positions_counts_source_shelves_exact=True,two_statistics_reads_stable=True,
                server_clock_after_boundary=True,account_data_posts=0,authentication_posts=0,historical_accounting_verified=False,dispatch_capability=False)
    evidence=PreflightEvidence(bundle,grant,report,snapshot,months,pairs)
    folder=root/mode;folder.mkdir(mode=0o700);home=folder/'profile';plugins=home/'plugins';plugins.mkdir(parents=True)
    extract_candidate(candidate,plugins);html=folder/'synthetic.html'
    html.write_text('<html><body>'+'<p>Synthetic text for native UI.</p>'*120+'</body></html>')
    epub,ledger=restore(bundle,folder,imported=True)
    gate_path=folder/'gate';audit_path=folder/'audit'
    gate=DispatchGate(FileBackend(gate_path),lambda:project_lock(folder/'gate.lock'),clock=time.time,zone=lambda:'+08:00')
    audit=AuditStore(FileBackend(audit_path),lambda:project_lock(folder/'audit.lock'),clock=time.time)
    supervisor=Supervisor(gate,Capture(bundle),bundle,grant,'synthetic-guest','synthetic-config',lambda:True,
                          audit_store=audit,evidence=evidence);supervisor.prepare()
    bridge=Bridge(supervisor,epub,armed=mode!='dry_run',remote=True);relay=Relay(plan,folder,epub);token=secrets.token_hex(16)
    payload={key:value for key,value in plan.items() if key!='archive_base64'}
    payload.update(grant=grant,guest='synthetic-guest',config='synthetic-config',mode=mode,token=token,months=months)
    if (payload['owner']!='900000' or payload['book_id']!='CB_Synthetic' or grant['accessToken']!='mock-native-access'
            or grant['refreshToken']!='mock-native-refresh'):raise ValueError('cb_ui/input')
    env=dict(os.environ,KO_HOME=str(home),TZ='Asia/Shanghai',LD_LIBRARY_PATH=str(runtime/'libs'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
             EMULATE_READER_W=str(width),EMULATE_READER_H=str(height),EMULATE_READER_DPI=str(dpi))
    command=[str(runtime/'luajit'),str(source/'spec/koreader/cb_native_time_bundle_ui_rpc.lua'),str(source),str(html),str(ledger),str(epub)]
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True,cwd=runtime,env=env)
    pending=None;events=[];result=None
    try:
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=100)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':result=event;break
            pending=event;name=event.get('kind');allowed=False
            try:
                offered=relay.prepare(event) if name=='claim' else event
                allowed=bridge.handle(offered)
                if name=='claim' and allowed:relay.recheck()
            except (ValueError,StoreError):allowed=False
            events.append((name,allowed));reply(child.stdin,{'kind':name,'ok':allowed});pending=None
        status=child.wait(timeout=10)
        if status!=0 or not isinstance(result,dict) or result.get('result')!='PASS':
            raise ValueError('cb_ui/child_'+str(result.get('failed_module','unknown') if isinstance(result,dict) else 'unknown')+'_'+str(result.get('failed_line',0) if isinstance(result,dict) else 0))
    finally:
        if pending is not None:
            try:reply(child.stdin,{'kind':pending.get('kind'),'ok':False})
            except Exception:pass
        if child.poll() is None:
            try:kill_reader_session(child)
            except (ProcessLookupError,RuntimeError):pass
        stop(child);reap_session(child.pid)
    state,_=gate.read();phase=state['phase'] if state else 'none'
    expected_events={
        'success':[('selection',True),('claim',True),('ack',True)],
        'dry_run':[('selection',True),('claim',False)],
        'tamper_selection':[('selection',False)],
        'tamper_body':[('selection',True),('claim',False)],
        'tamper_native_point':[('selection',True),('claim',False)],
        'tamper_native_web':[('selection',True),('claim',False)],
        'tamper_native_rows':[('selection',True),('claim',False)],
        'tamper_native_counts':[('selection',True),('claim',False)],
        'tamper_native_months':[('selection',True),('claim',False)],
        'tamper_native_shelf':[('selection',True),('claim',False)],
        'tamper_native_source':[('selection',True),('claim',False)],
        'tamper_native_catalog':[('selection',True),('claim',False)],
        'lost_reply':[('selection',True),('claim',True)],
        'no_ack':[('selection',True),('claim',True),('ack',False)],
        'kill_worker':[('selection',True),('claim',True)],
        'no_delta':[('selection',True),('claim',True),('ack',True)],
        'duplicate':[('selection',True),('claim',True),('claim',False)],
        'invalid_ack':[('selection',True),('claim',True),('ack',False)],
        'http_201':[('selection',True),('claim',True),('ack',False)],
    }[mode]
    no_gate={'dry_run','tamper_selection','tamper_body','tamper_native_point','tamper_native_web','tamper_native_rows',
             'tamper_native_counts','tamper_native_months','tamper_native_shelf','tamper_native_source','tamper_native_catalog'}
    wanted='none' if mode in no_gate else 'acknowledged' if mode in ('success','no_delta') else 'claimed'
    local_phase='claimed' if mode in no_gate-{'tamper_selection'} else 'none' if mode in ('success','tamper_selection') else wanted
    if (events!=expected_events or phase!=wanted or result.get('mode')!=mode or result.get('local_phase')!=local_phase
            or result.get('native_menu') is not True or result.get('dialog_correct') is not True or result.get('workers_reaped') is not True
            or result.get('background_service') is not (mode!='tamper_selection')
            or result.get('recovery_checked') is not (mode=='no_delta')
            or type(result.get('source_reads')) is not int or result['source_reads']<(0 if mode=='tamper_selection' else 2 if mode in ('success','no_delta') else 1)
            or result.get('local_confirmed')!=(plan['seconds'] if mode=='success' else 0)):
        raise ValueError('cb_ui/result')
    stored,_=audit.read()
    if (stored is not None)!=(phase!='none'):raise ValueError('cb_ui/audit')
    if state:
        saved,_,checked,_=audit.inspect(bundle,grant,gate)
        if saved['snapshot']!=snapshot or saved['months']!=months or checked['phase']!=phase:raise ValueError('cb_ui/audit')
        reopened=DispatchGate(FileBackend(gate_path),lambda:project_lock(folder/'gate.lock'),clock=time.time,zone=lambda:'+08:00')
        if reopened.read()[0]['phase']!=phase:raise ValueError('cb_ui/reopen')
        try:reopened.reserve(bundle,grant,snapshot)
        except StoreError:pass
        else:raise ValueError('cb_ui/replay')
    return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path)
    parser.add_argument('--source',type=Path);parser.add_argument('--candidate',type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv)
    if any((args.koreader,args.source,args.candidate)) and not all((args.koreader,args.source,args.candidate)):parser.error('runtime, source and candidate required together')
    result={'result':'OFFLINE_ONLY','synthetic_only':True,'account_data_posts':0,'authentication_posts':0,'profile_removed':False};root=None;mode='setup'
    try:
        if args.koreader:
            runtime=args.koreader.resolve();source=args.source.resolve();candidate=args.candidate.resolve()
            if (not (runtime/'luajit').is_file() or not candidate.is_file() or not 1<=min(args.width,args.height,args.dpi)
                    or max(args.width,args.height,args.dpi)>4096 or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
                raise ValueError('cb_ui/environment')
            enable_subreaper()
            with tempfile.TemporaryDirectory(prefix='weread-cb-ui-rpc-',dir='/dev/shm') as directory:
                root=Path(directory);bundle,_,_,_,_,_=fixture();seeded=seed(runtime,source,root,bundle['plan'])
                modes=('success','dry_run','tamper_selection','tamper_body','tamper_native_point','tamper_native_web',
                       'tamper_native_rows','tamper_native_counts','tamper_native_months','tamper_native_shelf',
                       'tamper_native_source','tamper_native_catalog','lost_reply','no_ack','kill_worker','no_delta','duplicate','invalid_ack','http_201')
                for mode in modes:scenario(runtime,source,candidate,root,mode,args.width,args.height,args.dpi,seeded)
                result.update(result='SYNTHETIC_CB_NATIVE_UI_RPC_VERIFIED',scenarios=len(modes),native_menu=True,background_service=True,
                              original_summary_preserved=True,baseline_sealed_before_claim=True,unknown_not_replayed=True)
    except Exception as error:
        result.update(result='UNVERIFIED',synthetic_failure_mode=mode,synthetic_failure_type=type(error).__name__)
        if isinstance(error,ValueError) and str(error).startswith('cb_ui/child_'):
            module,_,line=str(error).removeprefix('cb_ui/child_').rpartition('_')
            if line.isdigit() and module and all(char.isalnum() or char in '_.-' for char in module):
                result['synthetic_failed_module']=module;result['synthetic_failed_line']=int(line)
    finally:result['profile_removed']=root is not None and not root.exists()
    print(json.dumps(result));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
