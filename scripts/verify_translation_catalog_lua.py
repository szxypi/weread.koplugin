#!/usr/bin/env python3
"""Compare native Lua chapter admission with live read-only catalog evidence.

Account data and catalogue flow only through memory; the result reports counts.
No translation, purchase, trial, or account-changing requests are issued.
"""
import argparse,json,resource,subprocess
from datetime import datetime,timezone
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from verify_translation_preflight import TranslationProbe
from verify_eink_login import BASE
from verify_native_position_lua import equivalent


def compare(sample,member,command,runner=subprocess.run):
    raw=json.dumps(dict(raw=sample['source'],info=sample['info'],book_id=sample['book_id'],
        member={'isPaying':member['paying']}),ensure_ascii=False,separators=(',',':')).encode()
    if len(raw)>4*1024*1024:raise ValueError('input_limit')
    process=runner(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
    if process.returncode or len(process.stdout)>2*1024*1024:raise ValueError('child')
    actual=json.loads(process.stdout)
    model=sample['expected']
    keys=('uid','free_or_owned','wordCount','translateVersion','transWordCount','hasTranslated')
    expected=dict(member=member['paying'],format=model['format'],version=model['version'],
        rows=[{key:row[key] for key in keys if key in row} for row in model['chapters']])
    if not equivalent(expected,actual):raise ValueError('projection_mismatch')
    return len(expected['rows']),sum(row['free_or_owned'] for row in expected['rows'])


def verify_live_access(sample,credentials,command,runner=subprocess.run):
    candidates=[row for row in sample['expected']['chapters'] if row['free_or_owned'] and row.get('wordCount',0)>=200
        and 0<row['uid']<=2147483647 and row.get('translateVersion',0)<=2147483647]
    if not candidates:raise ValueError('no_readable_chapter')
    target=candidates[0]
    raw=json.dumps(dict(credentials=credentials,book_id=sample['book_id'],uid=target['uid'])).encode()
    if len(raw)>65536:raise ValueError('input_limit')
    process=runner(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=90)
    if len(process.stdout)>8192:raise ValueError('access_child')
    lines=[line for line in process.stdout.splitlines() if line.startswith(b'TRANSLATION_ACCESS=')]
    if len(lines)!=1:
        stages=[line.decode() for line in process.stdout.splitlines() if line.startswith(b'PROBE_')]
        tail=stages[-1] if stages and stages[-1] in {'PROBE_INPUT','PROBE_CLIENT','PROBE_BEFORE_NETWORK',*(f'PROBE_REQUEST_{n}' for n in range(1,7))} else 'none'
        raise ValueError('access_output_%d_%s' % (process.returncode,tail))
    actual=json.loads(lines[0].split(b'=',1)[1])
    if process.returncode:
        count=actual.get('requests')
        raise ValueError('access_child_'+str(count) if type(count) is int and 0<=count<=6 else 'access_child')
    expected=dict(ok=True,requests=6,version=sample['expected']['version'],translate_version=target.get('translateVersion',0))
    if not equivalent(expected,actual):raise ValueError('access_mismatch')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--live-access',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.live_access and not args.saved_session:parser.error('live access requires saved session')
    if args.saved_session!=bool(args.lua_command):parser.error('saved session requires a private Lua command')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
        translation_mode_requests=0,generation_requests=0,purchases=0,trial_activations=0,authentication_posts=0,
        private_data_on_regular_disk=False)
    api=credentials=saved=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid'])
            api=TranslationProbe();api.inspect(credentials,1,True)
            chapters,eligible=compare(api.samples[0],api.member,args.lua_command)
            if args.live_access:
                access_command=[part.replace('translation_generation_catalog_probe.lua','translation_generation_access_probe.lua') for part in args.lua_command]
                if access_command==args.lua_command:raise ValueError('probe_path')
                verify_live_access(api.samples[0],credentials,access_command)
                report['native_access_six_reads_verified']=True
            api.request('shelf',BASE+'/shelf/sync',credentials=credentials)
            report.update(result='NATIVE_CATALOG_REAL_PROJECTION_VERIFIED',chapters=chapters,
                explicitly_free_or_owned=eligible,final_shelf_read=True)
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        reason=str(error)
        if reason.startswith('access_output_') and len(reason)<60:report['reason']=reason
        elif reason in {'access_child','access_output','access_mismatch','no_readable_chapter','projection_mismatch',*(f'access_child_{n}' for n in range(7))}:report['reason']=reason
    finally:
        if api:
            api.samples=[]
            report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in api.report['stages']]
        for value in (credentials,saved):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
