#!/usr/bin/env python3
"""One bounded synthetic personal-book import with a permanent no-replay intent.

Offline by default. Opt-in mode first validates two independent shelf reads.
One fresh temporary-credential GET, one COS PUT, one notification and at most
one removal of the exact newly returned book ID are possible. Unknown receipts
stop the trial; neither upload nor cleanup is automatically replayed.
"""
import argparse,hashlib,json,re,resource,secrets,time
from datetime import datetime,timezone
from urllib.error import HTTPError,URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler,Request,build_opener
from cos_signature import sign
from personal_upload_trial import Journal,check,hash_value,prepare,projection,valid_book
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE,NativeProbe

BODY=b'KOReader synthetic upload verification.\nThis file contains no personal content.\n'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*_args,**_kwargs):return None


class Probe(NativeProbe):
    def __init__(self,journal,grant_check,opener=None,cos_opener=None):
        super().__init__(opener);self.journal=journal;self.grant_check=grant_check
        self.cos_opener=cos_opener or build_opener(NoRedirect());self.allowed=None
        self.attempts=dict(credential=0,put=0,notify=0,cleanup=0);self.cos_status=None;self.reads=0
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if stage=='shelf' and url==BASE+'/shelf/sync' and body is None and self.reads<20:
            self.reads+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)
        if stage in ('credential','notify','cleanup') and self.allowed==(stage,url,body) and self.attempts[stage]==0:
            self.attempts[stage]+=1;return super().request(stage,url,body=body,credentials=credentials,timeout=timeout)
        raise ValueError('personal_upload/scope')
    def shelf(self,credentials):return self.request('shelf',BASE+'/shelf/sync',credentials=credentials)
    def owns(self,phase,credentials,receipt):
        state,current=self.journal.read()
        if (not state or state['phase']!=phase or current!=receipt or state['plan']['owner']!=credentials.get('vid')
                or state['plan']['grant_sha256']!=hash_value(credentials) or not self.grant_check(credentials)):
            raise ValueError('personal_upload/ownership')
        return state
    def credential(self,credentials,receipt):
        state=self.owns('credential_pending',credentials,receipt);name=state['plan']['name'][:-4]
        url=BASE+'/cos/getcredential?'+urlencode(dict(name=name,**{'from':''}));self.allowed=('credential',url,None)
        try:return self.request('credential',url,credentials=credentials)
        finally:self.allowed=None
    def put(self,credentials,receipt,temporary,body,now):
        state=self.owns('upload_pending',credentials,receipt)
        if (not isinstance(body,bytes) or hashlib.sha256(body).hexdigest()!=state['plan']['body_sha256']
                or hash_value({'bucket':temporary.get('bucket'),'ObjectName':temporary.get('ObjectName')})!=state['object_sha256']
                or self.attempts['put']):raise ValueError('personal_upload/ownership')
        request=sign(temporary,len(body),now)
        self.attempts['put']+=1
        try:
            with self.cos_opener.open(Request(request['url'],data=body,headers=request['headers'],method='PUT'),timeout=30) as response:
                self.cos_status=response.status;raw=response.read(65537)
                return response.status in (200,201) and len(raw)<=65536
        except HTTPError as error:self.cos_status=error.code;error.close();return False
        except (OSError,URLError,ValueError):return False
    def notify(self,credentials,receipt,temporary):
        state=self.owns('notify_pending',credentials,receipt)
        if hash_value({'bucket':temporary.get('bucket'),'ObjectName':temporary.get('ObjectName')})!=state['object_sha256']:
            raise ValueError('personal_upload/ownership')
        url=BASE+'/cos/notify?'+urlencode(dict(name=state['plan']['name'],path=temporary['ObjectName'],cancel='0'))
        self.allowed=('notify',url,{})
        try:return self.request('notify',url,body={},credentials=credentials)
        finally:self.allowed=None
    def cleanup(self,credentials,receipt):
        state=self.owns('cleanup_pending',credentials,receipt);target=state['target']
        if not valid_book(target):raise ValueError('personal_upload/ownership')
        url=BASE+'/shelf/delete';body=dict(bookIds=[target],albumIds=[],archiveIds=[]);self.allowed=('cleanup',url,body)
        try:return self.request('cleanup',url,body=body,credentials=credentials)
        finally:self.allowed=None


def acknowledged(value):
    if not isinstance(value,dict):return False
    if any(k in value and (type(value[k]) is not int or value[k]!=0) for k in ('errcode','errCode')):return False
    if 'succ' in value and not (value['succ'] is True or type(value['succ']) is int and value['succ']==1):return False
    if 'success' in value and value['success'] is not True:return False
    return 'succ' in value or 'success' in value


def readback(probe,credentials,plan,target,expected,tries,sleep):
    for attempt in range(tries):
        if attempt:sleep(.5*attempt)
        observed=projection(probe.shelf(credentials),target);present=observed.pop('present')
        if any(observed[k]!=plan[k] for k in observed):raise ValueError('personal_upload/other_change')
        if present is expected:return True
    return False


