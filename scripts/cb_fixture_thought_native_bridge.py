"""Bind one isolated CB thought lifecycle to the real native editor.

The host owns the durable intents and independently reads each change before
releasing the next UI action. Input and identifiers stay on private pipes.
"""
from datetime import datetime, timezone
import secrets
import subprocess

from annotation_experiment_model import digest, note_text, valid_key
from native_trial_pipe import Frames, reply, stop, write_initial
from verify_native_thought_trial import validate_runner


class NativeThoughtBridge:
    def __init__(self, command, owner, book, grant, seed_intent, thought_intent, authority, read, *, mock_port=None):
        if not command or any(not isinstance(value,str) or not value for value in command):
            raise ValueError('cb_native_thought/command')
        self.command, self.owner, self.book, self.grant = command, owner, book, grant
        self.seed_intent, self.thought_intent = seed_intent, thought_intent
        self.authority, self.read, self.mock_port = authority, read, mock_port
        self.child = self.frames = self.payload = self.awaiting = self.target = None
        self.posts = 0
        self.dry_verified = self.completed = False

    def _launch(self, payload, armed):
        command = list(self.command) + (['--armed'] if armed else [])
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            write_initial(child.stdin,payload)
            return child,Frames(child.stdout,payload['rpc_token'],timeout=600)
        except BaseException:
            stop(child)
            raise

    def _payload(self, body, seed, snapshot, state, armed):
        now=int(datetime.now(timezone.utc).timestamp())
        payload=dict(rpc_token=secrets.token_hex(16),permit_writes=armed,credentials=self.grant,
            owner=self.owner,book_id=self.book,shelf_books=len(snapshot['shelf']),
            original_ids=sorted(snapshot['thoughts']),bookmark_id=seed['id'],
            marks=dict(schema=1,book_id=self.book,fetched_at=now,updated=list(snapshot['marks']['updated'].values()),
                       chapters=list(snapshot['marks']['chapters'].values())),
            thoughts=dict(schema=1,book_id=self.book,fetched_at=now,reviews=list(snapshot['thoughts'].values())),
            create_body=body,edited_text=note_text(state['plan']['nonce'],True))
        if self.mock_port is not None:payload['mock_port']=self.mock_port
        return payload

    def _dry(self,payload,snapshot):
        child=None
        try:
            child,frames=self._launch(payload,False)
            kind,event=frames.next()
            if kind!='STEP' or event!={'seq':0,'preview':payload['create_body']} or not self.authority() or self.read()!=snapshot:
                raise ValueError('cb_native_thought/dry')
            reply(child.stdin,{'seq':0,'ok':True})
            kind,result=frames.next()
            if kind!='RESULT':raise ValueError('cb_native_thought/dry')
            validate_runner(result,False)
            if child.wait(timeout=15) or not self.authority() or self.read()!=snapshot:raise ValueError('cb_native_thought/dry')
            self.dry_verified=True
        finally:
            if child is not None:stop(child)

    def send(self,phase,body,receipt):
        expected=('create_pending','edit_pending','delete_pending')
        state,_=self.thought_intent.read();seed_state,_=self.seed_intent.read()
        if (self.posts>=3 or phase!=expected[self.posts] or not self.authority()
                or not self.thought_intent.owns(receipt,phase) or not state or not seed_state
                or seed_state['phase']!='created' or state['plan']['book_sha256']!=digest(self.book)
                or state['plan']['owner_sha256']!=digest(self.owner)):
            raise ValueError('cb_native_thought/scope')
        if self.posts==0:
            if digest(body)!=state['plan']['request_sha256'] or body.get('bookId')!=self.book or body.get('isPrivate')!=1:
                raise ValueError('cb_native_thought/body')
            snapshot=self.read();seed=seed_state['target']
            if digest(snapshot)!=state['plan']['baseline_sha256'] or digest(seed)!=state['plan']['seed_sha256']:
                raise ValueError('cb_native_thought/baseline')
            dry=self._payload(body,seed,snapshot,state,False);self._dry(dry,snapshot)
            if not self.thought_intent.owns(receipt,phase) or not self.authority():raise ValueError('cb_native_thought/intent')
            self.payload=self._payload(body,seed,snapshot,state,True)
            self.child,self.frames=self._launch(self.payload,True)
        else:
            if state['created_id']!=self.target or self.awaiting!=self.posts or body.get('reviewId')!=self.target:
                raise ValueError('cb_native_thought/target')
            if phase=='edit_pending' and body!={'reviewId':self.target,'content':note_text(state['plan']['nonce'],True)}:
                raise ValueError('cb_native_thought/body')
            if phase=='delete_pending' and body!={'reviewId':self.target}:raise ValueError('cb_native_thought/body')
            reply(self.child.stdin,{'seq':self.awaiting,'ok':True,'created_id':self.target})
            self.awaiting=None
        kind,event=self.frames.next()
        seq=self.posts+1
        if (kind!='STEP' or set(event)!={'seq','created_id'} or type(event['seq']) is not int or event['seq']!=seq
                or not valid_key(event['created_id']) or event['created_id'] in self.payload['original_ids']
                or self.target is not None and self.target!=event['created_id']):raise ValueError('cb_native_thought/step')
        self.target=event['created_id'];self.awaiting=seq;self.posts=seq

    def finish(self):
        if (self.posts!=3 or self.awaiting!=3 or self.thought_intent.read()!=(None,None) or not self.authority()):
            raise ValueError('cb_native_thought/finish')
        reply(self.child.stdin,{'seq':3,'ok':True,'created_id':self.target});self.awaiting=None
        kind,result=self.frames.next()
        if kind!='RESULT':raise ValueError('cb_native_thought/result')
        validate_runner(result,True)
        if self.child.wait(timeout=15) or not self.authority():raise ValueError('cb_native_thought/result')
        self.completed=True

    def close(self):
        if self.child is not None:stop(self.child);self.child=None
        if self.payload is not None:self.payload.clear();self.payload=None
