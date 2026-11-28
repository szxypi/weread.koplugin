#!/usr/bin/env python3
"""One-use owner trial: add/remove by host; pin/unpin in native UI."""
import argparse
import hashlib
import json
from urllib.parse import urlencode
from native_cloud_pin_roundtrip import RoundtripFailure,run
from secure_native_cloud_pin_trial import NativeCloudPinTrialStore
from secure_native_session import NativeSessionStore
from secure_pin_trial import PinTrialStore,SERVICE_V3
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_eink_login import BASE
from verify_pin_gateway import SERVICE,KeyWeb,gateway,validate
from verify_pin_preflight import PinProbe,fingerprint,prepare,reading_fingerprint
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class HostWriter(PinProbe):
    def __init__(self):super().__init__();self.permit=None;self.next_operation=0;self.attempts=0;self.grant=None;self.receipts=[]
    def guard(self,stage,url,body):
        if body is not None:
            if self.permit!=(stage,url,body):raise ValueError('native_cloud_pin/write_blocked')
            self.permit=None;return
        return super().guard(stage,url,body)
    def send(self,operation,credentials):
        order=('add','remove')
        if (self.next_operation>=len(order) or order[self.next_operation]!=operation or not self.target
                or fingerprint(credentials)!=self.grant or self.permit is not None):raise ValueError('native_cloud_pin/write_blocked')
        stage='native_pin_host_'+operation;url=BASE+('/shelf/add' if operation=='add' else '/shelf/delete');body={'bookIds':[self.target]}
        self.permit=(stage,url,body);self.next_operation+=1;self.attempts+=1
        try:
            response=self.request(stage,url,body,credentials);known=('succ','success','errcode','errCode','status')
            self.receipts.append({'stage':operation,'known_fields':[field for field in known if field in response],
                                  'other_fields_count':len(set(response)-set(known))})
            return response
        finally:self.permit=None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--apply',action='store_true');mode.add_argument('--status',action='store_true')
    parser.add_argument('--native-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.apply and (not args.saved_session or not args.native_command):parser.error('--apply requires --saved-session and --native-command')
    if args.native_command and not args.apply:parser.error('--native-command requires --apply')
    report=dict(result='OFFLINE_ONLY',account_data_posts_attempted=0,authentication_posts=0,gateway_read_posts=0,
                credentials_written_to_files=False,no_automatic_replay=True)
    probe=HostWriter();web=KeyWeb();saved=credentials=key=None;outer=inner=None
    try:
        if args.saved_session or args.status:
            outer=PinTrialStore(service=SERVICE_V3);inner=NativeCloudPinTrialStore()
        if args.status:
            outer_state,_=outer.read();inner_state,_=inner.read()
            report.update(result='STATUS',outer_intent_state=outer_state['phase'] if outer_state else 'absent',
                          inner_intent_state=inner_state['phase'] if inner_state else 'absent')
        elif args.saved_session:
            from verify_native_thought_trial import other_pending
            if other_pending() or outer.read()[0] is not None or inner.read()[0] is not None:raise ValueError('native_cloud_pin/pending_or_used')
            sessions=SessionStore();saved=sessions.load();owner=saved['vid'];credentials=NativeSessionStore().load(owner);probe.grant=fingerprint(credentials)
            key_store=MacKeychain(service=SERVICE,account=ACCOUNT);key=validate(json.loads(key_store.load()),owner)['key'];web.vid=owner
            for name,value in saved['cookies'].items():web.set_cookie(name,value)
            web.verify_account();plans,reading_sha,skill_sha=prepare(probe,web,credentials,key,report,progress_digest=reading_fingerprint)
            def current():
                if (SessionStore().load()['vid']!=owner or NativeSessionStore().load(owner)!=credentials
                    or hashlib.sha256(validate(json.loads(key_store.load()),owner)['key'].encode()).hexdigest()!=skill_sha):
                    raise ValueError('native_cloud_pin/session')
                web.verify_account()
            def read():
                snapshots={'native':probe.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials),
                           'web':web.request('shelf',WEB+'/web/shelf/sync')}
                report['gateway_read_posts']+=1;snapshots['gateway']=gateway(key)
                progress=probe.request('pin_progress',BASE+'/book/getProgress?'+urlencode({'bookId':probe.target}),credentials=credentials)
                return snapshots,progress
            if args.apply:
                report.update(run(plans,reading_sha,skill_sha,outer,inner,current,read,lambda operation:probe.send(operation,credentials),
                                  args.native_command,credentials,probe.payload['expected_metadata']))
            else:
                from native_cloud_pin_roundtrip import stable
                stable(plans,reading_sha,current,read,False)
                report.update(result='READ_ONLY_PREFLIGHT_VERIFIED',candidate_absent=True,baseline_channels=3)
            web.verify_account();save_refreshed_web_session(sessions,saved,web)
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if isinstance(error,RoundtripFailure):report.update(failed_phase=error.phase,independent_steps=error.steps,native_ui=error.runner)
        elif str(error) in {'native_cloud_pin/pending_or_used','native_cloud_pin/session'}:report['detail']=str(error)
    finally:
        report['host_data_posts_attempted']=probe.attempts;report['host_write_receipts']=probe.receipts
        if outer and inner:
            try:
                state,_=outer.read();report['outer_intent_state']=state['phase'] if state else 'absent'
                state,_=inner.read();report['inner_intent_state']=state['phase'] if state else 'absent'
            except Exception:report['intent_state']='unknown'
        if args.apply:
            ui=report.get('native_ui');stage=ui.get('stage') if isinstance(ui,dict) else None
            native=stage.get('native_posts') if isinstance(stage,dict) else None
            if native is None and report.get('outer_intent_state') in ('absent','prepared','add_pending','add_acknowledged','add_verified'):
                native=0
            report['native_data_posts_attempted']=native
            report['account_data_posts_attempted']=probe.attempts+native if type(native) is int else None
        report['native_stages']=[{k:r[k] for k in ('stage','status') if k in r} for r in probe.report['stages']]
        report['web_stages']=[{k:r[k] for k in ('stage','status') if k in r} for r in web.report['stages']]
        web.close();key=None;probe.payload=None;probe.target=None;probe.permit=None
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
