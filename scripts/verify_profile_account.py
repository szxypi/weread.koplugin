#!/usr/bin/env python3
"""Verify nickname projection with the saved session; offline by default."""
import argparse
import hashlib
import json
import subprocess

from secure_weread_session import COOKIE_NAMES, SessionStore
from verify_owner_statistics import NameProbe
from verify_translation_preflight import save_refreshed_web_session


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('pair --saved-session and --lua-command; put the command last')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authorization_posts=0,credentials_written_to_disk=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    probe=store=saved=None;stage='session'
    try:
        store=SessionStore();saved=store.load();probe=NameProbe();probe.vid=saved['vid']
        for key,value in saved['cookies'].items():probe.set_cookie(key,value)
        stage='python_preflight';probe.verify_account();expected=probe.name
        cookies={cookie.name:cookie.value for cookie in probe.cookies if cookie.name in COOKIE_NAMES
                 and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
        payload=json.dumps(dict(owner=probe.vid,cookies=cookies,name_hash=hashlib.sha256(expected.encode()).hexdigest())).encode()
        stage='native_read';child=subprocess.run(args.lua_command,input=payload,capture_output=True,timeout=45)
        if child.returncode or b'PROFILE_ACCOUNT_LIVE_OK\n' not in child.stdout:
            for label in ('ACCESS_FAILED','FETCH_FAILED','NAME_MISMATCH'):
                if ('PROFILE_ACCOUNT_'+label+'\n').encode() in child.stdout:report['native_result']=label
            raise ValueError('native_probe_failed')
        stage='python_readback';probe.verify_account()
        if probe.name!=expected:raise ValueError('name_changed')
        stage='session_save';report['web_cookie_rotation_saved']=save_refreshed_web_session(store,saved,probe)
        report.update(result='PASS',independent_owner_reads=2,native_owner_reads=1,same_name=True)
    except Exception:
        report.update(result='UNVERIFIED',reason='profile_account_verification_failed',stage=stage)
    finally:
        if probe:probe.close()
        if saved:saved.clear()
    print(json.dumps(report))
    return 0 if report['result']=='PASS' else 1


if __name__=='__main__':raise SystemExit(main())
