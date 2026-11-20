#!/usr/bin/env python3
"""Exercise the fresh broker with isolated synthetic subprocesses only."""
from copy import deepcopy
import json,os,sys,tempfile
from pathlib import Path

from native_time_bundle_fresh_audit import FreshAuditStore
from native_time_bundle_fresh_broker import Prepared,execute
from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_native_time_bundle_evidence import synthetic_scope
from test_native_time_bundle_fresh_shelf import example
from test_native_time_bundle_gate import gate
from test_secure_native_session import Backend


CHILD=r'''
import json,os,shutil,signal,sys
from pathlib import Path
from cb_native_time_bundle_remote_archive import Relay
from native_time_bundle_workspace import restore
from native_time_bundle_selection import expected
from native_trial_pipe import read_initial
from test_native_time_bundle_accounting import example
from test_native_time_bundle_gate import fixture
from test_native_time_bundle_native_record import make_record
p=read_initial(sys.stdin.buffer);mode=sys.argv[1];token=p['token'];root=Path('/dev/shm/weread-native-time-'+token)
prefix='WEREAD_NATIVE_THOUGHT_'+token+'_'
def send(kind,value):
    sys.stdout.write('\n'+prefix+kind+'='+json.dumps(value,separators=(',',':'))+'\n');sys.stdout.flush()
def check(kind):
    value=json.loads(sys.stdin.readline());assert value['kind']==kind and type(value['ok']) is bool;return value['ok']
def interrupted(_signum,_frame):raise RuntimeError('synthetic/interrupted')
signal.signal(signal.SIGTERM,interrupted)
outcome='FAILED';os.mkdir(root,0o700)
try:
    source,_ledger=restore(p['bundle'],root)
    _b,_g,before,_samples,_now=example();_b,_g,body,_n=fixture()
    selection=expected(p['bundle']);record=make_record(p['bundle'],p['grant'],before,body,source)
    send('STEP',dict(kind='ready',source=str(source)+('.wrong' if mode=='bad_ready' else '')))
    if not check('ready'):raise ValueError('synthetic/denied')
    send('STEP',dict(kind='selection',selection=selection))
    if not check('selection'):raise ValueError('synthetic/denied')
    if mode=='tamper':record['metadata']['counts']['ttsTime']+=1
    relay=Relay(p['bundle']['plan'],root,source)
    send('STEP',relay.prepare(dict(kind='claim',body=body,selection=selection,record=record)))
    allowed=check('claim')
    if not allowed:outcome='DRY_BLOCKED'
    else:
        if mode=='lost':raise RuntimeError('synthetic/lost_reply')
        if mode=='changed':source.write_bytes(source.read_bytes()+b'changed')
        try:relay.recheck()
        except ValueError:outcome='FAILED'
        else:
            response={} if mode=='bad_ack' else {'succ':1}
            send('STEP',dict(kind='ack',status=200,response=response))
            if check('ack'):outcome='ACKNOWLEDGED'
finally:shutil.rmtree(root,ignore_errors=True)
send('RESULT',dict(result=outcome,profile_removed=not root.exists(),workers_reaped=True))
'''


class Capture:
    def __init__(self,bundle):self.bundle=deepcopy(bundle);self.receipt=Receipt(b'synthetic-capture')
    def read(self):return deepcopy(self.bundle),self.receipt


def scenario(mode):
    existing={p.name for p in Path('/dev/shm').glob('weread-native-time-*')}
    bundle,grant,evidence,_observations=example();now=evidence.for_bundle(bundle,grant)[0]['completed_at']
    capture=Capture(bundle);keeper=gate(now);audit=FreshAuditStore(Backend(),clock=lambda:now)
    prepared=Prepared(bundle,capture.receipt,grant,evidence);signing=SigningInputs('synthetic-guest','synthetic-config')
    cookies={'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'}
    report=execute(prepared,signing,cookies,capture,keeper,audit,lambda:True,lambda:synthetic_scope(bundle),
                   [sys.executable,'-c',CHILD,mode],armed=mode!='dry')
    if {p.name for p in Path('/dev/shm').glob('weread-native-time-*')}-existing:raise ValueError('synthetic_fresh_broker/cleanup')
    state,_=keeper.read();phase=state['phase'] if state else None
    expected={'success':('NATIVE_FRESH_ACKNOWLEDGED','acknowledged',True),
              'dry':('NATIVE_FRESH_DRY_RUN_VERIFIED',None,False),
              'tamper':('UNVERIFIED',None,False),'bad_ready':('UNVERIFIED',None,False),
              'lost':('UNVERIFIED','claimed',True),'changed':('UNVERIFIED','claimed',True),
              'bad_ack':('UNVERIFIED','claimed',True)}[mode]
    if (report['result'],phase,report['dispatch_may_have_occurred'])!=expected:
        raise ValueError('synthetic_fresh_broker/result '+mode+' '+repr(report))
    if (audit.read()[0] is not None)!=(phase is not None):raise ValueError('synthetic_fresh_broker/audit')
    if report['authentication_posts']!=0 or report['real_accounting_verified'] is not False:raise ValueError('synthetic_fresh_broker/report')
    prepared.close()


def main():
    if sys.platform!='linux' or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        raise ValueError('synthetic_fresh_broker/tmpfs')
    os.environ['PYTHONPATH']=str(Path(__file__).resolve().parent)
    for mode in ('success','dry','tamper','bad_ready','lost','changed','bad_ack'):scenario(mode)
    print(json.dumps(dict(result='SYNTHETIC_NATIVE_FRESH_BROKER_VERIFIED',scenarios=7,account_data_posts=0,
                          authentication_posts=0,ambiguous_claims_not_replayed=True)))


if __name__=='__main__':main()
