#!/usr/bin/env python3
"""Single-use native reading-time trials in one freshly imported TXT fixture."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import tempfile
import time

from cb_cloud_position import observed, state
from cb_fixture_native_time_intent import Intent as TimeIntent
from cb_fixture_web_time_evidence import Evidence
from cb_initial_fixture_intent import Intent as InitialIntent
from readtime_upload_model import local_zone
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from txt_coordinates import PlainSource
from verify_cb_fixture_web_time import NativeRead
from verify_cb_initial_fixture_ui_trial import target_matches, ui_command
from verify_cb_txt_fixture import Journal, Receipt
from verify_cb_txt_initial_fixture_ui_trial import execute as first_execute
from verify_cb_txt_manual_fixture_ui_trial import manual_command, run_manual
from verify_native_statistics import period
from verify_reader_progress import find_node
from verify_readtime_upload import counters, expected_statistics


def stores():
    def backend(suffix): return MacKeychain(service='org.codex.weread.cb-txt-time-native-ui-' + suffix + '-v1', account=ACCOUNT)
    def lock(suffix):
        path = Path(tempfile.gettempdir()) / ('codex-cb-txt-time-native-ui-' + suffix + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=backend('upload'), lock=lock('upload')), Receipt(backend=backend('receipt')),
            InitialIntent(backend=backend('initial'), lock=lock('initial')),
            TimeIntent(backend=backend('time'), lock=lock('time')),
            *(Evidence(backend=backend('baseline-' + str(i)), lock=lock('baseline-' + str(i))) for i in (1, 2)))


def run_time(command, payload, width, height, dpi):
    if not payload['armed']: return run_manual(command, payload, width, height, dpi)
    child = subprocess.run([*command, '--width', str(width), '--height', str(height), '--dpi', str(dpi)],
                           input=json.dumps(payload, ensure_ascii=False).encode(), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=780)
    if len(child.stdout) > 65536: raise ValueError('cb_txt_time_ui/result')
    expected = dict(result='PASS', profile_removed=True, installed_bytes_match=True, native_choice=True, actual_source=True,
                    upload_confirmed=True, fresh_process=True, pending_cleared=True, journal_cleared=True,
                    automatic_disabled=False, time_verified=True, writes=3, denied=0, credentials_not_persisted=True)
    if child.returncode or json.loads(child.stdout) != expected: raise ValueError('cb_txt_time_ui/result')
    return True


def read_pair(context, offset, summary, expected_counts):
    native, web = context['pair'](); chapters = context['sample']['chapters']; target = context['target']
    plan = dict(context['plan'], first=offset)
    if not all(target_matches(raw, plan, chapters, channel, summary)
               for raw, channel in ((native, 'native'), (web, 'web'))): raise ValueError('cb_txt_time_ui/target')
    if state(native, target, chapters, 'native')['raw_percent'] != state(web, target, chapters, 'web')['raw_percent']:
        raise ValueError('cb_txt_time_ui/percent')
    native_counts, web_counts = counters(native, target), counters(web, target)
    if native_counts != expected_counts or web_counts != expected_counts: raise ValueError('cb_txt_time_ui/counters')
    result = {channel: observed(raw, target, chapters, channel)
              for channel, raw in (('native', native), ('web', web))}
    updated = find_node(web, target).get('updateTime')
    if type(updated) is not int or updated < 0: raise ValueError('cb_txt_time_ui/updated')
    return result, updated


def time_trial(context, report, intent, evidences, command, api, *, runner=run_time, attest=manual_command,
               clock=time.time, sleep=time.sleep):
    plan, sample = context['plan'], context['sample']; model = PlainSource(sample['source'])
    before, after = plan['first'], plan['following']
    summaries = {offset: model.excerpt(offset)['text'] for offset in (before, after)}
    fingerprint = hashlib.sha256((context['source_hash'] + ':' + str(before) + ':' + str(after)).encode()).hexdigest()
    reservation = intent.reserve(context['owner'], context['target'], context['attempt'], fingerprint)
    previous = context['initial_observed']; report['time_stages'] = []
    for index, (width, height, dpi, stages) in enumerate((
            (600, 800, 167, ('first_enter', 'first_manual', 'first_time')),
            (1264, 1680, 300, ('second_enter', 'second_manual', 'second_time')))):
        if not context['authority']() or not context['shelf_current']() or context['attest']() != context['command'] or attest() != command: return False
        expected = dict(readingTime=index * 10, recordReadingTime=0, ttsTime=0)
        first, updated = read_pair(context, before, summaries[before], expected)
        if first != previous or read_pair(context, before, summaries[before], expected) != (first, updated): return False
        baseline_stats = api.stats()
        if counters(api.progress(), context['target']) != expected or api.stats() != baseline_stats: return False
        payload = dict(book=context['target'], chapter=plan['chapter'], chapter_idx=plan['index'], first_offset=before,
                       next_offset=after, expected_summary=summaries[after], timer_summary=summaries[before],
                       source=sample['source'], source_format='web_txt', chapters=context['chapters'], book_version=0,
                       owner=context['owner'], cookies=context['cookies'](), armed=False)
        if not runner(command, payload, width, height, dpi): return False
        if (not context['authority']() or not context['shelf_current']() or read_pair(context, before, summaries[before], expected) != (first, updated)
                or api.stats() != baseline_stats or context['attest']() != context['command'] or attest() != command): return False
        now = int(clock())
        if (now + 28800) // 86400 != (now + 60 + 28800) // 86400 or period('monthly', now)[0] != period('monthly', now + 60)[0]: return False
        candidates = []
        for zone in ('+08:00', local_zone()):
            for delta in (0, 1):
                candidate = expected_statistics(baseline_stats, now, 10, time_zone=zone)
                candidate['readDays'] = baseline_stats['readDays'] + delta; candidates.append(candidate)
        evidences[index].save(dict(schema=1, owner_sha256=hashlib.sha256(context['owner'].encode()).hexdigest(),
            book_sha256=hashlib.sha256(context['target'].encode()).hexdigest(), attempt=context['attempt'],
            baseline=dict(source=context['source_hash'], position=state(context['pair']()[1], context['target'], sample['chapters'], 'web'),
                          updated_at=updated, counters=expected, stats=baseline_stats, body=dict(seconds=10, kind='native_reader'))))
        permit = None
        for stage in stages:
            permit = intent.claim(reservation, stage)
            if not intent.verify(reservation, permit): return False
        if not context['authority']() or not intent.verify(reservation, permit): return False
        payload.update(cookies=context['cookies'](), armed=True, time=True)
        report['position_writes_uncertain'] = True
        if not runner(command, payload, width, height, dpi): return False
        report['position_writes_known'] += 3; report['position_writes_uncertain'] = False
        after_counts = dict(expected, readingTime=expected['readingTime'] + 10)
        matched = False
        for poll in range(4):
            if poll: sleep(min(2 * poll, 5))
            stats = api.stats()
            if stats not in [baseline_stats, *candidates]: return False
            try: current, _updated = read_pair(context, before, summaries[before], after_counts)
            except ValueError:
                if counters(api.progress(), context['target']) not in (expected, after_counts): return False
                continue
            if stats in candidates and counters(api.progress(), context['target']) == after_counts:
                matched = True; break
        if not matched or read_pair(context, before, summaries[before], after_counts)[0] != current: return False
        if not context['shelf_current']() or not context['authority'](): return False
        previous = current
        report['time_stages'].append(dict(screen='600x800' if index == 0 else '1264x1680', dry_run_blocked=True,
            native_choice=True, writes=3, book_seconds_delta=10, statistics_seconds_delta=10,
            dual_readback=True, offline_reopen=True))
    return len(report['time_stages']) == 2 and intent.verify(reservation, permit)


def execute(saved, session, native, grant, journal, receipt, initial, intent, evidence1, evidence2,
            first_command, second_command, *, apply=False, first=first_execute, api_factory=NativeRead,
            runner=run_time, attest=manual_command):
    if any(item.backend.load() is not None for item in (intent, evidence1, evidence2)):
        return dict(result='UNVERIFIED', phase='preflight', account_data_writes_known=0, position_writes_uncertain=False)
    def after(context, report):
        return time_trial(context, report, intent, (evidence1, evidence2), second_command, api_factory(grant, context['target']),
                          runner=runner, attest=attest)
    result = first(saved, session, native, grant, journal, receipt, initial, first_command, apply=apply, after_verified=after)
    if result.get('result') == 'CB_TXT_FIRST_NATIVE_UI_VERIFIED' and len(result.get('time_stages', [])) == 2:
        result['result'] = 'CB_TXT_NATIVE_TIME_VERIFIED'
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
    print(json.dumps(result)); return int(result['result'] not in ('READ_ONLY_PREVIEW', 'CB_TXT_NATIVE_TIME_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
