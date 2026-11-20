#!/usr/bin/env python3
"""Read one public suggestion query; credentials and result words stay in pipes."""
import argparse
from datetime import datetime, timezone
import json
import subprocess
from urllib.parse import urlencode

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE, NativeProbe

QUERY = '科学'
MARKER = b'\nWEREAD_SUGGESTION_PROBE='


def project(data):
    if not isinstance(data, dict) or data.get('keyword') not in (None, QUERY):
        raise ValueError('suggest/response')
    if any(data.get(key, 0) not in (None, 0) for key in ('errcode', 'errCode')):
        raise ValueError('suggest/response')
    words = []
    for name in ('records', 'list', 'parts'):
        rows = data.get(name)
        if not isinstance(rows, list) or len(rows) > 100:
            raise ValueError('suggest/response')
        if name == 'parts':
            continue
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError('suggest/response')
            word = row.get('word')
            if word is None:
                continue
            if (not isinstance(word, str) or not 0 < len(word.encode('utf-8')) <= 512
                    or any(ord(ch) < 32 or ord(ch) == 127 for ch in word)):
                raise ValueError('suggest/response')
            if word not in words and len(words) < 10:
                words.append(word)
    return words


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.lua_command and not args.saved_session:
        parser.error('--lua-command requires --saved-session')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes=0, authentication_posts=0, credentials_written_to_files=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    saved = grant = None
    try:
        saved = SessionStore().load();grant = NativeSessionStore().load(saved['vid'])
        probe = NativeProbe()
        reference = probe.request('suggest', BASE+'/store/suggest?'+urlencode({'keyword': QUERY, 'count': 10}), credentials=grant)
        expected = project(reference)
        report.update(result='PYTHON_READ_VERIFIED', suggestions=len(expected), python_requests=1)
        if args.lua_command:
            payload = json.dumps(dict(credentials=grant, keyword=QUERY, reference=reference), ensure_ascii=False).encode()
            if len(payload)>1024*1024:raise ValueError('suggest/size')
            child = subprocess.run(args.lua_command, input=payload, capture_output=True, timeout=60)
            if child.returncode or child.stdout.count(MARKER)!=1 or len(child.stdout)>1024*1024:
                raise ValueError('suggest/native')
            value = json.loads(child.stdout.split(MARKER, 1)[1].splitlines()[0])
            if value != dict(result='PASS', projection_matches=True, native_https_matches=True,
                             count=len(expected), requests=1):
                raise ValueError('suggest/mismatch')
            report.update(result='REAL_NATIVE_SUGGESTIONS_READ_VERIFIED', native_requests=1,
                          python_lua_ordered_projection_matches=True)
    except Exception:
        report['result'] = 'UNVERIFIED'
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report, ensure_ascii=False))
    return int(report['result']=='UNVERIFIED')


if __name__ == '__main__':
    raise SystemExit(main())
