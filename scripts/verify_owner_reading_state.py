#!/usr/bin/env python3
"""Memory-only owner comparison of native started-reading state; offline by default."""
import argparse
import json
import re
import resource
import subprocess

from cloud_group_contract import project
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_reading_state import ReadOnlyProbe
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import WebSourceProbe


def inspect(saved, credentials, probe, command):
    before = probe.shelf(credentials)
    initial = project(before)
    ordinary, imported = [], []
    for row in before['books']:
        value = row.get('bookId')
        if type(value) is int:
            if not 1 <= value <= 9007199254740991:
                continue
            value = str(value)
        if not isinstance(value, str):
            continue
        if re.fullmatch(r'[1-9][0-9]{0,19}', value):
            ordinary.append(value)
        elif re.fullmatch(r'CB_[A-Za-z0-9]{1,64}', value):
            imported.append(value)
    ids = sorted(ordinary)[:5] + sorted(imported)[:5]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError('owner_reading_state/scope')
    probe.allowed = set(ids)
    samples, expected = [], []
    for identity in ids:
        raw = probe.progress(credentials, identity)
        book = raw.get('book')
        flag = book.get('isStartReading') if isinstance(book, dict) else None
        if type(flag) is not int or flag not in (0, 1):
            raise ValueError('owner_reading_state/field')
        for node in (raw, book):
            for key, value in (('bookId', identity), ('vid', saved['vid']), ('userVid', saved['vid'])):
                if key in node and str(node[key]) != value:
                    raise ValueError('owner_reading_state/identity')
        samples.append({'book_id': identity, 'raw': raw})
        expected.append(flag == 1)
    encoded = json.dumps({'samples': samples, 'credentials': credentials}).encode()
    if len(encoded) > 2 * 1024 * 1024:
        raise ValueError('owner_reading_state/size')
    child = subprocess.run(command, input=encoded, capture_output=True, timeout=180)
    frame = b'\nWEREAD_OWNER_READING_STATE='
    if child.returncode or len(child.stdout) > 65536 or child.stdout.count(frame) != 1:
        raise ValueError('owner_reading_state/lua')
    result = json.loads(child.stdout.split(frame)[1])
    if result != {'model': expected, 'native': expected, 'requests': len(ids)}:
        raise ValueError('owner_reading_state/mismatch')
    if project(probe.shelf(credentials)) != initial:
        raise ValueError('owner_reading_state/shelf_changed')
    return dict(result='OWNER_READ_ONLY_VERIFIED', ordinary_books=min(len(ordinary), 5),
                imported_books=min(len(imported), 5), lua_projection_matches=True,
                native_https_readback_matches=True, account_data_writes=0, shelf_unchanged=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.saved_session != bool(args.lua_command):
        parser.error('saved session and Lua command are required together')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'account_data_writes': 0}))
        return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = credentials = web = None
    try:
        store = SessionStore()
        native_store = NativeSessionStore()
        saved = store.load()
        credentials = native_store.load(saved['vid'])
        web = WebSourceProbe()
        web.vid = saved['vid']
        for key, value in saved['cookies'].items():
            web.set_cookie(key, value)
        web.verify_account()
        report = inspect(saved, credentials, ReadOnlyProbe(), args.lua_command)
        if store.load() != saved or native_store.load(saved['vid']) != credentials:
            raise ValueError('owner_reading_state/session_changed')
        web.verify_account()
        report['refreshed_web_session_saved'] = save_refreshed_web_session(store, saved, web)
    except Exception:
        report = {'result': 'UNVERIFIED', 'account_data_writes': 0}
    finally:
        if web:
            web.close()
        if saved:
            saved.clear()
        if credentials:
            credentials.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] == 'OWNER_READ_ONLY_VERIFIED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
