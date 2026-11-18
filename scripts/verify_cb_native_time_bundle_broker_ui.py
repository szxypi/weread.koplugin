#!/usr/bin/env python3
"""Synthetic KOReader UI through host broker and isolated archive relay."""
import argparse,json,sys,tempfile,time
from copy import deepcopy
from pathlib import Path

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_broker import execute
from cb_native_time_bundle_evidence import PreflightEvidence
from cb_native_time_bundle_gate import DispatchGate,day
from cb_native_time_bundle_preflight import Prepared
from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from shelf_flag_change_contract import state_hash
from test_cb_native_time_bundle_evidence import fixture
from test_secure_native_session import Backend
from txt_full_summary import digest
from verify_cb_native_time_bundle_ui_rpc import seed
from verify_native_statistics import period


class Capture:
    def __init__(self,bundle):self.bundle=deepcopy(bundle);self.receipt=Receipt(b'synthetic-ui-capture')
    def read(self):return deepcopy(self.bundle),self.receipt


def scenario(runtime,source,candidate,seeded,armed,width,height,dpi):
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
    pairs=[[deepcopy(catalog[0]),deepcopy(catalog[0])],[deepcopy(catalog[0]),deepcopy(catalog[0])]]
    report=dict(result='CB_CROSS_DAY_READONLY_VERIFIED',seconds=plan['seconds'],observed_months=len(months),completed_at=now,
                exact_capture_and_source_bound=True,both_positions_counts_source_shelves_exact=True,two_statistics_reads_stable=True,
                server_clock_after_boundary=True,account_data_posts=0,authentication_posts=0,historical_accounting_verified=False,dispatch_capability=False)
    evidence=PreflightEvidence(bundle,grant,report,snapshot,months,pairs);capture=Capture(bundle)
    gate=DispatchGate(Backend(),clock=time.time,zone=lambda:'+08:00');audit=AuditStore(Backend(),clock=time.time)
    prepared=Prepared(bundle,capture.receipt,grant,evidence);signing=SigningInputs('synthetic-guest','synthetic-config')
    command=[sys.executable,str(source/'scripts/run_cb_native_time_bundle_synthetic_trial.py'),
             '--koreader',str(runtime),'--source',str(source),'--candidate',str(candidate),
             '--width',str(width),'--height',str(height),'--dpi',str(dpi)]
    result=execute(prepared,signing,{'wr_vid':'900000','wr_skey':'mock_key'},capture,gate,audit,lambda:True,command,armed=armed)
    expected='CB_NATIVE_ACKNOWLEDGED' if armed else 'CB_NATIVE_DRY_RUN_VERIFIED'
    if result['result']!=expected or result['dispatch_may_have_occurred'] is not armed or result['profile_removed'] is not True:
        raise ValueError('synthetic_cb_broker_ui/result '+str(result))
    state,_=gate.read()
    if (state['phase'] if state else None)!=('acknowledged' if armed else None):raise ValueError('synthetic_cb_broker_ui/state')
    if (audit.read()[0] is not None)!=armed:raise ValueError('synthetic_cb_broker_ui/audit')
    prepared.close()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('koreader','source','candidate'):parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);root=None
    try:
        if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
            raise ValueError('synthetic_cb_broker_ui/tmpfs')
        with tempfile.TemporaryDirectory(prefix='weread-cb-broker-ui-',dir='/dev/shm') as directory:
            root=Path(directory);bundle,_grant,_report,_snapshot,_months,_pairs=fixture()
            seeded=seed(args.koreader,args.source,root,bundle['plan'])
            for armed in (False,True):scenario(args.koreader,args.source,args.candidate,seeded,armed,args.width,args.height,args.dpi)
        result=dict(result='SYNTHETIC_CB_BROKER_UI_VERIFIED',scenarios=2,native_menu=True,background_service=True,
                    account_data_posts=0,authentication_posts=0,profile_removed=not root.exists())
    except Exception as error:
        result=dict(result='UNVERIFIED',synthetic_failure_type=type(error).__name__,profile_removed=root is not None and not root.exists())
        if isinstance(error,ValueError) and str(error).startswith('synthetic_cb_broker_ui/result '):
            result['failure_stage']='broker_result'
    print(json.dumps(result));return int(result['result']!='SYNTHETIC_CB_BROKER_UI_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
