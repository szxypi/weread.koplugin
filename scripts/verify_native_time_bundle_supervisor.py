#!/usr/bin/env python3
"""Offline synthetic native selection -> signed request -> durable one-shot."""
import argparse,json,subprocess,tempfile
from pathlib import Path

from native_time_bundle_gate import DispatchGate
from native_time_bundle_selection import expected
from native_time_bundle_supervisor import Supervisor
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import StoreError
from test_native_time_bundle_gate import FileBackend,fixture
from test_native_time_bundle_supervisor import observed


class Capture:
    def __init__(self,bundle):self.bundle=bundle;self.receipt=Receipt(b'synthetic-capture')
    def read(self):return self.bundle,self.receipt


def probe(command,payload):
    child=subprocess.run(command,input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
    if child.returncode or len(child.stdout)>65536:raise ValueError('supervisor_probe/native')
    result=json.loads(child.stdout)
    if not isinstance(result,dict) or result.get('result')!='PASS':raise ValueError('supervisor_probe/native')
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path);parser.add_argument('--source',type=Path)
    args=parser.parse_args(argv)
    if bool(args.koreader)!=bool(args.source):parser.error('both runtime and source required')
    report=dict(result='OFFLINE_ONLY',synthetic_only=True,account_data_posts=0,authentication_posts=0,
                historical_accounting_verified=False,profile_removed=False)
    root=None;stage='setup'
    try:
        if args.koreader:
            runtime=args.koreader.resolve();source=args.source.resolve()
            if (not (runtime/'luajit').is_file() or not (source/'spec/koreader/native_time_bundle_selection_probe.lua').is_file()
                    or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
                raise ValueError('supervisor_probe/environment')
            captured,grant,_body,now=fixture();plan=captured['plan'];wanted=expected(captured)
            stage='selection'
            selection=probe([str(runtime/'luajit'),str(source/'spec/koreader/native_time_bundle_selection_probe.lua'),str(source)],
                dict(owner=plan['owner'],book_id=plan['book_id'],rows=wanted['rows'],parts=wanted['parts'],now=now))['selection']
            rows=wanted['protocol_rows']
            stage='signature'
            request=probe([str(runtime/'luajit'),str(source/'spec/koreader/readtime_protocol_probe.lua'),str(source)],
                dict(credentials=grant,book_id=plan['book_id'],rows=rows,guest_token='synthetic-guest',config_token='synthetic-config',
                     now=now,random=123,envelope=dict(timestamp=now*1000,random=456,current_zone='+08:00')))['body']
            with tempfile.TemporaryDirectory(prefix='weread-native-gate-',dir='/dev/shm') as directory:
                root=Path(directory);path=root/'journal';lock=root/'journal.lock'
                task=DispatchGate(FileBackend(path),lambda:project_lock(lock),clock=lambda:now,zone=lambda:'+08:00')
                supervisor=Supervisor(task,Capture(captured),captured,grant,'synthetic-guest','synthetic-config',lambda:True,observed)
                stage='prepare';supervisor.prepare()
                stage='select';supervisor.select(selection)
                stage='claim';receipt=supervisor.claim(request,selection)
                if task.read()[0]['phase']!='claimed':raise ValueError('supervisor_probe/claim')
                stage='ack';supervisor.acknowledge({'succ':1})
                stage='reopen';reopened=DispatchGate(FileBackend(path),lambda:project_lock(lock),clock=lambda:now,zone=lambda:'+08:00')
                if reopened.read()[0]['phase']!='acknowledged':raise ValueError('supervisor_probe/reopen')
                try:reopened.claim(receipt,captured,grant,request,'synthetic-guest','synthetic-config')
                except StoreError:pass
                else:raise ValueError('supervisor_probe/replay')
                report.update(result='SYNTHETIC_NATIVE_SUPERVISOR_VERIFIED',native_selection_exact=True,native_signature_exact=True,
                              durable_claim_before_ack=True,reopened_no_replay=True)
    except Exception as error:
        report['result']='UNVERIFIED';report['synthetic_failure_stage']=stage;report['synthetic_failure_type']=type(error).__name__
    finally:report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
