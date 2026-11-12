#!/usr/bin/env python3
"""Read-only shelf flags before native display integration; offline by default.

Only saved owner sessions, account verification and two shelf GETs are allowed.
No shelf, status, privacy, progress or annotation write exists. Private rows and
identities remain in memory/pipes; reports contain counts and field types only.
"""
import argparse
from collections import Counter
from datetime import datetime,timezone
import json
import subprocess

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore,StoreError
from verify_eink_login import BASE,NativeProbe,ProbeError
from verify_web_source_progress import BASE as WEB,WebSourceProbe,PreflightError
from verify_translation_preflight import save_refreshed_web_session
from web_shelf_contract import normalize
from shelf_flags_contract import FIELDS,flag


def project(shelf):
    normalized=normalize(shelf)
    return [dict(book_id=book['bookId'],**{name:flag(source,keys) for name,keys in FIELDS.items()})
            for source,book in zip(shelf['books'],normalized['books'])]


def summary(shelf,rows):
    result=dict(book_count=len(rows),states={},field_types={})
    result['independent_finished_field_differs']=sum(row.get('finishReading')!=row.get('finished')
        for row in shelf['books'] if 'finishReading' in row and 'finished' in row)
    result['archive_pin_field_types']=dict(Counter(type(row['isTop']).__name__ if 'isTop' in row else 'missing' for row in shelf.get('archive',[])))
    for name in FIELDS:
        result['states'][name]=dict(Counter('true' if row[name].get('value') is True else 'false' if row[name].get('value') is False
                                           else row[name]['reason'] for row in rows))
    for key in ('isTop','secret','finishReading','finished'):
        result['field_types'][key]=dict(Counter(type(row[key]).__name__ if key in row else 'missing' for row in shelf['books']))
    return result


class NativeFlagsProbe(NativeProbe):
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if stage!='shelf_flags' or url!=BASE+'/shelf/sync' or body is not None: raise ProbeError('flags_scope')
        return super().request(stage,url,body,credentials,timeout)


class WebFlagsProbe(WebSourceProbe):
    def guard(self,stage,url,body):
        if stage not in ('account','shelf') or body is not None: raise PreflightError('flags_scope')
        return super().guard(stage,url,body)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (args.lua_command and not args.saved_session) or (args.native_http and not args.lua_command): parser.error('Lua comparison requires --saved-session; --native-http also requires --lua-command')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes=0,credentials_written_to_files=False)
    if not args.saved_session:
        assert flag(dict(secret=False),'secret')==dict(value=False)
        print(json.dumps(report,indent=2));return 0
    web=WebFlagsProbe();native=NativeFlagsProbe();credentials=None;saved=None
    try:
        store=SessionStore();saved=store.load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
        web.vid=owner
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account()
        shelves=dict(native=native.request('shelf_flags',BASE+'/shelf/sync',credentials=credentials),web=web.request('shelf',WEB+'/web/shelf/sync'))
        expected={key:project(shelf) for key,shelf in shelves.items()}
        from verify_eink_shelf_write import state,snapshot
        for key,shelf in shelves.items():
            rows=snapshot(shelf)
            for item in expected[key]:
                if 'value' in item['finished'] and state(rows,item['book_id'],'finish')!=item['finished']['value']: raise ValueError('flags_status_preview_mismatch')
        report['shelf_write_preview_reading_state_matches']=True
        report['channels']={key:summary(shelves[key],rows) for key,rows in expected.items()}
        report['same_members_observed']={row['book_id'] for row in expected['native']}=={row['book_id'] for row in expected['web']}
        if args.lua_command:
            payload=dict(shelves=shelves)
            if args.native_http:payload.update(credentials=credentials,session=saved)
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>8*1024*1024: raise ValueError('flags_input_limit')
            child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            frame=b'\nWEREAD_FLAGS_RESULT='
            if child.returncode or len(child.stdout)>4*1024*1024 or child.stdout.count(frame)!=1: raise ValueError('flags_lua_failed')
            actual=json.loads(child.stdout.split(frame)[1])
            if actual.get('model')!=expected: raise ValueError('flags_lua_mismatch')
            report['lua_projection_matches']=True
            if args.native_http:
                if actual.get('native')!=expected or actual.get('requests')!=2: raise ValueError('flags_native_mismatch')
                report.update(native_https_projection_matches=True,native_read_requests=2)
        web.verify_account()
        report['refreshed_web_session_saved']=save_refreshed_web_session(store,saved,web)
        report.update(result='SHELF_FLAGS_READ_VERIFIED',same_owner_verified=True,native_stages=native.report['stages'],web_stages=web.report['stages'])
    except (StoreError,ProbeError,PreflightError):report.update(result='UNVERIFIED',reason='shelf_flags_read_failed',native_stages=native.report['stages'],web_stages=web.report['stages'])
    except Exception:report.update(result='UNVERIFIED',reason='shelf_flags_verification_failed')
    finally:
        web.close()
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='SHELF_FLAGS_READ_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
