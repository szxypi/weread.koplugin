#!/usr/bin/env python3
"""Exercise the CB host broker with synthetic isolated subprocesses."""
import json,os,sys,tempfile
from pathlib import Path

from cb_native_time_bundle_broker import execute
from cb_native_time_bundle_preflight import Prepared
from native_time_bundle_preparation import SigningInputs
from test_cb_native_time_bundle_supervisor import fixture


CHILD=r'''
import json,os,shutil,signal,sys,tempfile
from pathlib import Path
from cb_native_time_bundle_remote_archive import Relay
from native_time_bundle_workspace import restore
from native_trial_pipe import read_initial
from test_cb_native_time_bundle_native_record import setup
p=read_initial(sys.stdin.buffer);mode=sys.argv[1];token=p['token'];root=Path('/dev/shm/weread-cb-'+token)
prefix='WEREAD_NATIVE_THOUGHT_'+token+'_'
def send(kind,value):
    sys.stdout.write('\n'+prefix+kind+'='+json.dumps(value,separators=(',',':'))+'\n');sys.stdout.flush()
def check(kind):
    value=json.loads(sys.stdin.readline());assert value['kind']==kind and type(value['ok']) is bool;return value['ok']
def interrupted(_signum,_frame):raise RuntimeError('synthetic/interrupted')
signal.signal(signal.SIGTERM,interrupted)
outcome='FAILED';os.mkdir(root,0o700)
try:
    source,_ledger=restore(p['bundle'],root,imported=True)
    with tempfile.TemporaryDirectory(dir=root) as folder:
        _bundle,_grant,_evidence,selection,body,record,_path,_now=setup(folder)
    record['metadata']['source']['ref']['file']=str(source)
    send('STEP',dict(kind='ready',source=str(source)+('.wrong' if mode=='bad_ready' else '')))
    if not check('ready'):raise ValueError('synthetic/denied')
    send('STEP',dict(kind='selection',selection=selection))
    if not check('selection'):raise ValueError('synthetic/denied')
    if mode=='tamper':body['books'][0]['summary']='changed'
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
finally:
    shutil.rmtree(root,ignore_errors=True)
send('RESULT',dict(result=outcome,profile_removed=not root.exists(),workers_reaped=True))
'''


def scenario(directory,mode):
    existing={p.name for p in Path('/dev/shm').glob('weread-cb-*')}
    bundle,grant,evidence,_selection,_body,_record,_path,_now,gate,audit,store,state,_supervisor,_bridge=fixture(directory,True)
    prepared=Prepared(bundle,store.receipt,grant,evidence);signing=SigningInputs('synthetic-guest','synthetic-config')
    cookies={'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'}
    command=[sys.executable,'-c',CHILD,mode]
    report=execute(prepared,signing,cookies,store,gate,audit,lambda:state['current'],command,armed=mode!='dry')
    if {p.name for p in Path('/dev/shm').glob('weread-cb-*')}-existing:raise ValueError('synthetic_cb_broker/cleanup')
    state_value,_receipt=gate.read();phase=state_value['phase'] if state_value else None
    expected={'success':('CB_NATIVE_ACKNOWLEDGED','acknowledged',True),
              'dry':('CB_NATIVE_DRY_RUN_VERIFIED',None,False),
              'tamper':('UNVERIFIED',None,False),'bad_ready':('UNVERIFIED',None,False),
              'lost':('UNVERIFIED','claimed',True),'changed':('UNVERIFIED','claimed',True),
              'bad_ack':('UNVERIFIED','claimed',True)}[mode]
    if (report['result'],phase,report['dispatch_may_have_occurred'])!=expected:raise ValueError('synthetic_cb_broker/result '+mode)
    if (audit.read()[0] is not None)!=(phase is not None):raise ValueError('synthetic_cb_broker/audit')
    if report['authentication_posts']!=0 or report['real_accounting_verified'] is not False:raise ValueError('synthetic_cb_broker/report')
    prepared.close()


def main():
    if sys.platform!='linux' or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        raise ValueError('synthetic_cb_broker/tmpfs')
    os.environ['PYTHONPATH']=str(Path(__file__).resolve().parent)
    with tempfile.TemporaryDirectory(prefix='weread-cb-broker-',dir='/dev/shm') as root:
        for mode in ('success','dry','tamper','bad_ready','lost','changed','bad_ack'):
            folder=Path(root)/mode;folder.mkdir(mode=0o700);scenario(folder,mode)
    print(json.dumps(dict(result='SYNTHETIC_CB_BROKER_VERIFIED',scenarios=7,account_data_posts=0,
                          authentication_posts=0,ambiguous_claims_not_replayed=True)))


if __name__=='__main__':main()
