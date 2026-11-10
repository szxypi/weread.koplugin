#!/usr/bin/env python3
"""Read-only group membership validation. No login renewal or data write route."""
import argparse
from datetime import datetime, timezone
import json
import subprocess

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_groups_contract import project, summary
from verify_shelf_flags import NativeFlagsProbe, WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session
from web_shelf_contract import normalize


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session:parser.error('--lua-command requires --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,private_values_saved=False)
    web=native=saved=credentials=None
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid'])
            web=WebFlagsProbe();native=NativeFlagsProbe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            shelves=dict(native=native.request('shelf_flags','https://i.weread.qq.com/shelf/sync',credentials=credentials),
                         web=web.request('shelf','https://weread.qq.com/web/shelf/sync'))
            expected={key:project(shelf) for key,shelf in shelves.items()}
            report['channels']={key:summary(shelves[key],groups) for key,groups in expected.items()}
            if args.lua_command:
                payload={key:normalize(shelf) for key,shelf in shelves.items()}
                raw=json.dumps(payload,ensure_ascii=False).encode()
                if len(raw)>4*1024*1024:raise ValueError('group_input_limit')
                child=subprocess.run(args.lua_command,input=raw,capture_output=True,timeout=60)
                frame=b'\nWEREAD_GROUPS_RESULT='
                if child.returncode or len(child.stdout)>2*1024*1024 or child.stdout.count(frame)!=1:raise ValueError('group_lua_unverified')
                if json.loads(child.stdout.split(frame)[1])!=expected:raise ValueError('group_projection_mismatch')
                report['lua_projection_matches']=True
            web.verify_account()
            report['web_rotation_saved']=save_refreshed_web_session(store,saved,web)
            report.update(result='SHELF_GROUPS_READ_VERIFIED',same_owner_verified=True)
    except Exception:
        report.update(result='UNVERIFIED',reason='group_verification_failed')
    finally:
        for name,probe in (('web',web),('native',native)):
            if probe:
                report[name+'_stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in probe.report['stages']]
        if web:web.close()
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','SHELF_GROUPS_READ_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
