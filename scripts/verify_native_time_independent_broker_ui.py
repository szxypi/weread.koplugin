#!/usr/bin/env python3
"""Run the independent broker through the synthetic native time menu."""
import argparse,json,sys,tempfile,time
from copy import deepcopy
from pathlib import Path

from native_time_bundle_accounting import day
from native_time_bundle_evidence import IndependentCaptureEvidence
from native_time_bundle_preparation import SigningInputs
from native_time_independent_audit import IndependentAudit
from native_time_independent_broker import Prepared,execute
from native_time_independent_gate import IndependentGate
from secure_highlight_trial import Receipt
from shelf_flag_change_contract import state_hash
from test_native_time_bundle_accounting import example
from test_native_time_bundle_evidence import synthetic_catalog,synthetic_pairs
from test_secure_native_session import Backend
from txt_full_summary import digest
from verify_native_statistics import period
from verify_native_time_bundle_ui_rpc import seed_evidence


class Capture:
    def __init__(self,bundle):self.bundle=deepcopy(bundle);self.receipt=Receipt(b'synthetic-ui-capture')
    def read(self):return deepcopy(self.bundle),self.receipt


def scenario(runtime,source,candidate,seeded,armed,width,height,dpi):
    bundle,grant,before,_samples,_old_now=example();plan=bundle['plan'];bundle['evidence']=deepcopy(seeded)
    now=int(time.time());old=period('monthly',plan['start_time'])[0];current=period('monthly',now)[0];old_day=day(plan['start_time'])
    months={str(old):dict(baseTime=old,readTimes={str(old_day):10,str(old):0},totalReadTime=10,readDays=1)}
    if current!=old:months[str(current)]=dict(baseTime=current,readTimes={},totalReadTime=0,readDays=0)
    before['snapshot']['shelf']=state_hash({'books':[{'bookId':plan['book_id'],'secret':0,'finishReading':0}],'archive':[]})
    plan['baseline_sha256']=digest(before['snapshot'])
    report=dict(result='CROSS_DAY_READONLY_VERIFIED',seconds=plan['seconds'],completed_at=now,
                captured_native_baseline_matches=True,both_current_shelves_stable=True,two_statistics_reads_stable=True,
                saved_capture_unchanged=True,observed_months=len(months),account_data_posts=0,authentication_posts=0,
                historical_accounting_verified=False,dispatch_capability=False,captured_web_shelf_comparable=False)
    evidence=IndependentCaptureEvidence(bundle,grant,report,before['snapshot'],months,synthetic_pairs(synthetic_catalog(plan)),('a'*64,'b'*64))
    capture=Capture(bundle);gate=IndependentGate(Backend(),capture=capture,clock=time.time,zone=lambda:'+08:00')
    audit=IndependentAudit(Backend(),clock=time.time)
    prepared=Prepared(deepcopy(bundle),capture.receipt,deepcopy(grant),evidence)
    command=[sys.executable,str(source/'scripts/run_native_time_independent_ui_synthetic.py'),
             '--koreader',str(runtime),'--source',str(source),'--candidate',str(candidate),
             '--width',str(width),'--height',str(height),'--dpi',str(dpi)]
    result=execute(prepared,SigningInputs('synthetic-guest','synthetic-config'),{'wr_vid':'900000','wr_skey':'mock_key'},
                   capture,gate,audit,lambda:True,command,armed=armed)
    expected='INDEPENDENT_NATIVE_ACKNOWLEDGED' if armed else 'INDEPENDENT_NATIVE_DRY_RUN_VERIFIED'
    if result['result']!=expected or result['dispatch_may_have_occurred'] is not armed or result['profile_removed'] is not True:
        raise ValueError('independent_broker_ui/result '+str(result))
    state,_=gate.read()
    if (state['phase'] if state else None)!=('acknowledged' if armed else None):raise ValueError('independent_broker_ui/state')
    if (audit.read()[0] is not None)!=armed:raise ValueError('independent_broker_ui/audit')
    prepared.close()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('koreader','source','candidate'):parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);root=None
    try:
        if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
            raise ValueError('independent_broker_ui/tmpfs')
        with tempfile.TemporaryDirectory(prefix='weread-independent-ui-',dir='/dev/shm') as directory:
            root=Path(directory);seeded=seed_evidence(args.koreader,args.source,root)
            for armed in (False,True):scenario(args.koreader,args.source,args.candidate,seeded,armed,args.width,args.height,args.dpi)
        result=dict(result='SYNTHETIC_INDEPENDENT_BROKER_UI_VERIFIED',scenarios=2,native_menu=True,background_service=True,
                    account_data_posts=0,authentication_posts=0,profile_removed=not root.exists())
    except Exception as error:
        result=dict(result='UNVERIFIED',synthetic_failure_type=type(error).__name__,profile_removed=root is not None and not root.exists())
        if isinstance(error,ValueError) and str(error).startswith('independent_broker_ui/result '):result['failure_stage']='broker_result'
    print(json.dumps(result));return int(result['result']!='SYNTHETIC_INDEPENDENT_BROKER_UI_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
