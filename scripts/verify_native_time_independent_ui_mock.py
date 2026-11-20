#!/usr/bin/env python3
"""Exercise the dry-only native menu with KOReader and loopback HTTP."""
import argparse
from contextlib import nullcontext
from copy import deepcopy
import json,os,sys,tempfile,threading,time
from pathlib import Path
from unittest.mock import patch

from cloud_group_contract import project
from native_time_bundle_accounting import day
from native_time_bundle_bridge import NativeTimeBridge
from native_time_bundle_evidence import IndependentCaptureEvidence
from native_time_bundle_preparation import SigningInputs
from native_time_independent_audit import IndependentAudit
from native_time_independent_broker import Prepared,execute
from native_time_independent_gate import IndependentGate
from native_time_shelf_components import make
from shelf_flag_change_contract import state_hash
from test_native_time_bundle_accounting import example
from test_native_time_bundle_evidence import synthetic_pairs
from test_native_time_capture import capture
from test_secure_native_session import Backend
from txt_full_summary import digest
from verify_native_statistics import period
from verify_native_time_bundle_ui_rpc import seed_evidence
from verify_native_time_guarded_mock import Capture,Server


def scenario(args,mode):
    bundle,grant,before,_samples,_old_now=example();now=int(time.time())
    raw='<html><body>'+''.join('<p>Unique chapter passage %03d passes through forests and rivers.</p>'%i for i in range(30))+'</body></html>'
    plan=capture('web_xhtml',raw_override=raw.encode());plan['device_sha256']=digest(grant['deviceId']);bundle['plan']=plan
    with tempfile.TemporaryDirectory(prefix='weread-independent-seed-',dir='/dev/shm') as directory:
        bundle['evidence']=seed_evidence(args.koreader,args.source,Path(directory))
    old_month=period('monthly',plan['start_time'])[0];current_month=period('monthly',now)[0];old_day=day(plan['start_time'])
    months={str(old_month):dict(baseTime=old_month,readTimes={str(old_day):10,str(old_month):0},totalReadTime=10,readDays=1)}
    if current_month!=old_month:months[str(current_month)]=dict(baseTime=current_month,readTimes={},totalReadTime=0,readDays=0)
    server=Server(plan,raw,months);before['snapshot']['shelf']=state_hash(server.shelf)
    before['snapshot']['source']=plan['raw_sha256']
    before['snapshot']['catalog']=digest(dict(book_id=plan['book_id'],versions=[7,7],chapters=server.catalog['updated']))
    plan['baseline_sha256']=digest(before['snapshot'])
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    report=dict(result='CROSS_DAY_READONLY_VERIFIED',seconds=plan['seconds'],completed_at=now,
                captured_native_baseline_matches=True,both_current_shelves_stable=True,two_statistics_reads_stable=True,
                saved_capture_unchanged=True,observed_months=len(months),account_data_posts=0,authentication_posts=0,
                historical_accounting_verified=False,dispatch_capability=False,captured_web_shelf_comparable=False)
    shelf=project(server.shelf);shelf_hash=digest(shelf);components=make(shelf)
    evidence=IndependentCaptureEvidence(bundle,grant,report,before['snapshot'],months,synthetic_pairs(server.catalog),
                                        (shelf_hash,shelf_hash),components=(components,components))
    store=Capture(bundle);gate=IndependentGate(Backend(),capture=store,clock=time.time,zone=lambda:'+08:00')
    audit=IndependentAudit(Backend(),clock=time.time)
    prepared=Prepared(deepcopy(bundle),store.receipt,deepcopy(grant),evidence)
    server.fault=mode
    if mode=='source_changed':server.chapter_source=lambda _uid,_revision=None:raw+'changed'
    command=[sys.executable,str(args.source/'scripts/run_native_time_guarded_worker.py'),'--koreader',str(args.koreader),
             '--source',str(args.source),'--candidate',str(args.candidate),'--mock-port',str(server.server_port)]
    existing={item.name for item in Path('/dev/shm').glob('weread-native-time-*')}
    original=NativeTimeBridge.handle
    def change_archive(bridge,event):
        allowed=original(bridge,event)
        if event.get('kind')=='claim' and allowed:Path(bridge.source_path).write_bytes(b'synthetic replacement')
        return allowed
    def interrupt(bridge,event):
        allowed=original(bridge,event)
        if event.get('kind')=='claim' and allowed:raise RuntimeError('synthetic interruption')
        return allowed
    def malicious(bridge,event):return True if event.get('kind')=='claim' else original(bridge,event)
    override={'archive_changed':change_archive,'interrupted':interrupt,'malicious_approval':malicious}.get(mode)
    try:
        with patch.object(NativeTimeBridge,'handle',new=override) if override else nullcontext():
            result=execute(prepared,SigningInputs('synthetic-guest','synthetic-config'),{'wr_vid':'900000','wr_skey':'mock_key'},
                           store,gate,audit,lambda:True,command,armed=mode not in ('dry','malicious_approval'))
        if {item.name for item in Path('/dev/shm').glob('weread-native-time-*')}-existing:raise ValueError('independent_mock/cleanup')
        expected={'dry':('INDEPENDENT_NATIVE_DRY_RUN_VERIFIED',None,0),
                  'malicious_approval':('UNVERIFIED',None,0),'success':('INDEPENDENT_NATIVE_ACKNOWLEDGED','acknowledged',1),
                  'source_changed':('UNVERIFIED',None,0),'position_changed':('UNVERIFIED',None,0),
                  'missing_ack':('UNVERIFIED','claimed',1),'archive_changed':('UNVERIFIED','claimed',0),
                  'interrupted':('UNVERIFIED','claimed',0)}[mode]
        state,_=gate.read();phase=state['phase'] if state else None
        if (result['result'],phase,server.writes)!=expected:
            raise ValueError('independent_mock/result '+json.dumps({'mode':mode,'broker':result,'phase':phase,'writes':server.writes}))
        if result['dispatch_may_have_occurred'] is not (phase is not None):raise ValueError('independent_mock/gate')
        if (audit.read()[0] is not None)!=(phase is not None):raise ValueError('independent_mock/audit')
    finally:
        server.shutdown();thread.join();server.server_close();prepared.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('koreader','source','candidate'):parser.add_argument('--'+name,required=True,type=Path)
    args=parser.parse_args()
    try:
        for mode in ('dry','malicious_approval'):
            scenario(args,mode)
        report=dict(result='SYNTHETIC_INDEPENDENT_NATIVE_UI_DRY_VERIFIED',scenarios=2,real_account_posts=0,synthetic_posts=0,
                    dry_override_blocked=True,native_menu=True,background_service=True,actual_ui_readback_verified=False)
    except Exception as error:
        if os.getenv('WEREAD_NATIVE_SYNTHETIC_DEBUG')=='1':
            import traceback;traceback.print_exc()
        report=dict(result='UNVERIFIED',failure_type=type(error).__name__)
        if isinstance(error,ValueError) and str(error).startswith('independent_mock/result '):
            report['diagnostic']=json.loads(str(error).removeprefix('independent_mock/result '))
    print(json.dumps(report));return int(report['result']!='SYNTHETIC_INDEPENDENT_NATIVE_UI_DRY_VERIFIED')


if __name__=='__main__':main()
