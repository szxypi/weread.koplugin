#!/usr/bin/env python3
"""Synthetic native subprocess RPC and durable one-shot failure paths."""
import argparse,json,secrets,subprocess,tempfile
from pathlib import Path

from native_time_bundle_gate import DispatchGate
from native_time_bundle_selection import expected
from native_time_bundle_supervisor import Supervisor
from native_trial_pipe import Frames,reply,stop,write_initial
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import StoreError
from test_native_time_bundle_gate import FileBackend,fixture
from test_native_time_bundle_supervisor import observed


class Capture:
    def __init__(self,value):self.value=value;self.receipt=Receipt(b'synthetic-capture')
    def read(self):return self.value,self.receipt


def scenario(runtime,source,root,mode):
    capture,grant,_body,now=fixture();p=capture['plan'];selection=expected(capture)
    path=root/(mode+'.journal');lock=root/(mode+'.lock')
    gate=DispatchGate(FileBackend(path),lambda:project_lock(lock),clock=lambda:now,zone=lambda:'+08:00')
    guard=Supervisor(gate,Capture(capture),capture,grant,'synthetic-guest','synthetic-config',lambda:True,observed)
    guard.prepare();token=secrets.token_hex(16)
    payload={'owner':p['owner'],'book_id':p['book_id'],'grant':grant,'guest':'synthetic-guest','config':'synthetic-config',
             'mode':mode,'token':token,'rows':selection['rows'],'parts':selection['parts'],'now':now}
    if (payload['owner']!='900000' or payload['book_id']!='900001' or grant['accessToken']!='mock-native-access'
            or grant['refreshToken']!='mock-native-refresh'):raise ValueError('synthetic_rpc/input')
    command=[str(runtime/'luajit'),str(source/'spec/koreader/native_time_bundle_rpc_probe.lua'),str(source)]
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True,cwd=runtime)
    pending=None;done=False;selection_count=claims=acks=0;failure=None
    try:
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=30)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':
                if event!={'result':'PASS'} or mode!='success':raise ValueError('synthetic_rpc/result')
                done=True;break
            pending=event;name=event.get('kind')
            if name=='selection' and set(event)=={'kind','selection'} and not selection_count:
                guard.select(event['selection']);selection_count+=1
            elif name=='claim' and set(event)=={'kind','body','selection'}:
                guard.claim(event['body'],event['selection']);claims+=1
            elif name=='ack' and set(event)=={'kind','response'} and claims==1 and not acks:
                guard.acknowledge(event['response']);acks+=1
            else:raise ValueError('synthetic_rpc/order')
            reply(child.stdin,{'kind':name,'ok':True});pending=None
        if child.wait(timeout=10)!=0:raise ValueError('synthetic_rpc/child')
    except Exception as error:
        failure=(type(error).__name__,str(error))
        if pending is not None:
            try:reply(child.stdin,{'kind':pending.get('kind'),'ok':False})
            except Exception:pass
    finally:stop(child)
    state,_=gate.read();phase=state['phase'] if state else None
    expected_result={'success':(True,1,1,'acknowledged',None),
                     'tamper':(False,0,0,None,('ValueError','bundle_selection/mismatch')),
                     'body_tamper':(False,0,0,None,('ValueError','bundle_gate/request')),
                     'drop':(False,1,0,'claimed',('ValueError','trial_pipe/eof')),
                     'duplicate':(False,1,0,'claimed',('ValueError','bundle_supervisor/state'))}[mode]
    if (done,claims,acks,phase,failure)!=expected_result:raise ValueError('synthetic_rpc/verification')
    if phase is not None:
        reopened=DispatchGate(FileBackend(path),lambda:project_lock(lock),clock=lambda:now,zone=lambda:'+08:00')
        if reopened.read()[0]['phase']!=phase:raise ValueError('synthetic_rpc/reopen')
        try:reopened.reserve(capture,grant)
        except StoreError as error:
            if str(error)!='bundle_gate/consumed':raise
        else:raise ValueError('synthetic_rpc/replay')
    return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path);parser.add_argument('--source',type=Path)
    args=parser.parse_args(argv)
    if bool(args.koreader)!=bool(args.source):parser.error('both runtime and source required')
    report={'result':'OFFLINE_ONLY','synthetic_only':True,'account_data_posts':0,'authentication_posts':0,
            'historical_accounting_verified':False,'profile_removed':False}
    root=None;mode='setup'
    try:
        if args.koreader:
            runtime=args.koreader.resolve();source=args.source.resolve()
            if (not (runtime/'luajit').is_file() or not (source/'spec/koreader/native_time_bundle_rpc_probe.lua').is_file()
                    or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
                raise ValueError('synthetic_rpc/environment')
            with tempfile.TemporaryDirectory(prefix='weread-native-rpc-',dir='/dev/shm') as directory:
                root=Path(directory)
                for mode in ('success','tamper','body_tamper','drop','duplicate'):scenario(runtime,source,root,mode)
                report.update(result='SYNTHETIC_NATIVE_RPC_VERIFIED',native_selection_and_signing=True,
                    durable_claim_before_reply=True,tampered_selection_blocked=True,tampered_body_blocked_before_reserve=True,
                    lost_reply_never_replayed=True,duplicate_claim_blocked=True,scenarios=5)
    except Exception as error:
        report['result']='UNVERIFIED';report['synthetic_failure_mode']=mode;report['synthetic_failure_type']=type(error).__name__
    finally:report['profile_removed']=root is not None and not root.exists()
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
