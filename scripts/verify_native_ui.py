#!/usr/bin/env python3
"""Opt-in owner UI read probe. Credentials/results use captured memory pipes.

Default is offline. The Lua viewer uses anonymous credential descriptors,
volatile settings/SQLite and isolated profile directories; it never takes a
screenshot. It allows five fixed native GETs and no renewal or account writes.
Prepare a packaged candidate and fresh KO_HOME before invoking --lua-command.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore,StoreError
from verify_native_metadata import NativeMetadataProbe,MetadataError
from verify_eink_login import ProbeError

FRAME=b'\nWEREAD_NATIVE_UI_RESULT='
PHASES={'init','shelf','home','book','search','similar','recommend','audit','complete'}
BOOL_FIELDS={'anonymous_credentials','volatile_settings','volatile_sqlite','transport_guard_selftest','worker_heartbeat','metadata_projection_matches'}
COUNT_FIELDS={'shelf_books':5000,'shelf_groups':1000,'search_books':100,'similar_books':100,
              'recommend_books':100,'painted_views':7,'profile_files_audited':512,
              'screenshots':0,'forbidden_requests':1}


def validate_result(value):
    keys={'result','phase','request_counts','paged_shelf'}|BOOL_FIELDS|set(COUNT_FIELDS)
    if not isinstance(value,dict) or set(value)!=keys:raise ValueError('ui_result_schema')
    if (type(value['result']) is not str or value['result'] not in ('PASS','UNVERIFIED')
            or type(value['phase']) is not str or value['phase'] not in PHASES):raise ValueError('ui_result_status')
    if type(value['paged_shelf']) is not bool:raise ValueError('ui_result_flags')
    if any(type(value[key]) is not bool for key in BOOL_FIELDS):raise ValueError('ui_result_flags')
    if any(type(value[key]) is not int or not 0<=value[key]<=maximum for key,maximum in COUNT_FIELDS.items()):
        raise ValueError('ui_result_counts')
    counts=value['request_counts']
    if not isinstance(counts,list) or len(counts)!=5 or any(type(n) is not int or not 0<=n<=1 for n in counts):
        raise ValueError('ui_result_requests')
    if value['result']=='PASS' and (value['phase']!='complete' or not all(value[key] for key in BOOL_FIELDS)
            or counts!=[1]*5 or value['forbidden_requests'] or value['painted_views']!=6+int(value['paged_shelf'])
            or value['shelf_books']<1 or value['profile_files_audited']<1):raise ValueError('ui_result_incomplete')
    return value


def decode_result(raw):
    if not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('ui_result_frame')
    return validate_result(json.loads(raw.split(FRAME)[1]))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('use --saved-session and --lua-command together, with --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),
                credentials_written_to_persistent_files=False,private_results_written_to_persistent_files=False,screenshots=0,
                account_data_writes_attempted=0,authentication_posts_attempted=0)
    credentials=probe=None
    try:
        if args.saved_session:
            owner=SessionStore().load()['vid']
            credentials=NativeSessionStore().load(owner)
            probe=NativeMetadataProbe()
            baseline=probe.inspect(credentials,1)
            sample=probe.samples[0]
            payload=dict(credentials=credentials,book_id=sample['book_id'],expected_metadata=sample['expected'],
                         shelf_books=baseline['shelf_book_count'])
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>256*1024:raise ValueError('ui_input_limit')
            child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=120)
            value=decode_result(child.stdout)
            if b'[WeRead] forceRePaint failed:' in child.stdout+child.stderr:raise ValueError('ui_repaint_failed')
            report.update(ui=value,python_preflight_gets=2,same_owner_verified=True)
            if child.returncode or value['result']!='PASS':raise ValueError('ui_stage_unverified')
            report['result']='OWNER_NATIVE_UI_READ_VERIFIED'
    except (StoreError,ProbeError,MetadataError):report.update(result='UNVERIFIED',reason='owner_native_preflight_failed')
    except (ValueError,subprocess.TimeoutExpired):report.update(result='UNVERIFIED',reason='native_ui_unverified')
    except Exception:report.update(result='UNVERIFIED',reason='native_ui_probe_failed')
    finally:
        if credentials:credentials.clear()
        if probe:probe.samples.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','OWNER_NATIVE_UI_READ_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
