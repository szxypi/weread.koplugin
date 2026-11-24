#!/usr/bin/env python3
"""Read-only full native change-menu preflight against one owner shelf book."""
import argparse
import json
import re
import resource
import subprocess
from urllib.parse import urlencode

from cloud_group_contract import project
from ordinary_reading_status_trial import progress
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_reading_state import ReadOnlyProbe
from verify_eink_login import BASE, NativeProbe
from run_owner_reading_state_change_ui import FRAME, validate_stage


class RunnerError(ValueError):
    def __init__(self, phase=None, failed_line=None):
        super().__init__('started_preview/runner')
        self.phase = phase if phase in ('input', 'menu', 'preview', 'commit', 'audit') else 'runner'
        self.failed_line = failed_line if type(failed_line) is int and 0 <= failed_line <= 10000 else 0


class PreviewProbe(ReadOnlyProbe):
    def __init__(self, opener=None):
        super().__init__(opener);self.progress_reads = 0

    def progress(self, credentials, identity):
        if identity not in self.allowed or self.progress_reads >= 2:
            raise ValueError('started_preview/scope')
        self.progress_reads += 1
        return NativeProbe.request(self, 'progress', BASE + '/book/getProgress?' + urlencode({'bookId': identity}),
                                   credentials=credentials)


def decode_runner(output, code, armed=False):
    if len(output) > 65536 or output.count(FRAME) != 1:
        raise RunnerError()
    value = json.loads(output.split(FRAME)[1])
    if code:
        if isinstance(value, dict): raise RunnerError(value.get('phase'), value.get('failed_line'))
        raise RunnerError()
    if (not isinstance(value, dict) or set(value) != {'result', 'profile_removed', 'installed_bytes_match', 'stage'}
            or value['result'] != 'PASS' or value['profile_removed'] is not True or value['installed_bytes_match'] is not True):
        raise ValueError('started_preview/runner')
    validate_stage(value['stage'], armed)
    return value


def preview(credentials, probe, command, kind):
    shelf = probe.shelf(credentials); snapshot = project(shelf)
    pattern = r'[1-9][0-9]{0,19}' if kind == 'ordinary' else r'CB_[A-Za-z0-9]{1,64}'
    identities = sorted(str(row.get('bookId')) for row in shelf['books'] if re.fullmatch(pattern, str(row.get('bookId'))))
    if not identities or not command:
        raise ValueError('started_preview/target')
    identity = identities[0]; probe.allowed = {identity}
    raw = probe.progress(credentials, identity); before = progress(raw, identity)
    if before['flag'] not in (0, 1) or (before['start_time'] > 0) != (before['flag'] == 1):
        raise ValueError('started_preview/status')
    payload = dict(credentials=credentials, book_id=identity, shelf=shelf, progress=raw,
                   desired=before['flag'] == 0, armed=False)
    encoded = json.dumps(payload, ensure_ascii=False).encode()
    if len(encoded) > 2 * 1024 * 1024:
        raise ValueError('started_preview/size')
    child = subprocess.run(command, input=encoded, capture_output=True, timeout=180)
    ui = decode_runner(child.stdout, child.returncode)
    if project(probe.shelf(credentials)) != snapshot or progress(probe.progress(credentials, identity), identity) != before:
        raise ValueError('started_preview/changed')
    return dict(result='OWNER_NATIVE_PREVIEW_VERIFIED', kind=kind, ui=ui,
                account_data_writes=0, shelf_and_progress_unchanged=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--kind', choices=('ordinary', 'imported'))
    parser.add_argument('--ui-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.saved_session != bool(args.kind and args.ui_command):
        parser.error('saved session requires kind and UI command')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'account_data_writes': 0}));return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = credentials = None
    try:
        saved = SessionStore().load();credentials = NativeSessionStore().load(saved['vid'])
        report = preview(credentials, PreviewProbe(), args.ui_command, args.kind)
        if NativeSessionStore().load(saved['vid']) != credentials or SessionStore().load() != saved:
            raise ValueError('started_preview/session_changed')
    except RunnerError as error:
        report = {'result': 'UNVERIFIED', 'account_data_writes': 0, 'phase': error.phase, 'failed_line': error.failed_line}
    except Exception:
        report = {'result': 'UNVERIFIED', 'account_data_writes': 0}
    finally:
        if saved: saved.clear()
        if credentials: credentials.clear()
    print(json.dumps(report, indent=2));return int(report['result'] != 'OWNER_NATIVE_PREVIEW_VERIFIED')


if __name__ == '__main__':
    raise SystemExit(main())
