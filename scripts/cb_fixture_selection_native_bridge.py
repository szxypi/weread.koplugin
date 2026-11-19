"""Duplex gate for native selected-text writes on one fresh CB fixture."""
import secrets
import subprocess

from annotation_experiment_model import digest,note_text,valid_key
from native_trial_pipe import Frames,reply,stop,write_initial


class NativeSelectionBridge:
    def __init__(self,command,payload,plan,baseline,intent,authority,read):
        if not command or any(not isinstance(value,str) or not value for value in command):raise ValueError('cb_native_selection/command')
        self.command,self.payload,self.plan,self.baseline=command,payload,plan,baseline
        self.intent,self.authority,self.read=intent,authority,read
        self.child=self.frames=self.awaiting=self.target=None
        self.steps=0;self.dry_verified=self.completed=False

    def _launch(self,armed):
        payload=dict(self.payload,armed=armed,token=secrets.token_hex(16))
        child=subprocess.Popen(self.command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        try:
            write_initial(child.stdin,payload)
            return child,Frames(child.stdout,payload['token'],timeout=600)
        except BaseException:
            stop(child);raise

    def _dry(self):
        child=None
        try:
            child,frames=self._launch(False);kind,event=frames.next()
            if kind!='STEP' or event!={'seq':0,'preview':self.payload['body']} or not self.authority() or self.read()!=self.baseline:
                raise ValueError('cb_native_selection/dry')
            reply(child.stdin,{'seq':0,'ok':True});kind,result=frames.next()
            expected=dict(result='DRY_RUN',profile_removed=True,installed_bytes_match=True,stage=None,
                          native_controls=True,writes=0,fresh_offline=False,credentials_not_persisted=True)
            if kind!='RESULT' or result!=expected or child.wait(timeout=15) or not self.authority() or self.read()!=self.baseline:
                raise ValueError('cb_native_selection/dry')
            self.dry_verified=True
        finally:
            if child is not None:stop(child)

    def send(self,step,body,receipt):
        state,current=self.intent.read()
        if (not self.authority() or current!=receipt or not state or state['phase']!='pending'
                or state['plan']!=self.plan or state['native_steps']!=step-1 or step!=self.steps+1 or not 1<=step<=3
                or state['cleanup_pending'] or state['cleanup_verified']):raise ValueError('cb_native_selection/intent')
        if step==1:
            if body!=self.payload['body'] or digest(body)!=self.plan['request_sha256'] or body.get('isPrivate')!=1:
                raise ValueError('cb_native_selection/body')
            if self.read()!=self.baseline:raise ValueError('cb_native_selection/baseline')
            self._dry()
            if self.intent.read()[1]!=receipt or not self.authority():raise ValueError('cb_native_selection/intent')
            self.child,self.frames=self._launch(True)
        else:
            if self.awaiting!=step-1 or state['created_id']!=self.target or body.get('reviewId')!=self.target:
                raise ValueError('cb_native_selection/target')
            expected=dict(reviewId=self.target,**({'content':note_text(self.plan['nonce'],True)} if step==2 else {}))
            if body!=expected:raise ValueError('cb_native_selection/body')
            reply(self.child.stdin,{'seq':self.awaiting,'ok':True,'created_id':self.target});self.awaiting=None
        kind,event=self.frames.next()
        if (kind!='STEP' or set(event)!={'seq','created_id'} or type(event['seq']) is not int or event['seq']!=step
                or not valid_key(event['created_id']) or event['created_id'] in self.baseline['thoughts']
                or self.target is not None and event['created_id']!=self.target):raise ValueError('cb_native_selection/step')
        self.target=event['created_id'];self.awaiting=step;self.steps=step

    def finish(self):
        state,_=self.intent.read()
        if (self.steps!=3 or self.awaiting!=3 or not self.authority() or state is None or state['phase']!='pending'
                or state['plan']!=self.plan or state['native_steps']!=3 or state['created_id']!=self.target
                or state['cleanup_pending'] or not state['cleanup_verified']):raise ValueError('cb_native_selection/finish')
        reply(self.child.stdin,{'seq':3,'ok':True,'created_id':self.target});self.awaiting=None
        kind,result=self.frames.next()
        expected=dict(result='PASS',profile_removed=True,installed_bytes_match=True,stage=None,
                      native_controls=True,writes=3,fresh_offline=True,credentials_not_persisted=True)
        if kind!='RESULT' or result!=expected or self.child.wait(timeout=15) or not self.authority():raise ValueError('cb_native_selection/result')
        self.completed=True

    def close(self):
        if self.child is not None:stop(self.child);self.child=None
        self.payload=None
