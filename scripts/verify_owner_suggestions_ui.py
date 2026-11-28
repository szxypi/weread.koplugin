#!/usr/bin/env python3
"""Compare an owner suggestion menu and its selected search, read-only."""
import argparse
from datetime import datetime, timezone
import json
import subprocess
from urllib.parse import urlencode

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE, NativeProbe
from verify_native_discovery import page
from verify_search_suggestions import QUERY, project


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--ui-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.ui_command):parser.error('pair --saved-session and --ui-command')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes=0,
                authentication_posts=0,credentials_written_to_files=False,screenshots=0)
    if not args.saved_session:
        print(json.dumps(report));return 0
    saved=grant=None
    try:
        saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid']);probe=NativeProbe()
        response=probe.request('suggest',BASE+'/store/suggest?'+urlencode(dict(keyword=QUERY,count=10)),credentials=grant)
        words=project(response)
        if not words:raise ValueError('empty')
        response=probe.request('search',BASE+'/store/search?'+urlencode(dict(keyword=words[0],scope=10,count=20,maxIdx=0)),credentials=grant)
        expected=page('search',response)
        payload=json.dumps(dict(credentials=grant,keyword=QUERY,words=words,search=expected),ensure_ascii=False).encode()
        if len(payload)>1024*1024:raise ValueError('size')
        child=subprocess.run(args.ui_command,input=payload,capture_output=True,timeout=150)
        if len(child.stdout)>65536:raise ValueError('ui')
        result=json.loads(child.stdout);stage=result.get('stage') or {}
        report['ui_stage']={key:stage[key] for key in ('phase','failed_line','suggestions','books','expected_books','keyword_matches','requests','forbidden','screenshots')
                            if key in stage and (type(stage[key]) in (int,bool) or key=='phase' and stage[key] in ('init','search','complete'))}
        required=('native_host','menu_matches','search_matches','query_restored','workers_reaped','credential_audit')
        stage_fields={'result','phase','suggestions','books','expected_books','keyword_matches','requests','forbidden','screenshots',*required}
        if (not isinstance(result,dict) or set(result)!={'result','tmpfs_profile','profile_removed','stage','reason'}
                or not isinstance(stage,dict) or set(stage)!=stage_fields or result['reason']!='none'
                or type(result['tmpfs_profile']) is not bool or type(result['profile_removed']) is not bool
                or any(type(stage[key]) is not bool for key in (*required,'keyword_matches'))
                or any(type(stage[key]) is not int for key in ('suggestions','books','expected_books','requests','forbidden','screenshots'))
                or not stage['keyword_matches'] or stage['expected_books']!=len(expected['books'])
                or child.returncode or result.get('result')!='PASS' or not result.get('tmpfs_profile') or not result.get('profile_removed')
                or stage.get('result')!='PASS' or stage.get('phase')!='complete'
                or not all(stage.get(key) is True for key in required) or stage.get('suggestions')!=len(words)
                or stage.get('books')!=len(expected['books']) or stage.get('requests')!=2
                or stage.get('forbidden')!=0 or stage.get('screenshots')!=0):raise ValueError('ui')
        report.update(result='OWNER_NATIVE_SUGGESTIONS_UI_VERIFIED',suggestions=len(words),books=len(expected['books']),
                      python_read_requests=2,ui_read_requests=2,profile_removed=True,credentials_audited=True)
    except Exception:report['result']='UNVERIFIED'
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
