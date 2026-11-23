#!/usr/bin/env python3
"""Verify real shelf UI renewal after an independent HTTP 401; offline by default."""
import argparse,json,os,resource,secrets
from pathlib import Path
from native_shelf_renewal_broker import Broker,execute,shelf_projection
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_native_time_guarded_dry import trusted_command
from verify_eink_login import BASE,NativeProbe
from verify_native_direct_time_trial import web_cookies
from verify_native_thought_trial import other_pending
from verify_web_source_progress import BASE as WEB,WebSourceProbe

MARKER=Path(__file__).resolve().parent.parent.parent/'.validation'/'native-shelf-renewal-once-v1.json'


def command(armed):
    known=trusted_command();index=known.index('--candidate')
    if index+2!=len(known):raise ValueError('shelf_renewal/command')
    result=known[:6]+['python3','scripts/run_native_shelf_renewal_ui.py','--koreader',
        '/validation/runtime/lib/koreader','--candidate',known[index+1]]
    if armed:result.append('--armed')
    return result


def run(*,apply=False):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_posts=0,authentication_posts_claimed=0,
        keychain_new_grant_saved=False,private_data_in_report=False)
    web=saved=grant=None
    try:
        if type(apply) is not bool or MARKER.exists() or not MARKER.parent.is_dir() or other_pending():
            raise ValueError('shelf_renewal/pending')
        session=SessionStore();saved=session.load();store=NativeSessionStore();grant=store.load(saved['vid'])
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();cookies=web_cookies(web,saved['vid'])
        web_before=web.request('shelf',WEB+'/web/shelf/sync');baseline=shelf_projection(web_before);web_state=state_hash(web_before)
        if not baseline[0]:raise ValueError('shelf_renewal/shelf')
        def current():
            if session.load()!=saved or web_cookies(web,saved['vid'])!=cookies:raise ValueError('shelf_renewal/session')
        def verify_expiry(credentials):
            probe=NativeProbe()
            try:probe.request('shelf',BASE+'/shelf/sync',credentials=credentials)
            except Exception:return bool(probe.report['stages'] and probe.report['stages'][-1].get('status')==401)
            return False
        native_states=[]
        def verify_grant(credentials):
            probe=NativeProbe();raw=probe.request('shelf',BASE+'/shelf/sync',credentials=credentials)
            if not isinstance(raw,dict) or not isinstance(raw.get('books'),list):raise ValueError('shelf_renewal/shelf')
            return len(raw['books'])
        def observe(credentials):
            probe=NativeProbe();raw=probe.request('shelf',BASE+'/shelf/sync',credentials=credentials)
            value=shelf_projection(raw);fingerprint=state_hash(raw)
            if native_states and native_states[0]!=fingerprint:raise ValueError('shelf_renewal/changed')
            if not native_states:native_states.append(fingerprint)
            return value
        def claim():
            fd=os.open(MARKER,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,'w') as stream:
                json.dump(dict(state='claimed',authentication_post_limit=1,account_data_post_limit=0),stream)
                stream.flush();os.fsync(stream.fileno())
            directory=os.open(MARKER.parent,os.O_RDONLY)
            try:os.fsync(directory)
            finally:os.close(directory)
        current()
        if store.load(saved['vid'])!=grant or not verify_expiry(grant):raise ValueError('shelf_renewal/expiry')
        broker=Broker(grant,store,current=current,verify_expiry=verify_expiry,verify_grant=verify_grant,observe=observe,claim=claim)
        payload=dict(token=secrets.token_hex(16),armed=apply,credentials=grant,web_cookies=cookies,expected_count=len(baseline[0]))
        report['phase']='ui';execute(payload,command(apply),broker,report)
        if apply:
            current()
            web_after=web.request('shelf',WEB+'/web/shelf/sync')
            if (store.load(saved['vid'])!=broker.fresh or observe(broker.fresh)!=broker.snapshot or broker.snapshot!=baseline
                    or shelf_projection(web_after)!=baseline or state_hash(web_after)!=web_state):
                raise ValueError('shelf_renewal/changed')
        else:
            web_after=web.request('shelf',WEB+'/web/shelf/sync')
            if store.load(saved['vid'])!=grant or shelf_projection(web_after)!=baseline or state_hash(web_after)!=web_state:
                raise ValueError('shelf_renewal/changed')
        report['phase']='complete'
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and __import__('re').fullmatch('shelf_renewal/[a-z_]+',str(error)):
            report['reason']=str(error)
    finally:
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts_claimed=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report=run(apply=args.apply);print(json.dumps(report))
    return int(report['result'] not in ('NATIVE_SHELF_RENEWAL_VERIFIED','NATIVE_SHELF_RENEWAL_DRY_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
