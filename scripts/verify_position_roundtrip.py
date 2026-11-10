#!/usr/bin/env python3
"""Prepare a bounded Web position experiment; offline and non-writing by default.

--saved-session prepares only a private, source-checked preview. Explicit
--apply --mode same|probe is for a separately owner-approved experiment: one
enter, one zero-time same-position report, optionally one adjacent source-point
report and a conditional restore. Never renew, retry POSTs or switch targets.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import time
import unicodedata

from fetch_weread_epub import make_read_params, sorted_query, web_app_id, weread_e, weread_sign
from secure_weread_session import SessionStore, StoreError
from verify_cloud_source_target import inspect
from verify_reader_context import ContextError, project as context_project
from verify_reader_progress import ProgressError, find_node, project as position_project
from verify_source_coordinates import CoordinateError, FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, identifier

WRITE_URL = BASE + '/web/book/read'
DEFAULT_TOKEN = '3c5c8717f3daf09iop3423zafeqoi'
WRITE_ORDER = ('write_enter', 'write_same', 'write_probe', 'write_restore')


class RoundTripError(ValueError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def same_position(first, second):
    return all(str(first[key]) == str(second[key]) if key in ('book_id', 'chapter_uid') else first[key] == second[key]
               for key in ('book_id', 'chapter_uid', 'chapter_idx', 'chapter_offset', 'raw_percent'))


def same_coordinate(first, second):
    return (str(first['book_id']) == str(second['book_id']) and str(first['chapter_uid']) == str(second['chapter_uid'])
            and first['chapter_offset'] == second['chapter_offset'])


def prepare_plan(book_id, raw, context, source):
    baseline = position_project(raw, book_id)
    node = find_node(raw, book_id)
    if not baseline['has_chapter_offset'] or context['book_id'] != book_id or not context.get('psvts'):
        raise RoundTripError('roundtrip_incomplete_context')
    if not any(key in node for key in ('chapterIdx', 'chapterIndex', 'chapter_idx')):
        raise RoundTripError('roundtrip_chapter_index_missing')
    embedded = position_project(context['progress'], book_id)
    if not same_position(baseline, embedded):
        raise RoundTripError('roundtrip_context_changed')
    if float(baseline['raw_percent']).is_integer():
        baseline['raw_percent'] = int(baseline['raw_percent'])
    model = FilteredSource(source)
    current = baseline['chapter_offset']
    current_text = model.anchor_at(current)
    summary_preserved = 'summary' in node and len(baseline['summary']) <= 20
    if not summary_preserved:
        baseline['summary'] = current_text[:20]
    target = None
    at = [i for i, offset in enumerate(model.starts) if offset == current]
    if len(at) == 1 and at[0] + 1 < len(model.starts):
        index = at[0]
        next_offset = model.starts[index + 1]
        if (next_offset - current == 1 and model.ends[index] == next_offset
                and all(not char.isspace() and unicodedata.category(char)[0] not in ('M', 'C')
                        for char in model.characters[index:index + 2])):
            try:
                text = model.anchor_at(next_offset)
                target = dict(baseline, chapter_offset=next_offset, summary=text[:20])
            except CoordinateError:
                pass
    pc = context.get('pclts')
    if pc is None or str(pc) in ('', '0'):
        pc = weread_e(int(time.time()))
    return dict(book_id=book_id, baseline=baseline, target=target, context=context,
                pclts=pc, same_position_summary_preserved=summary_preserved)


def payload(plan, stage):
    point = plan['target'] if stage == 'write_probe' else plan['baseline']
    if point is None:
        raise RoundTripError('roundtrip_probe_unavailable')
    value = make_read_params(book_id=plan['book_id'], chapter_uid=point['chapter_uid'],
                            chapter_idx=point['chapter_idx'], chapter_offset=point['chapter_offset'],
                            progress=point['raw_percent'], summary=point['summary'], psvts=plan['context']['psvts'],
                            pclts=plan['pclts'], token=plan['context'].get('token') or DEFAULT_TOKEN,
                            elapsed_seconds=0)
    if stage == 'write_enter':
        for key in ('rt', 'ts', 'rn', 'sg'):
            value.pop(key)
        value['s'] = weread_sign(sorted_query({k: v for k, v in value.items() if k != 's'}))
    return value


def validate_payload(plan, stage, value, *, observed_at=None):
    observed_at = int(time.time()) if observed_at is None else observed_at
    if type(observed_at) is not int or observed_at < 0:
        raise RoundTripError('roundtrip_payload_invalid')
    enter = stage == 'write_enter'
    keys = {'appId', 'b', 'c', 'ci', 'co', 'sm', 'pr', 'ct', 'ps', 'pc', 's'}
    if not enter:
        keys |= {'rt', 'ts', 'rn', 'sg'}
    point = plan['target'] if stage == 'write_probe' else plan['baseline']
    if (not isinstance(value, dict) or set(value) != keys or point is None or value['appId'] != web_app_id()
            or value['b'] != weread_e(plan['book_id']) or value['c'] != weread_e(point['chapter_uid'])
            or type(value['ci']) is not int or value['ci'] != point['chapter_idx']
            or type(value['co']) is not int or value['co'] != point['chapter_offset']
            or type(value['pr']) not in (int, float) or value['pr'] != point['raw_percent']
            or value['sm'] != point['summary'] or value['ps'] != plan['context']['psvts'] or value['pc'] != plan['pclts']
            or type(value['ct']) is not int or not 0 <= observed_at - value['ct'] <= 30
            or value['s'] != weread_sign(sorted_query({k: v for k, v in value.items() if k != 's'}))):
        raise RoundTripError('roundtrip_payload_invalid')
    if not enter:
        token = plan['context'].get('token') or DEFAULT_TOKEN
        if (type(value['rt']) is not int or value['rt'] != 0 or type(value['ts']) is not int
                or value['ts'] // 1000 != value['ct'] or type(value['rn']) is not int or not 0 <= value['rn'] <= 999
                or value['sg'] != hashlib.sha256(f"{value['ts']}{value['rn']}{token}".encode()).hexdigest()):
            raise RoundTripError('roundtrip_payload_invalid')
    if stage == 'write_probe' and (point['chapter_offset'] != plan['baseline']['chapter_offset'] + 1
                                  or str(point['chapter_uid']) != str(plan['baseline']['chapter_uid'])):
        raise RoundTripError('roundtrip_payload_invalid')
    return True


def acknowledged(value):
    if not isinstance(value, dict):
        return False
    if any(key in value and not (type(value[key]) in (int, float, str) and value[key] in (0, '0'))
           for key in ('errcode', 'errCode')):
        raise RoundTripError('roundtrip_write_rejected')
    if 'succ' in value and value['succ'] not in (True, 1, '1'):
        raise RoundTripError('roundtrip_write_rejected')
    return value.get('succ') in (True, 1, '1')


def verify_lua_payloads(plan, command):
    """Compare real-context payloads without giving the Lua process a client."""
    samples=[]
    for stage in WRITE_ORDER:
        if stage=='write_probe' and plan['target'] is None:continue
        expected=payload(plan,stage)
        validate_payload(plan,stage,expected)
        point=plan['target'] if stage=='write_probe' else plan['baseline']
        options=dict(book_id=plan['book_id'],chapter_uid=point['chapter_uid'],chapter_idx=point['chapter_idx'],
                     chapter_offset=point['chapter_offset'],progress=point['raw_percent'],summary=point['summary'],
                     psvts=plan['context']['psvts'],pclts=plan['pclts'],token=plan['context'].get('token') or DEFAULT_TOKEN,
                     now=expected['ct'],elapsed_seconds=0)
        if stage!='write_enter':options.update(ts=expected['ts'],rn=expected['rn'])
        samples.append(dict(stage=stage,options=options,expected=expected))
    encoded=json.dumps(dict(samples=samples),ensure_ascii=False).encode()
    if len(encoded)>65536:raise RoundTripError('roundtrip_model_input_limit')
    child=subprocess.run(command,input=encoded,capture_output=True,timeout=45)
    marker=b'\nWEREAD_POSITION_PAYLOAD_RESULT='
    if child.returncode or len(child.stdout)>65536 or child.stdout.count(marker)!=1:
        raise RoundTripError('roundtrip_lua_model_failed')
    result=json.loads(child.stdout.split(marker)[1])
    if (not isinstance(result,dict) or set(result)!={'stages','http_requests'} or type(result['http_requests']) is not int
            or result['http_requests']!=0 or not isinstance(result['stages'],list) or len(result['stages'])!=len(samples)):
        raise RoundTripError('roundtrip_lua_model_failed')
    for actual,sample in zip(result['stages'],samples):
        if (not isinstance(actual,dict) or set(actual)!={'stage','matches','mismatched_fields'}
                or actual['stage']!=sample['stage'] or actual['matches'] is not True or actual['mismatched_fields']!=[]):
            raise RoundTripError('roundtrip_lua_payload_mismatch')
    return dict(lua_payload_model_verified=True,lua_payloads_compared=len(samples),lua_http_requests=0)


class RoundTripProbe(WebSourceProbe):
    def __init__(self):
        super().__init__()
        self.plan, self.context, self.pending, self.mode = None, None, None, None
        self.writes = 0
        self.scope_vid = None
        self.last_observed = None

    def guard(self, stage, url, body):
        if stage in WRITE_ORDER:
            if (not self.authenticated or self.mode not in ('same', 'probe') or not self.plan or not self.pending
                    or self.mode == 'same' and stage not in WRITE_ORDER[:2]
                    or url != WRITE_URL or stage != self.pending[0] or self.writes > (2 if self.mode == 'same' else 4)
                    or self.vid != self.scope_vid or self.book_id != self.plan['book_id']
                    or not any(cookie.name == 'wr_vid' and cookie.value == self.scope_vid for cookie in self.cookies)
                    or canonical(body) != self.pending[1]):
                raise PreflightError('roundtrip_write_scope_rejected')
            validate_payload(self.plan, stage, body)
            return
        super().guard(stage, url, body)

    def request(self, stage, url, body=None, **options):
        result = super().request(stage, url, body, **options)
        if stage == 'reader':
            self.context = context_project(dict(book_id=self.book_id), result)
        return result

    def prepare(self, book_id=None):
        key = identifier(book_id) if book_id else self.select_shelf_book()
        _target, sample = inspect(self, key)
        self.plan = prepare_plan(key, sample['before'], self.context, sample['source'])
        self.scope_vid = self.vid
        for stage in WRITE_ORDER:
            if stage != 'write_probe' or self.plan['target']:
                value = payload(self.plan, stage)
                validate_payload(self.plan, stage, value)
                point = self.plan['target'] if stage == 'write_probe' else self.plan['baseline']
                if (value['b'] != weread_e(key) or value['c'] != weread_e(point['chapter_uid'])
                        or value['co'] != point['chapter_offset'] or value['pr'] != point['raw_percent']
                        or stage != 'write_enter' and value['rt'] != 0):
                    raise RoundTripError('roundtrip_payload_invalid')
        return self.plan

    def read_position(self):
        return position_project(self.request('progress_after', BASE + '/web/book/getProgress?bookId=' + self.plan['book_id']),
                                self.plan['book_id'])

    def send(self, stage):
        if self.mode not in ('same', 'probe') or self.writes >= (2 if self.mode == 'same' else 4):
            raise RoundTripError('roundtrip_write_scope_rejected')
        if stage != WRITE_ORDER[self.writes]:
            raise RoundTripError('roundtrip_write_order_rejected')
        value = payload(self.plan, stage)
        validate_payload(self.plan, stage, value)
        self.pending = (stage, canonical(value))
        try:
            self.guard(stage, WRITE_URL, value)
            self.writes += 1  # Consume a send slot even if transport/ack is uncertain.
            return self.request(stage, WRITE_URL, value)
        finally:
            self.pending = None

    def observe(self, expected, other, coordinate_only=False):
        for attempt in range(4):
            point = self.read_position()
            self.last_observed = point
            if (same_coordinate if coordinate_only else same_position)(point, expected):
                return True
            if not same_coordinate(point, other) and not same_coordinate(point, expected):
                raise RoundTripError('roundtrip_concurrent_position')
            if attempt < 3:
                time.sleep(.25)
        return False

    def execute(self, mode, report):
        if mode == 'probe' and not self.plan['target']:
            raise RoundTripError('roundtrip_probe_unavailable')
        if not same_position(self.read_position(), self.plan['baseline']):
            raise RoundTripError('roundtrip_baseline_changed')
        self.mode = mode
        acknowledged(self.send('write_enter'))
        if not same_position(self.read_position(), self.plan['baseline']):
            raise RoundTripError('roundtrip_enter_changed_position')
        report['same_position_acknowledged'] = acknowledged(self.send('write_same'))
        if not same_position(self.read_position(), self.plan['baseline']):
            raise RoundTripError('roundtrip_same_position_changed')
        if mode == 'same':
            report['restoration_verified'] = True
            return 'SAME_POSITION_ACKNOWLEDGED' if report['same_position_acknowledged'] else 'SAME_POSITION_UNCONFIRMED'
        baseline, target = self.plan['baseline'], self.plan['target']
        try:
            acknowledged(self.send('write_probe'))
            report['probe_observed'] = self.observe(target, baseline, coordinate_only=True)
            report['probe_metadata_unchanged'] = same_position(self.last_observed, target)
        finally:
            # Restore only the exact owned test point. An unrelated position
            # belongs to a concurrent reader; never replace it with our snapshot.
            point = self.read_position()
            if same_coordinate(point, target):
                acknowledged(self.send('write_restore'))
                report['restoration_verified'] = self.observe(baseline, target)
                report['original_coordinates_restored'] = same_coordinate(self.last_observed, baseline)
            elif same_coordinate(point, baseline):
                report['restoration_verified'] = same_position(point, baseline)
                report['original_coordinates_restored'] = True
            else:
                report['concurrent_position_detected'] = True
                raise RoundTripError('roundtrip_concurrent_position')
        return 'ONE_CHARACTER_ROUNDTRIP_VERIFIED' if report.get('probe_observed') and report.get('restoration_verified') else 'ROUNDTRIP_UNCONFIRMED'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-id')
    parser.add_argument('--expected-owner')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--mode', choices=('same', 'probe'))
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if (args.book_id or args.expected_owner or args.apply or args.mode or args.lua_command) and not args.saved_session:
        parser.error('online options require --saved-session')
    if args.apply and not (args.mode and args.book_id and args.expected_owner):
        parser.error('--apply requires explicit --mode, --book-id and --expected-owner')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(), account_data_writes_attempted=0,
                  credentials_written_to_files=False, private_source_saved=False, planned_elapsed_seconds=0,
                  restoration_verified=False, concurrent_position_detected=False)
    web = saved = None
    try:
        if args.saved_session:
            store, web = SessionStore(), RoundTripProbe()
            saved = store.load(); web.vid = saved['vid']
            if args.expected_owner and identifier(args.expected_owner) != web.vid:
                raise RoundTripError('roundtrip_owner_changed')
            for key, value in saved['cookies'].items():
                web.set_cookie(key, value)
            web.verify_account()
            try:
                plan = web.prepare(args.book_id)
            finally:
                web.verify_account()
                report['preflight_rotation_saved'] = save_refreshed_web_session(store, saved, web)
                saved = store.load()
            report.update(result='READONLY_ROUNDTRIP_PREVIEW_READY', same_book_context=True, stable_source_target=True,
                          probe_available=plan['target'] is not None, same_position_post_limit=2, probe_post_limit=4,
                          probe_utf16_delta=1 if plan['target'] else 0, no_post_retry=True, no_authentication_posts=True,
                          same_position_summary_preserved=plan['same_position_summary_preserved'],
                          recent_read_metadata_may_update=True)
            if args.lua_command:
                report.update(verify_lua_payloads(plan,args.lua_command))
            if args.apply:
                try:
                    report['result'] = web.execute(args.mode, report)
                finally:
                    web.verify_account()
                    report['final_rotation_saved'] = save_refreshed_web_session(store, saved, web)
    except RoundTripError as exc:
        report.update(result='UNVERIFIED', reason=str(exc))
    except (StoreError, PreflightError, ContextError, ProgressError, CoordinateError, ValueError, TypeError):
        report.update(result='UNVERIFIED', reason='position_roundtrip_unverified')
    except KeyboardInterrupt:
        report.update(result='UNVERIFIED', reason='position_roundtrip_interrupted')
    except Exception:
        report.update(result='UNVERIFIED', reason='position_roundtrip_failed')
    finally:
        if web:
            report['account_data_writes_attempted'] = web.writes
            report['stages'] = [{key: row[key] for key in ('stage', 'status') if key in row} for row in web.report['stages']]
            web.plan = web.context = web.pending = None
            web.close()
        if saved:
            saved.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'READONLY_ROUNDTRIP_PREVIEW_READY', 'SAME_POSITION_ACKNOWLEDGED', 'ONE_CHARACTER_ROUNDTRIP_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
