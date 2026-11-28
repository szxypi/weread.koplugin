"""Host CAS/expiry witness for a single native renewal, with no data transport."""
from copy import deepcopy
import hashlib
import re
import subprocess
import time
from native_trial_pipe import Frames,write_initial,reply,stop
from native_source_recovery_contract import validate_payload,validate_result
from verify_eink_renewal import validate_credentials
from secure_native_txt_roundtrip import POINT_FIELDS,point
from native_txt_read_model import body
from verify_native_position_lua import equivalent


def check_refresh(value,grant):
    fields={'deviceId','deviceName','deviceType','timestamp','random','trackId','signature','refreshToken','inBackground','kickType','refCgi'}
    if not isinstance(value,dict) or set(value)!=fields: raise ValueError('source_recovery/refresh')
    stamp,random=value['timestamp'],value['random']
    if (type(stamp) is not int or not 0<=time.time()*1000-stamp<=30000 or type(random) is not int or not 1<=random<=999
            or value['deviceId']!=grant['deviceId'] or value['refreshToken']!=grant['refreshToken']
            or value['deviceName']!='BOOX' or type(value['deviceType']) is not int or value['deviceType']!=3
            or value['trackId']!='' or type(value['inBackground']) is not int or value['inBackground']!=0
            or type(value['kickType']) is not int or value['kickType']!=1 or value['refCgi']!=''
            or value['signature']!=hashlib.sha256(f"{stamp}{grant['deviceId']}{random}".encode()).hexdigest()):
        raise ValueError('source_recovery/refresh')


def check_metadata(value,payload,observation,percent):
    fields={'book_id','before','desired','counts','version','shelf_sha256','source_sha256','file_id','basis'}
    if not isinstance(value,dict) or set(value)!=fields: raise ValueError('source_recovery/metadata')
    point(value['before']);point(value['desired']);trial=payload['native_recovery']
    if (value['book_id']!=payload['book_id'] or value['basis']!='raw_txt_utf16' or type(percent) is not int or not 0<=percent<=100
            or not equivalent(value['before'],trial['baseline']) or not equivalent(value['before'],observation['point'])
            or not equivalent(value['counts'],observation['counts']) or type(value['version']) is not int or value['version']!=observation['version']
            or value['shelf_sha256']!=observation['shelf_sha256'] or value['source_sha256']!=payload['source_raw_sha256']
            or not isinstance(value['file_id'],str) or not re.fullmatch('[a-f0-9]{64}',value['file_id'])
            or value['desired']['raw_percent']!=percent
            or any(value['desired'][k]!=trial['target'][k] for k in POINT_FIELDS-{'raw_percent'})):
        raise ValueError('source_recovery/metadata')


