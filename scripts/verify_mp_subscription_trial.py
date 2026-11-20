#!/usr/bin/env python3
"""Public-account subscription proof: offline unless explicitly enabled.

The optional two-write trial has its own permanent Keychain tombstone. Each
POST is claimed before dispatch; an unknown receipt is never replayed and
never authorizes the second POST. Reports contain only fixed metadata.
"""
import argparse,json,re,resource,time
from datetime import datetime,timezone
from mp_subscription_trial import Journal,check,grant_digest,prepare,projection
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE,NativeProbe
from verify_mp_catalog import KNOWN_REVIEW


class Probe(NativeProbe):
    def __init__(self,target,journal,grant_check,opener=None):
        super().__init__(opener);self.target=target;self.journal=journal;self.grant_check=grant_check
        self.attempts={'add':0,'remove':0};self.permit=None;self.reads=0
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if stage=='shelf' and url==BASE+'/shelf/sync' and body is None and self.reads<16:
            self.reads+=1;return super().request(stage,url,credentials=credentials,timeout=timeout)
        if (stage in ('add','remove') and self.permit==(stage,url,body) and self.attempts[stage]==0
                and url==BASE+('/shelf/add' if stage=='add' else '/shelf/delete')
                and body==dict(albumIds=[],archiveIds=[],bookIds=[self.target])):
            self.attempts[stage]+=1;return super().request(stage,url,body=body,credentials=credentials,timeout=timeout)
        raise ValueError('mp_subscription/scope')
    def shelf(self,credentials):return self.request('shelf',BASE+'/shelf/sync',credentials=credentials)
    def send(self,stage,credentials,receipt):
        state,current=self.journal.read()
        if (stage not in ('add','remove') or not state or state['phase']!=stage+'_pending' or current!=receipt
                or state['plan']['account_id']!=self.target or state['plan']['owner']!=credentials.get('vid')
                or state['plan']['grant_sha256']!=grant_digest(credentials) or not self.grant_check(credentials)):
            raise ValueError('mp_subscription/ownership')
        path='/shelf/add' if stage=='add' else '/shelf/delete'
        body=dict(albumIds=[],archiveIds=[],bookIds=[self.target]);self.permit=(stage,BASE+path,body)
        try:return self.request(stage,BASE+path,body=body,credentials=credentials)
        finally:self.permit=None


def acknowledged(value):
    if not isinstance(value,dict):return False
    if any(k in value and (type(value[k]) is not int or value[k]!=0) for k in ('errcode','errCode')):return False
    if 'succ' in value and not (value['succ'] is True or type(value['succ']) is int and value['succ']==1):return False
    if 'success' in value and value['success'] is not True:return False
    return 'succ' in value or 'success' in value


def readback(probe,credentials,plan,expected,tries,sleep):
    for attempt in range(tries):
        if attempt:sleep(.5*attempt)
        source=probe.shelf(credentials);observed=projection(source,plan['account_id'])
        present=observed.pop('present')
        if any(observed[k]!=plan[k] for k in observed):raise ValueError('mp_subscription/other_change')
        if present is expected:return True
    return False


def run(probe,journal,credentials,target,grant_check,*,apply=False,sleep=time.sleep):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False)
    try:
        plan=prepare(credentials,probe.shelf(credentials),target)
        check(plan,credentials,probe.shelf(credentials),False)
        if not grant_check(credentials):raise ValueError('mp_subscription/grant')
        report.update(shelf_count=plan['count'],target_initially_absent=True,independent_baselines_match=True)
        current,_receipt=journal.read()
        if current is not None:raise ValueError('mp_subscription/already_reserved')
        if not apply:report.update(result='READ_ONLY_PREVIEW',phase='preview');return report
        receipt=journal.reserve(plan);report['phase']='prepared'
        check(plan,credentials,probe.shelf(credentials),False)
        if not grant_check(credentials):raise ValueError('mp_subscription/grant')
        receipt=journal.advance(receipt,'add_pending');report['phase']='add_pending'
        accepted=False
        try:accepted=acknowledged(probe.send('add',credentials,receipt))
        except Exception:pass
        finally:report['account_data_posts']=sum(probe.attempts.values())
        report['add_acknowledged']=accepted
        report['add_observed']=readback(probe,credentials,plan,True,3 if accepted else 1,sleep)
        if not accepted or not report['add_observed']:raise ValueError('mp_subscription/add_unconfirmed')
        receipt=journal.advance(receipt,'add_confirmed');report['phase']='add_confirmed'
        check(plan,credentials,probe.shelf(credentials),True)
        if not grant_check(credentials):raise ValueError('mp_subscription/grant')
        receipt=journal.advance(receipt,'remove_pending');report['phase']='remove_pending'
        accepted=False
        try:accepted=acknowledged(probe.send('remove',credentials,receipt))
        except Exception:pass
        finally:report['account_data_posts']=sum(probe.attempts.values())
        report['remove_acknowledged']=accepted
        report['restore_observed']=readback(probe,credentials,plan,False,3 if accepted else 1,sleep)
        if not accepted or not report['restore_observed']:raise ValueError('mp_subscription/remove_unconfirmed')
        check(plan,credentials,probe.shelf(credentials),False)
        if not grant_check(credentials):raise ValueError('mp_subscription/grant')
        journal.advance(receipt,'restored');report.update(result='ROUNDTRIP_VERIFIED',phase='restored',independent_restore_verified=True)
    except Exception as error:
        allowed={'mp_subscription/already_reserved','mp_subscription/already_present','mp_subscription/grant',
                 'mp_subscription/other_change','mp_subscription/add_unconfirmed','mp_subscription/remove_unconfirmed',
                 'mp_subscription/changed','mp_subscription/ownership'}
        report['reason']=str(error) if str(error) in allowed else 'mp_subscription/unavailable'
    return report


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--apply',action='store_true');a=p.parse_args(argv)
    if a.apply and not a.saved_session:p.error('--apply requires --saved-session')
    if not a.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=credentials=probe=None
    try:
        saved=SessionStore().load();store=NativeSessionStore();credentials=store.load(saved['vid']);journal=Journal()
        target=re.fullmatch(r'(MP_WXS_[1-9][0-9]{0,19})_.+',KNOWN_REVIEW).group(1)
        def same_grant(value):return store.load(saved['vid'])==value
        probe=Probe(target,journal,same_grant);report=run(probe,journal,credentials,target,same_grant,apply=a.apply)
    except Exception:report=dict(result='UNVERIFIED',reason='mp_subscription/unavailable',account_data_posts=0,authentication_posts=0)
    finally:
        if probe:
            report['stages']=[{k:row[k] for k in ('stage','status','error_code') if k in row} for row in probe.report['stages']]
        if saved:saved.clear()
        if credentials:credentials.clear()
    report['checked_at']=datetime.now(timezone.utc).isoformat()
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0 if report['result'] in ('READ_ONLY_PREVIEW','ROUNDTRIP_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
