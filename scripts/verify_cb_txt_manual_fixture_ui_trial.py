#!/usr/bin/env python3
"""Two native manual TXT position choices in one freshly imported fixture.

Offline by default. First position, import, and four later writes use separate
durable one-shot records. Each UI write sequence is preceded by a denied-write
rehearsal and followed by two-channel independent reads. Unknown effects leave
the fixture in place and never trigger a replay or automatic cleanup.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import tempfile

from cb_cloud_position import observed, state
from cb_existing_position_intent import Intent as ManualIntent
from cb_initial_fixture_intent import Intent as InitialIntent
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from txt_coordinates import PlainSource
from verify_cb_initial_fixture_ui_trial import target_matches, ui_command
from verify_cb_native_time_guarded_dry import trusted_command
from verify_cb_txt_fixture import Journal, Receipt
from verify_cb_txt_initial_fixture_ui_trial import execute as first_execute


def stores():
    def backend(suffix): return MacKeychain(service='org.codex.weread.cb-txt-manual-native-ui-' + suffix + '-v1', account=ACCOUNT)
    def lock(suffix):
        path = Path(tempfile.gettempdir()) / ('codex-cb-txt-manual-native-ui-' + suffix + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=backend('upload'), lock=lock('upload')),
            Receipt(backend=backend('receipt')),
            InitialIntent(backend=backend('initial'), lock=lock('initial')),
            ManualIntent(backend=backend('manual'), lock=lock('manual')))


def manual_command():
    trusted = trusted_command()
    return trusted[:6] + ['env', '-u', 'WEREAD_FIXTURE_SYNTHETIC', '-u', 'WEREAD_FIXTURE_MOCK_PORT',
        'SDL_VIDEODRIVER=dummy', 'LD_LIBRARY_PATH=/validation/runtime/lib/koreader/libs',
        'python3', '/source/scripts/run_cb_fixture_manual_ui.py', '--koreader', '/validation/runtime/lib/koreader',
        '--candidate', trusted[-1]]


def run_manual(command, payload, width, height, dpi):
    child = subprocess.run([*command, '--width', str(width), '--height', str(height), '--dpi', str(dpi)],
                           input=json.dumps(payload, ensure_ascii=False).encode(), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=780)
    if len(child.stdout) > 65536: raise ValueError('cb_txt_manual_ui/result')
    value = json.loads(child.stdout)
    expected = (dict(result='DRY_RUN', profile_removed=True, installed_bytes_match=True, native_choice=True,
                     write_blocked=True, writes=0, denied=1, credentials_not_persisted=True) if not payload['armed'] else
                dict(result='PASS', profile_removed=True, installed_bytes_match=True, native_choice=True, actual_source=True,
                     upload_confirmed=True, fresh_process=True, pending_cleared=True, journal_cleared=True,
                     automatic_disabled=True, writes=2, denied=0, credentials_not_persisted=True))
    if child.returncode or value != expected: raise ValueError('cb_txt_manual_ui/result')
    return True


def validate_pair(context, offset, summary):
    native, web = context['pair']()
    target = dict(context['plan'], first=offset)
    chapters = context['sample']['chapters']
    if not target_matches(native, target, chapters, 'native', summary) or not target_matches(web, target, chapters, 'web', summary):
        raise ValueError('cb_txt_manual_ui/target')
    if state(native, context['target'], chapters, 'native')['raw_percent'] != state(web, context['target'], chapters, 'web')['raw_percent']:
        raise ValueError('cb_txt_manual_ui/percent')
    values = {channel: observed(raw, context['target'], chapters, channel)
              for channel, raw in (('native', native), ('web', web))}
    counts = values['native']['counters']
    if any(not counts[key]['present'] or type(counts[key]['value']) is not int or counts[key]['value'] != 0
           for key in ('readingTime', 'recordReadingTime', 'ttsTime')):
        raise ValueError('cb_txt_manual_ui/counts')
    return values


def manual_trial(context, report, intent, command, *, runner=run_manual, attest=manual_command):
    plan, sample = context['plan'], context['sample']
    model = PlainSource(sample['source'])
    offsets = (plan['first'], plan['following'])
    summaries = {offset: model.excerpt(offset)['text'] for offset in offsets}
    fingerprint = hashlib.sha256((context['source_hash'] + ':' + str(offsets[0]) + ':' + str(offsets[1])).encode()).hexdigest()
    reservation = intent.reserve(context['owner'], context['target'], context['attempt'], fingerprint)
    previous = context['initial_observed']
    report['manual_stages'] = []
    for index, (before, after, width, height, dpi, stages) in enumerate((
            (offsets[0], offsets[1], 600, 800, 167, ('write_enter', 'write_same')),
            (offsets[1], offsets[0], 1264, 1680, 300, ('write_probe', 'write_restore')))):
        if not context['authority']() or not context['shelf_current']() or context['attest']() != context['command'] or attest() != command:
            return False
        first = validate_pair(context, before, summaries[before])
        if first != previous or validate_pair(context, before, summaries[before]) != first: return False
        payload = dict(book=context['target'], chapter=plan['chapter'], chapter_idx=plan['index'], first_offset=before,
                       next_offset=after, expected_summary=summaries[after], source=sample['source'], source_format='web_txt',
                       chapters=context['chapters'], book_version=0, owner=context['owner'], cookies=context['cookies'](), armed=False)
        if not runner(command, payload, width, height, dpi): return False
        if (not context['authority']() or not context['shelf_current']() or validate_pair(context, before, summaries[before]) != first
                or context['attest']() != context['command'] or attest() != command): return False
        permit = None
        for stage in stages:
            permit = intent.claim(reservation, stage)
            if not intent.verify(reservation, permit): return False
        if not context['authority']() or not intent.verify(reservation, permit): return False
        payload.update(cookies=context['cookies'](), armed=True)
        report['position_writes_uncertain'] = True
        if not runner(command, payload, width, height, dpi): return False
        report['position_writes_known'] += 2
        report['position_writes_uncertain'] = False
        current = validate_pair(context, after, summaries[after])
        if validate_pair(context, after, summaries[after]) != current or not context['shelf_current']() or not context['authority']():
            return False
        previous = current
        report['manual_stages'].append(dict(screen='600x800' if index == 0 else '1264x1680', dry_run_blocked=True,
                                            native_choice=True, writes=2, dual_readback=True, offline_reopen=True))
    return len(report['manual_stages']) == 2 and intent.verify(reservation, permit)


def execute(saved, session, native, grant, journal, receipt, initial, manual, first_command, second_command, *, apply=False,
            first=first_execute, runner=run_manual, attest=manual_command):
    if manual.backend.load() is not None:
        return dict(result='UNVERIFIED', phase='preflight', account_data_writes_known=0, position_writes_uncertain=False)
    def after(context, report): return manual_trial(context, report, manual, second_command, runner=runner, attest=attest)
    result = first(saved, session, native, grant, journal, receipt, initial, first_command, apply=apply, after_verified=after)
    if result.get('result') == 'CB_TXT_FIRST_NATIVE_UI_VERIFIED' and len(result.get('manual_stages', [])) == 2:
        result['result'] = 'CB_TXT_MANUAL_NATIVE_UI_VERIFIED'
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', account_data_writes_known=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        first_command, second_command = ui_command(), manual_command()
        session = SessionStore(); saved = session.load(); native = NativeSessionStore(); grant = native.load(saved['vid'])
        result = execute(saved, session, native, grant, *stores(), first_command, second_command, apply=args.apply)
    except Exception:
        result = dict(result='UNVERIFIED', phase='unknown' if args.apply else 'preflight',
                      account_data_writes_known=None if args.apply else 0, position_writes_uncertain=args.apply)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(result))
    return int(result['result'] not in ('READ_ONLY_PREVIEW', 'CB_TXT_MANUAL_NATIVE_UI_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
