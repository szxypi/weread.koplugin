"""One host-claimed native renewal with independently verified shelf state."""
from copy import deepcopy
import subprocess,time
from native_source_recovery_broker import check_refresh
from native_trial_pipe import Frames,reply,stop,write_initial
from verify_eink_renewal import validate_credentials


def shelf_projection(value):
    if not isinstance(value,dict):raise ValueError('shelf_renewal/shelf')
    books=value.get('books');groups=value.get('archive',value.get('archives'))
    if not isinstance(books,list) or not isinstance(groups,list) or len(books)>5000 or len(groups)>1000:
        raise ValueError('shelf_renewal/shelf')
    def identity(raw):
        if isinstance(raw,bool) or not isinstance(raw,(str,int)) or not str(raw):raise ValueError('shelf_renewal/id')
        return str(raw)
    clean=[];seen=set()
    for row in books:
        if not isinstance(row,dict) or not isinstance(row.get('title'),str):raise ValueError('shelf_renewal/shelf')
        book=identity(row.get('bookId'));author=row.get('author','')
        if book in seen or not isinstance(author,str):raise ValueError('shelf_renewal/shelf')
        seen.add(book);clean.append((book,row['title'],author))
    archives=[];keys=set()
    for group in groups:
        if not isinstance(group,dict) or not isinstance(group.get('name'),str) or not isinstance(group.get('bookIds'),list):
            raise ValueError('shelf_renewal/groups')
        key=identity(group.get('archiveId'));members=[identity(item) for item in group['bookIds']]
        if key in keys or len(members)!=len(set(members)):raise ValueError('shelf_renewal/groups')
        keys.add(key);archives.append((key,group['name'],tuple(sorted(members))))
    return sorted(clean),sorted(archives)


class Broker:
    def __init__(self,grant,store,*,current,verify_expiry,verify_grant,observe,claim):
        validate_credentials(grant);self.grant=deepcopy(grant);self.store=store;self.current=current
        self.verify_expiry=verify_expiry;self.verify_grant=verify_grant;self.observe=observe;self.claim=claim
        self.phase='initial';self.receipt=self.fresh=self.snapshot=None;self.expired_at=0;self.auth_claimed=0;self.saved_status=False
    def handle(self,event,armed):
        if not isinstance(event,dict) or type(armed) is not bool:raise ValueError('shelf_renewal/event')
        name=event.get('kind');self.current()
        if name=='expiry' and self.phase=='initial' and event==dict(kind='expiry',status=401):
            if self.verify_expiry(self.grant) is not True:raise ValueError('shelf_renewal/expiry')
            self.expired_at=time.monotonic();self.phase='expired';return True
        if name=='claim' and self.phase=='expired' and set(event)=={'kind','body'}:
            if not 0<=time.monotonic()-self.expired_at<=30:raise ValueError('shelf_renewal/stale')
            check_refresh(event['body'],self.grant)
            if not armed:self.phase='dry';return False
            self.claim();self.receipt,previous=self.store.begin_renewal(self.grant['vid'],self.grant)
            try:
                if previous!=self.grant:raise ValueError('shelf_renewal/session')
                self.current();check_refresh(event['body'],self.grant)
            except Exception:
                self.store.release_renewal(self.receipt,not_dispatched=True);raise
            self.auth_claimed=1;self.phase='claimed';return True
        if name=='verified' and self.phase=='claimed' and armed and set(event)=={'kind','credentials','book_count'}:
            fresh=event['credentials'];validate_credentials(fresh)
            if (set(fresh)!={'vid','deviceId','accessToken','refreshToken'} or fresh['vid']!=self.grant['vid']
                    or fresh['deviceId']!=self.grant['deviceId'] or type(event['book_count']) is not int):raise ValueError('shelf_renewal/owner')
            count=self.verify_grant(fresh)
            if type(count) is not int or not 1<=count<=5000:raise ValueError('shelf_renewal/count')
            self.current();self.saved_status=None;self.store.finish_renewal(self.receipt,fresh,verified=True)
            if self.store.load(fresh['vid'])!=fresh:raise ValueError('shelf_renewal/readback')
            self.saved_status=True;self.fresh=deepcopy(fresh);self.phase='verified'
            if count!=event['book_count']:raise ValueError('shelf_renewal/count')
            self.snapshot=self.observe(fresh);return True
        if name=='shelf' and self.phase=='verified' and armed and set(event)=={'kind','snapshot'}:
            if shelf_projection(event['snapshot'])!=self.snapshot or self.store.load(self.grant['vid'])!=self.fresh:
                raise ValueError('shelf_renewal/shelf')
            if self.observe(self.fresh)!=self.snapshot:raise ValueError('shelf_renewal/shelf')
            self.phase='complete';return True
        raise ValueError('shelf_renewal/order')


def execute(payload,command,broker,report):
    child=waiting=None;armed=payload['armed'];events=[]
    try:
        broker.current();child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['token'],timeout=420,max_frame=2*1024*1024)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':
                runner=event
                if payload.get('mock_endpoint') and isinstance(event,dict):
                    report['synthetic_diagnostic']={key:event[key] for key in ('stage','diagnostic') if key in event}
                break
            waiting=event;name=event.get('kind');allow=broker.handle(event,armed);events.append(name)
            reply(child.stdin,dict(kind=name,ok=allow));waiting=None
        if (child.wait(timeout=15)!=0 or runner.get('profile_removed') is not True
                or runner.get('result')!=('SHELF_RENEWAL_VERIFIED' if armed else 'DRY_BLOCKED')
                or events!=( ['expiry','claim','verified','shelf'] if armed else ['expiry','claim'])
                or broker.phase!=('complete' if armed else 'dry')):raise ValueError('shelf_renewal/runner')
        report.update(result='NATIVE_SHELF_RENEWAL_VERIFIED' if armed else 'NATIVE_SHELF_RENEWAL_DRY_VERIFIED',
            profile_removed=True,account_data_posts=0,authentication_posts_claimed=broker.auth_claimed,
            same_account_and_shelf_independently_verified=armed)
    finally:
        report.update(authentication_posts_claimed=broker.auth_claimed,keychain_new_grant_saved=broker.saved_status)
        if child is not None:
            if waiting is not None and child.poll() is None:
                try:reply(child.stdin,dict(kind=waiting.get('kind'),ok=False))
                except Exception:pass
            stop(child)
