#!/usr/bin/env python3
"""Compare KOReader's two read-only baseline snapshots with independent reads."""
import argparse,json,resource,subprocess
from datetime import datetime,timezone
from secure_weread_session import SessionStore,COOKIE_NAMES
from secure_native_session import NativeSessionStore
from verify_translation_generation import Native,Web,snapshot
from verify_translation_preflight import save_refreshed_web_session
from verify_owner_reading import validate_cookies

FRAME=b'\nTRANSLATION_BASELINE='


def position_presence(value):
    if not isinstance(value,dict) or not isinstance(value.get('native'),dict) or not isinstance(value.get('web'),dict):
        raise ValueError('baseline_shape')
    kind=value.get('kind')
    if kind=='explicit-unrecorded-translation-baseline-v1':
        if value['native'].get('position_present') is not False or value['web'].get('position_present') is not False:
            raise ValueError('baseline_shape')
        return False
    if kind is not None or not isinstance(value.get('counts'),dict) or not all('point' in value[key] for key in ('native','web')):
        raise ValueError('baseline_shape')
    return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--shelf',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.saved_session!=bool(args.lua_command) or args.shelf and not args.saved_session:
        parser.error('saved session and private Lua command required together')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
        authentication_posts=0,translation_mode_requests=0,generation_requests=0,purchases=0,trial_activations=0,
        private_data_on_regular_disk=False,book_source='shelf' if args.shelf else 'public')
    saved=grant=api=web=None;phase='init'
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
            api=Native();api.inspect(grant,1,not args.shelf);sample=api.samples[0]
            web=Web();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();web.book_id=sample['book_id'];phase='before'
            before=snapshot(api,web,grant)
            cookies={c.name:c.value for c in web.cookies if c.name in COOKIE_NAMES
                and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'}
            validate_cookies(cookies,saved['vid'])
            payload=json.dumps(dict(credentials=grant,cookies=cookies,book_id=sample['book_id']),separators=(',',':')).encode()
            if len(payload)>65536:raise ValueError('input_limit')
            phase='native';child=subprocess.run(args.lua_command,input=payload,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=180)
            report['native_exit']=child.returncode;report['native_output_bytes']=len(child.stdout);report['native_frames']=child.stdout.count(FRAME)
            if child.returncode or len(child.stdout)>65536 or child.stdout.count(FRAME)!=1:raise ValueError('native_unavailable')
            result=json.loads(child.stdout.split(FRAME)[1])
            if not isinstance(result,dict) or result.get('ok') is not True:
                if isinstance(result,dict):
                    for key in ('native_reads','web_reads'):
                        if type(result.get(key)) is int and 0<=result[key]<=4:report[key]=result[key]
                    if result.get('reason') in ('unavailable','changed'):report['native_reason']=result['reason']
                raise ValueError('native_unavailable')
            if result.get('native_reads')!=4 or result.get('web_reads')!=4 or type(result.get('position_present')) is not bool:
                raise ValueError('native_shape')
            expected_present=position_presence(before)
            if result['position_present']!=expected_present:raise ValueError('native_presence')
            phase='after';after=snapshot(api,web,grant)
            if before!=after:raise ValueError('baseline_changed')
            web.verify_account();save_refreshed_web_session(SessionStore(),saved,web)
            if NativeSessionStore().load(saved['vid'])!=grant:raise ValueError('grant_changed')
            report.update(result='NATIVE_BASELINE_READONLY_VERIFIED',position_present=result['position_present'],
                native_reads=4,web_reads=4,independent_before_after_equal=True)
    except (Exception,KeyboardInterrupt):report.update(result='UNVERIFIED',stage=phase)
    finally:
        if api:
            api.samples=[];report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in api.report['stages']]
        if web:
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
