#!/usr/bin/env python3
"""One bounded owner shelf-pin observation; offline unless explicitly enabled.

The selected book must be absent from three independently read shelves. A
persistent one-use intent prevents retries after interruption or ambiguity.
Private account data and credentials are never printed or written to files.
"""
import argparse
import hashlib
import json
from urllib.parse import urlencode

from pin_trial_contract import run,verify,observe
from secure_native_session import NativeSessionStore
from secure_pin_trial import PinTrialStore,SERVICE_V2
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_eink_login import BASE
from verify_pin_gateway import SERVICE,KeyWeb,gateway,validate
from verify_pin_preflight import PinProbe,fingerprint,prepare,progress_fingerprint,reading_fingerprint
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB

OPERATIONS=('add','pin','unpin','remove')


class Writer(PinProbe):
    def __init__(self):
        super().__init__();self.permit=None;self.next_operation=0;self.writes_attempted=0;self.grant=None;self.receipts=[]
    def guard(self,stage,url,body):
        if body is not None:
            if self.permit!=(stage,url,body):raise ValueError('pin/write_blocked')
            self.permit=None
            return
        return super().guard(stage,url,body)
    def send(self,operation,credentials):
        if (self.next_operation>=len(OPERATIONS) or OPERATIONS[self.next_operation]!=operation
                or not self.target or fingerprint(credentials)!=self.grant or self.permit is not None):
            raise ValueError('pin/write_blocked')
        if operation in ('add','remove'):
            path='/shelf/add' if operation=='add' else '/shelf/delete'
            body={'bookIds':[self.target]}
        else:
            path='/shelf/top'
            body={'albumIds':[],'archiveIds':[],'bookIds':[self.target],'isDel':int(operation=='unpin')}
        stage='pin_trial_'+operation;url=BASE+path
        self.permit=(stage,url,body);self.next_operation+=1;self.writes_attempted+=1
        try:
            response=self.request(stage,url,body,credentials)
            known=('succ','success','errcode','errCode','status')
            self.receipts.append({'stage':operation,'known_fields':[field for field in known if field in response],
                                  'other_fields_count':len(set(response)-set(known))})
            return response
        finally:self.permit=None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--v2',action='store_true',help='new one-use trial; allow book updateTime to change')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('--apply requires --saved-session')
    report=dict(result='OFFLINE_ONLY',account_data_posts_attempted=0,gateway_read_posts=0,
                credentials_written_to_files=False,no_automatic_replay=True)
    probe=Writer();web=KeyWeb();saved=credentials=key=None
    store=PinTrialStore(service=SERVICE_V2) if args.v2 else PinTrialStore()
    progress_digest=reading_fingerprint if args.v2 else progress_fingerprint
    try:
        if args.saved_session:
            from verify_native_thought_trial import other_pending
            if other_pending() or store.read()[0] is not None:raise ValueError('pin/pending_or_used')
            sessions=SessionStore();saved=sessions.load();owner=saved['vid']
            credentials=NativeSessionStore().load(owner);probe.grant=fingerprint(credentials)
            key_store=MacKeychain(service=SERVICE,account=ACCOUNT)
            key=validate(json.loads(key_store.load()),owner)['key'];web.vid=owner
            for name,value in saved['cookies'].items():web.set_cookie(name,value)
            web.verify_account();plans,progress_sha,skill_sha=prepare(probe,web,credentials,key,report,progress_digest=progress_digest)
            full_before=probe.request('pin_progress',BASE+'/book/getProgress?'+urlencode({'bookId':probe.target}),credentials=credentials)
            if progress_digest(full_before)!=progress_sha:raise ValueError('pin/progress_changed')
            full_before_sha=progress_fingerprint(full_before);full_before=None
            last_full_sha=None
            def current():
                if (SessionStore().load()['vid']!=owner or NativeSessionStore().load(owner)!=credentials
                        or hashlib.sha256(validate(json.loads(key_store.load()),owner)['key'].encode()).hexdigest()!=skill_sha):
                    raise ValueError('pin/session_changed')
                web.verify_account()
            def read():
                nonlocal last_full_sha
                snapshots={'native':probe.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials),
                           'web':web.request('shelf',WEB+'/web/shelf/sync')}
                report['gateway_read_posts']+=1;snapshots['gateway']=gateway(key)
                progress=probe.request('pin_progress',BASE+'/book/getProgress?'+urlencode({'bookId':probe.target}),credentials=credentials)
                last_full_sha=progress_fingerprint(progress)
                return snapshots,progress
            if args.apply:
                report.update(run(plans,progress_sha,skill_sha,store,current,read,
                                  lambda operation:probe.send(operation,credentials),progress_digest=progress_digest))
                report['full_progress_excluding_server_clock_unchanged']=last_full_sha==full_before_sha
                report['progress_projection']='exclude_server_clock_and_book_update_time' if args.v2 else 'exclude_server_clock'
            else:
                for _ in range(2):verify(observe(plans,progress_sha,current,read,progress_digest),plans,False)
                report.update(result='PREVIEW_VERIFIED',candidate_absent=True,baseline_channels=3)
            web.verify_account();save_refreshed_web_session(sessions,saved,web)
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if str(error) in {'pin/observation','pin/target_changed','pin/invalid_flag','pin/unstable',
                          'pin/receipt_unknown','pin/session_changed','pin/pending_or_used',
                          'native_shelf/presence','native_shelf/unrelated_change'}:
            report['detail']=str(error)
        try:
            state,_=store.read();report['intent_state']=state['phase'] if state else 'absent'
        except Exception:report['intent_state']='unknown'
    finally:
        report['account_data_posts_attempted']=probe.writes_attempted
        report['write_receipts']=probe.receipts
        report['native_stages']=[{k:r[k] for k in ('stage','status') if k in r} for r in probe.report['stages']]
        report['web_stages']=[{k:r[k] for k in ('stage','status') if k in r} for r in web.report['stages']]
        web.close();key=None;probe.payload=None;probe.target=None;probe.permit=None
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
