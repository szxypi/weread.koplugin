#!/usr/bin/env python3
"""Strict reader-progress response prototype, offline unless explicitly opted in.

Only verified owner/shelf/progress GETs are used. Private responses and optional
Lua model comparisons stay in captured pipes. No progress/time/shelf writes.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import re
import subprocess

from secure_weread_session import SessionStore, StoreError
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, identifier

FRAME = b'\nWEREAD_READER_PROGRESS_RESULT='


class ProgressError(ValueError):
    pass


def identity(value):
    if type(value) in (int, float):
        if value < 0 or value > 9007199254740991 or not math.isfinite(value) or int(value) != value:
            return None
        value = str(int(value))
    if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,127}', value):
        return value
    return None


def numeric(value, maximum, *, integer=False):
    if type(value) not in (int, float, str) or isinstance(value, str) and len(value) > 64:
        raise ProgressError('progress_invalid')
    if isinstance(value, str) and not re.fullmatch(r'\s*[+-]?[0-9.]+(?:[eE][+-]?[0-9]+)?\s*', value, re.ASCII):
        raise ProgressError('progress_invalid')
    try:
        number = float(value)
    except (ValueError, OverflowError):
        raise ProgressError('progress_invalid') from None
    if not math.isfinite(number) or not 0 <= number <= maximum or integer and int(number) != number:
        raise ProgressError('progress_invalid')
    return int(number) if integer else number


def numbers(node, names, maximum, *, integer=False):
    values = [numeric(node[key], maximum, integer=integer) for key in names if key in node]
    if values and any(value != values[0] for value in values):
        raise ProgressError('progress_invalid')
    return values[0] if values else None


def find_node(data, book_id):
    candidates, visited = [], 0
    mismatch, rejected = False, False

    def visit(node, depth):
        nonlocal visited, mismatch, rejected
        if not isinstance(node, (dict, list)):
            return
        visited += 1
        if depth > 7 or visited > 512:
            raise ProgressError('progress_invalid')
        if isinstance(node, dict):
            if any(key in node and identity(node[key]) != book_id for key in ('bookId', 'book_id')):
                mismatch = True
                return
            if (any(key in node and not (type(node[key]) in (int, float, str) and node[key] in (0, '0')) for key in ('errcode', 'errCode'))
                    or 'succ' in node and not (node['succ'] is True or type(node['succ']) in (int, float, str) and node['succ'] in (1, '1'))):
                rejected = True
                return
            if any(key in node and not isinstance(node[key], (dict, list)) for key in ('progress', 'readingProgress', 'bookProgress')):
                candidates.append(node)
                return
            children = node.values()
        else:
            children = node
        for child in children:
            visit(child, depth + 1)

    visit(data, 0)
    if len(candidates) > 1:
        raise ProgressError('progress_ambiguous')
    if not candidates:
        raise ProgressError('progress_book_mismatch' if mismatch else 'progress_rejected' if rejected else 'progress_not_found')
    return candidates[0]


def project(data, book_id, source='web'):
    book_id = identity(book_id)
    if book_id is None:
        raise ProgressError('progress_book_mismatch')
    node = find_node(data, book_id)
    percent = numbers(node, ('progress', 'readingProgress', 'bookProgress'), 100)
    if percent is None:
        raise ProgressError('progress_invalid')
    offset = numbers(node, ('chapterOffset', 'chapterPos', 'offset', 'chapter_offset'), 2147483647, integer=True)
    index = numbers(node, ('chapterIdx', 'chapterIndex', 'chapter_idx'), 1000000, integer=True)
    updated = numbers(node, ('updateTime', 'updatedAt', 'update_time'), 9007199254740991, integer=True)
    summary = node.get('summary', node.get('chapterTitle', ''))
    if not isinstance(summary, str) or len(summary.encode()) > 16384 or '\0' in summary:
        raise ProgressError('progress_invalid')
    result = dict(book_id=book_id, percent=percent, raw_percent=percent, chapter_offset=offset or 0,
                  chapter_idx=index or 0, has_chapter_offset=offset is not None, updated_at=updated or 0,
                  summary=summary, source=source, position_basis='raw_percent')
    uids = [identity(node[key]) for key in ('chapterUid', 'chapterId', 'chapter_uid') if key in node]
    if uids:
        if None in uids or len(set(uids)) != 1:
            raise ProgressError('progress_invalid')
        result['chapter_uid'] = next(node[key] for key in ('chapterUid', 'chapterId', 'chapter_uid') if key in node)
    return result


def outcome(data, book_id):
    try:
        return dict(ok=True, position=project(data, book_id))
    except ProgressError as exc:
        return dict(ok=False, reason=str(exc))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--sample', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.lua_command and not args.saved_session:
        parser.error('--lua-command requires --saved-session and must be last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes_attempted=0, private_responses_saved=False, credentials_written_to_files=False)
    web = saved = payload = None
    try:
        if args.saved_session:
            store, web = SessionStore(), WebSourceProbe()
            saved = store.load(); web.vid = saved['vid']
            for key, value in saved['cookies'].items():
                web.set_cookie(key, value)
            web.verify_account()
            shelf = web.request('shelf', BASE + '/web/shelf/sync')
            rows = shelf.get('books') if isinstance(shelf, dict) else None
            if not isinstance(rows, list) or len(rows) > 5000:
                raise ProgressError('progress_invalid')
            samples = []
            for row in rows:
                try:
                    key = identifier(row.get('bookId'))
                except (PreflightError, AttributeError):
                    continue
                if key in {sample['book_id'] for sample in samples}:
                    continue
                web.book_id = key
                raw = web.request('selection_progress', BASE + '/web/book/getProgress?bookId=' + key)
                if len(json.dumps(raw).encode()) > 65536:
                    raise ProgressError('progress_invalid')
                result = outcome(raw, key)
                if not result['ok'] and result['reason'] != 'progress_not_found':
                    raise ProgressError('progress_invalid')
                samples.append(dict(book_id=key, raw=raw, expected=result))
                if len(samples) == args.sample:
                    break
            web.verify_account()
            report['cookie_rotation_saved'] = save_refreshed_web_session(store, saved, web)
            if not samples or not any(sample['expected']['ok'] for sample in samples):
                raise ProgressError('progress_not_found')
            if args.lua_command:
                payload = dict(samples=[{k: value for k, value in sample.items() if k != 'expected'} for sample in samples])
                child = subprocess.run(args.lua_command, input=json.dumps(payload).encode(), capture_output=True, timeout=60)
                if child.returncode or len(child.stdout) > 1024*1024 or child.stdout.count(FRAME) != 1:
                    raise ProgressError('progress_model_failed')
                result = json.loads(child.stdout.split(FRAME)[1])
                if result != [sample['expected'] for sample in samples]:
                    raise ProgressError('progress_model_failed')
                report['lua_projection_matches'] = True
            report.update(result='READER_PROGRESS_CONTRACT_VERIFIED', same_owner_verified=True,
                          shelf_books=len(rows), samples=len(samples), positions=sum(sample['expected']['ok'] for sample in samples))
    except (StoreError, PreflightError, ProgressError, ValueError, TypeError, subprocess.TimeoutExpired):
        report.update(result='UNVERIFIED', reason='reader_progress_unverified')
    except Exception:
        report.update(result='UNVERIFIED', reason='reader_progress_probe_failed')
    finally:
        if web:
            report['stages'] = [{key: row[key] for key in ('stage', 'status') if key in row} for row in web.report['stages']]
            web.close()
        for private in (saved, payload):
            if private:
                private.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'READER_PROGRESS_CONTRACT_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
