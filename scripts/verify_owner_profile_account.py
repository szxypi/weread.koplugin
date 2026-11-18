#!/usr/bin/env python3
"""Verify the real native nickname UI using a saved session; offline by default."""
import argparse
import json
import subprocess

from run_owner_profile_account import decode_stage
from secure_weread_session import COOKIE_NAMES, SessionStore
from verify_owner_statistics import NameProbe
from verify_translation_preflight import save_refreshed_web_session


def validate_runner(raw):
    if not isinstance(raw,bytes) or len(raw)>65536:raise ValueError('runner')
    value=json.loads(raw)
    if (not isinstance(value,dict) or set(value)!={'result','tmpfs_profile','profile_removed','stages','installed_bytes_match'}
            or value['result']!='PASS' or value['tmpfs_profile'] is not True or value['profile_removed'] is not True
            or value['installed_bytes_match'] is not True or not isinstance(value['stages'],list) or len(value['stages'])!=2):
        raise ValueError('runner')
    for mode,stage in zip(('live','reopen'),value['stages']):
        checked=decode_stage(b'\nWEREAD_PROFILE_ACCOUNT_UI='+json.dumps(stage).encode(),mode)
        if checked['result']!='PASS':raise ValueError('stage')
    return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--runner-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.runner_command):parser.error('pair --saved-session and --runner-command; put the command last')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authorization_posts=0,credentials_written_to_disk=False,screenshots=0)
    if not args.saved_session:
        print(json.dumps(report));return 0
    store=saved=probe=None;stage='session'
    try:
        store=SessionStore();saved=store.load();probe=NameProbe();probe.vid=saved['vid']
        for key,value in saved['cookies'].items():probe.set_cookie(key,value)
        stage='python_preflight';probe.verify_account();expected=probe.name
        cookies={cookie.name:cookie.value for cookie in probe.cookies if cookie.name in COOKIE_NAMES
                 and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
        raw=json.dumps(dict(owner=probe.vid,cookies=cookies,expected_name=expected),ensure_ascii=False).encode()
        if len(raw)>65536:raise ValueError('input')
        stage='native_ui';child=subprocess.run(args.runner_command,input=raw,capture_output=True,timeout=220)
        value=validate_runner(child.stdout)
        if child.returncode:raise ValueError('runner')
        stage='python_readback';probe.verify_account()
        if probe.name!=expected:raise ValueError('changed')
        stage='session_save';report['web_cookie_rotation_saved']=save_refreshed_web_session(store,saved,probe)
        report.update(result='PASS',independent_owner_reads=2,ui=value)
    except Exception:
        report.update(result='UNVERIFIED',reason='profile_account_ui_verification_failed',stage=stage)
    finally:
        if probe:probe.close()
        if saved:saved.clear()
    print(json.dumps(report))
    return 0 if report['result']=='PASS' else 1


if __name__=='__main__':raise SystemExit(main())