def run(probe,journal,credentials,grant_check,*,apply=False,sleep=time.sleep,now=time.time):
    report=dict(result='UNVERIFIED',phase='preflight',credential_requests=0,cos_put_attempts=0,notify_posts=0,cleanup_posts=0,
                authentication_posts=0,private_data_on_regular_disk=False)
    try:
        baseline=probe.shelf(credentials);name='KOReaderSynthetic-'+secrets.token_hex(8)+'.txt'
        plan=prepare(credentials,baseline,name,BODY);check(plan,credentials,probe.shelf(credentials))
        if not grant_check(credentials):raise ValueError('personal_upload/grant')
        report.update(independent_baselines_match=True,shelf_count=plan['count'])
        if journal.read()[0] is not None:raise ValueError('personal_upload/already_reserved')
        if not apply:report.update(result='READ_ONLY_PREVIEW',phase='preview');return report
        receipt=journal.reserve(plan);report['phase']='prepared';check(plan,credentials,probe.shelf(credentials))
        receipt=journal.advance(receipt,'credential_pending');report['phase']='credential_pending'
        try:temporary=probe.credential(credentials,receipt)
        finally:report['credential_requests']=probe.attempts['credential']
        sign(temporary,len(BODY),int(now()))
        object_hash=hash_value({'bucket':temporary.get('bucket'),'ObjectName':temporary.get('ObjectName')})
        receipt=journal.advance(receipt,'credential_ready',object_sha256=object_hash);report['phase']='credential_ready'
        check(plan,credentials,probe.shelf(credentials));receipt=journal.advance(receipt,'upload_pending');report['phase']='upload_pending'
        uploaded=False
        try:uploaded=probe.put(credentials,receipt,temporary,BODY,int(now())) is True
        except Exception:pass
        finally:report['cos_put_attempts']=probe.attempts['put']
        if not uploaded:raise ValueError('personal_upload/put_unconfirmed')
        receipt=journal.advance(receipt,'uploaded');report.update(phase='uploaded',cos_put_acknowledged=True)
        check(plan,credentials,probe.shelf(credentials));receipt=journal.advance(receipt,'notify_pending');report['phase']='notify_pending'
        notified=None
        try:notified=probe.notify(credentials,receipt,temporary)
        except Exception:pass
        finally:report['notify_posts']=probe.attempts['notify']
        target=notified.get('bookId') if isinstance(notified,dict) else None
        if (not isinstance(notified,dict) or type(notified.get('status')) is not int or notified['status']!=1 or not valid_book(target)
                or any(k in notified and (type(notified[k]) is not int or notified[k]!=0) for k in ('errcode','errCode'))):
            raise ValueError('personal_upload/notify_unconfirmed')
        check(plan,credentials,baseline,target,False)
        if not readback(probe,credentials,plan,target,True,5,sleep):raise ValueError('personal_upload/import_unconfirmed')
        receipt=journal.advance(receipt,'imported',target=target);report.update(phase='imported',import_observed=True)
        check(plan,credentials,probe.shelf(credentials),target,True)
        receipt=journal.advance(receipt,'cleanup_pending');report['phase']='cleanup_pending'
        ack=False
        try:ack=acknowledged(probe.cleanup(credentials,receipt))
        except Exception:pass
        finally:report['cleanup_posts']=probe.attempts['cleanup']
        restored=readback(probe,credentials,plan,target,False,3 if ack else 1,sleep)
        report.update(cleanup_acknowledged=ack,restore_observed=restored)
        if not ack or not restored:raise ValueError('personal_upload/cleanup_unconfirmed')
        check(plan,credentials,probe.shelf(credentials),target,False)
        if not grant_check(credentials):raise ValueError('personal_upload/grant')
        journal.advance(receipt,'restored');report.update(result='SYNTHETIC_IMPORT_ROUNDTRIP_VERIFIED',phase='restored',independent_restore_verified=True)
    except Exception as error:
        allowed={'personal_upload/already_reserved','personal_upload/grant','personal_upload/other_change','personal_upload/changed',
                 'personal_upload/put_unconfirmed','personal_upload/notify_unconfirmed','personal_upload/import_unconfirmed','personal_upload/cleanup_unconfirmed'}
        report['reason']=str(error) if str(error) in allowed else 'personal_upload/unavailable'
    return report


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--apply',action='store_true');a=p.parse_args(argv)
    if a.apply and not a.saved_session:p.error('--apply requires --saved-session')
    if not a.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY',cos_put_attempts=0,notify_posts=0,cleanup_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=probe=None
    try:
        saved=SessionStore().load();native=NativeSessionStore();grant=native.load(saved['vid']);journal=Journal()
        def same_grant(value):return native.load(saved['vid'])==value
        probe=Probe(journal,same_grant);report=run(probe,journal,grant,same_grant,apply=a.apply)
    except Exception:report=dict(result='UNVERIFIED',reason='personal_upload/unavailable')
    finally:
        if probe:
            report['cos_http_status']=probe.cos_status
            report['stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in probe.report['stages']]
        if saved:saved.clear()
        if grant:grant.clear()
    report['checked_at']=datetime.now(timezone.utc).isoformat();print(json.dumps(report,indent=2))
    return 0 if report['result'] in ('READ_ONLY_PREVIEW','SYNTHETIC_IMPORT_ROUNDTRIP_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
