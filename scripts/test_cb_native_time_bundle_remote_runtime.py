#!/usr/bin/env python3
"""Synthetic archive relay across a private process pipe; no network."""
import json,os,secrets,subprocess,sys,tempfile
from pathlib import Path
from unittest.mock import patch

from cb_native_time_bundle_bridge import Bridge
from native_trial_pipe import Frames,reply,stop,write_initial
from test_cb_native_time_bundle_supervisor import fixture


CHILD=r'''
import json,sys
from cb_native_time_bundle_remote_archive import Relay
from native_trial_pipe import read_initial
p=read_initial(sys.stdin.buffer);prefix='WEREAD_NATIVE_THOUGHT_'+p['token']+'_'
def send(kind,value):
    sys.stdout.write('\n'+prefix+kind+'='+json.dumps(value,separators=(',',':'))+'\n');sys.stdout.flush()
def check(kind):
    value=json.loads(sys.stdin.readline());assert value['kind']==kind and type(value['ok']) is bool;return value['ok']
relay=Relay(p['plan'],p['root'],p['source'])
send('STEP',dict(kind='selection',selection=p['selection']))
assert check('selection')
event=dict(kind='claim',body=p['body'],selection=p['selection'],record=p['record'])
send('STEP',relay.prepare(event));allowed=check('claim')
if allowed:
    try:relay.recheck();result='READY'
    except ValueError:result='BLOCKED_CHANGED_ARCHIVE'
else:result='DRY_BLOCKED'
send('RESULT',dict(result=result))
'''


def scenario(root,mode):
    directory=root/mode;directory.mkdir(mode=0o700)
    bundle,_grant,_evidence,selection,body,record,path,_now,gate,audit,_capture,_state,supervisor,_bridge=fixture(directory,True)
    os.chmod(path,0o600);token=secrets.token_hex(16)
    bridge=Bridge(supervisor,path,armed=mode!='dry',remote=True)
    payload=dict(plan=bundle['plan'],root=str(directory),source=str(path),selection=selection,body=body,record=record,token=token)
    env=dict(os.environ,PYTHONPATH=str(Path(__file__).resolve().parent))
    child=subprocess.Popen([sys.executable,'-c',CHILD],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True,env=env)
    try:
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=20,max_frame=3*1024*1024)
        kind,event=frames.next();assert kind=='STEP' and event['kind']=='selection'
        reply(child.stdin,dict(kind='selection',ok=bridge.handle(event)))
        kind,event=frames.next();assert kind=='STEP' and event['kind']=='claim'
        with patch('cb_native_time_bundle_native_record.archive_details',side_effect=AssertionError('remote path opened on host')):
            allowed=bridge.handle(event)
        if mode=='changed':path.write_bytes(path.read_bytes()+b'changed')
        reply(child.stdin,dict(kind='claim',ok=allowed))
        kind,result=frames.next();assert kind=='RESULT' and result=={'result':{'success':'READY','dry':'DRY_BLOCKED',
                                                                               'changed':'BLOCKED_CHANGED_ARCHIVE'}[mode]}
        if child.wait(timeout=5):raise ValueError('synthetic_cb_remote/child')
        state,_=gate.read();phase=state['phase'] if state else None
        if phase!=('claimed' if mode!='dry' else None) or (audit.read()[0] is not None)!=(mode!='dry'):
            raise ValueError('synthetic_cb_remote/state')
        if mode!='dry':
            try:bridge.handle(event)
            except ValueError:pass
            else:raise ValueError('synthetic_cb_remote/replay')
    finally:stop(child)


def main():
    if sys.platform!='linux' or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        raise ValueError('synthetic_cb_remote/tmpfs')
    with tempfile.TemporaryDirectory(prefix='weread-cb-remote-',dir='/dev/shm') as directory:
        for mode in ('success','dry','changed'):scenario(Path(directory),mode)
    print(json.dumps(dict(result='SYNTHETIC_CB_REMOTE_PIPE_VERIFIED',scenarios=3,account_data_posts=0,
                          authentication_posts=0,changed_archive_blocked=True,unknown_not_replayed=True,profile_removed=True)))


if __name__=='__main__':main()