class Broker:
    def __init__(self,payload,store,*,verify_expiry,observe,current=lambda:None,claim=lambda:None,allow_renewal=True):
        if type(allow_renewal) is not bool:raise ValueError('source_recovery/authorization')
        validate_payload(payload,payload.get('reader_mock_port'))
        self.payload=deepcopy(payload);self.store=store;self.verify_expiry=verify_expiry;self.observe=observe
        self.current,self.claim=current,claim;self.phase='init';self.grant=deepcopy(payload['native_grant'])
        self.fresh=self.receipt=self.observation=self.metadata=None;self.expired_at=0;self.posts=0;self.blocked=0
        self.allow_renewal=allow_renewal
    def handle(self,value):
        if not isinstance(value,dict): raise ValueError('source_recovery/event')
        kind,seq=value.get('kind'),value.get('seq')
        if type(seq) is not int: raise ValueError('source_recovery/event')
        expected={'expiry':(1,'init',{'url','status'}),'claim':(2,'expired',{'body'}),
                  'verified':(3,'claimed',{'credentials','book_count'}),'plan':(4,'verified',{'metadata','reader_percent'}),
                  'data':(5,'planned',{'body'}),'no_expiry':(0,'init',{'metadata','reader_percent'})}
        if kind not in expected: raise ValueError('source_recovery/event')
        number,phase,fields=expected[kind]
        if seq!=number or self.phase!=phase or set(value)!=fields|{'kind','seq'}: raise ValueError('source_recovery/sequence')
        self.current();owner=self.payload['vid']
        if kind=='expiry':
            allowed={'https://i.weread.qq.com/book/info?bookId='+self.payload['book_id'],
                     'https://i.weread.qq.com/book/getProgress?bookId='+self.payload['book_id'],
                     'https://i.weread.qq.com/shelf/sync','https://i.weread.qq.com/feature?synckey=0'}
            if (type(value['status']) is not int or value['status']!=401 or value['url'] not in allowed
                    or self.verify_expiry(value['url'],self.grant) is not True): raise ValueError('source_recovery/expiry')
            self.expired_at=time.monotonic();self.phase='expired'
        elif kind=='claim':
            if not self.allow_renewal:raise ValueError('source_recovery/renewal_disabled')
            if not 0<=time.monotonic()-self.expired_at<=30: raise ValueError('source_recovery/stale_expiry')
            check_refresh(value['body'],self.grant)
            self.claim()  # Durable once-only marker, before Keychain and HTTP permission.
            self.receipt,previous=self.store.begin_renewal(owner,self.grant)
            if previous!=self.grant: raise ValueError('source_recovery/replaced')
            self.posts=1;self.phase='claimed'
        elif kind=='verified':
            fresh=value['credentials'];validate_credentials(fresh)
            if (set(fresh)!={'vid','accessToken','refreshToken','deviceId'} or fresh['vid']!=owner or fresh['deviceId']!=self.grant['deviceId']
                    or type(value['book_count']) is not int or not 1<=value['book_count']<=5000): raise ValueError('source_recovery/owner')
            observation=self.observe(fresh)
            if observation['book_count']!=value['book_count'] or not equivalent(observation['point'],self.payload['native_recovery']['baseline']):
                raise ValueError('source_recovery/observation')
            self.current();self.store.finish_renewal(self.receipt,fresh,verified=True)
            if self.store.load(owner)!=fresh: raise ValueError('source_recovery/readback')
            self.fresh,self.observation=deepcopy(fresh),deepcopy(observation);self.phase='verified'
        elif kind in ('plan','no_expiry'):
            if kind=='no_expiry': self.observation=self.observe(self.grant)
            check_metadata(value['metadata'],self.payload,self.observation,value['reader_percent'])
            self.metadata=deepcopy(value['metadata']);self.phase='no_expiry' if kind=='no_expiry' else 'planned'
        elif kind=='data':
            if self.store.load(owner)!=self.fresh: raise ValueError('source_recovery/replaced')
            candidate=value['body']
            if not isinstance(candidate,dict): raise ValueError('source_recovery/body')
            stamp,random=candidate.get('timestamp'),candidate.get('random')
            if type(stamp) is not int or not 0<=time.time()-stamp<=30 or type(random) is not int or not 0<=random<=999:
                raise ValueError('source_recovery/clock')
            expected=body(self.fresh,self.metadata['desired'],self.observation['version'],self.observation['guest'],stamp,random,
                          self.payload['native_recovery']['time_zone'])
            if not equivalent(candidate,expected): raise ValueError('source_recovery/body')
            self.blocked=1;self.phase='blocked'  # Reply authorizes only local rejection, never HTTP.
        return dict(kind=kind,seq=seq,ok=True)
    def finish(self,runner):
        validate_result(runner,self.payload['vid']);a=runner['stage']['native_recovery']
        if (runner['result']!='PASS' or self.phase not in ('blocked','no_expiry') or a['no_expiry']!=(self.phase=='no_expiry')
                or a['authentication_posts']!=self.posts or a['blocked_posts']!=self.blocked): raise ValueError('source_recovery/incomplete')
        self.current();grant=self.fresh or self.grant
        if self.store.load(self.payload['vid'])!=grant: raise ValueError('source_recovery/replaced')
        later=self.observe(grant)
        for key in ('point','counts','version','shelf_sha256','book_count'):
            if not equivalent(later[key],self.observation[key]): raise ValueError('source_recovery/changed')


def execute(payload,command,broker,report):
    child=awaiting=runner=None
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['native_recovery']['rpc_token'],timeout=420)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':
                runner=validate_result(value,payload['vid'])
                report['native_ui']={k:v for k,v in runner.items() if k!='cookies'}
                break
            awaiting=value;reply(child.stdin,broker.handle(value));awaiting=None
        if child.wait(timeout=15): raise ValueError('source_recovery/child')
        broker.finish(runner)
        report.update(result='NO_NATIVE_EXPIRY_OBSERVED' if broker.phase=='no_expiry' else 'NATIVE_SOURCE_AUTOMATIC_RENEWAL_VERIFIED',
                      native_ui={k:v for k,v in runner.items() if k!='cookies'},same_owner_keychain_readback=True,
                      independent_position_counts_shelf_preserved=True)
        return runner['cookies']
    finally:
        report.update(authentication_posts_claimed=broker.posts,blocked_data_posts=broker.blocked,account_data_posts=0,
                      keychain_new_grant_saved=broker.fresh is not None)
        if child is not None:
            if awaiting is not None and child.poll() is None:
                try:reply(child.stdin,dict(kind=awaiting.get('kind'),seq=awaiting.get('seq'),ok=False))
                except Exception:pass
            stop(child)
