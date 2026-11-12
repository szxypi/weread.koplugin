#!/usr/bin/env python3
"""Read-only prototype for exact chapter-coordinate upload confirmation.

The comparison proves a coordinate was observed, not that a write occurred.
An upload additionally needs its own explicit acknowledgement. Percentages
remain server metadata; this does not grant source-coordinate upload rights.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import subprocess

from secure_weread_session import SessionStore
from verify_reader_progress import ProgressError, identity, numeric, project, find_node
from verify_web_source_progress import BASE, WebSourceProbe, identifier, PreflightError
from verify_translation_preflight import save_refreshed_web_session

FRAME = b'\nWEREAD_PROGRESS_READBACK_RESULT='


def expected(book_id, position):
    key = identity(book_id)
    if (key is None or not isinstance(position, dict) or position.get('basis') is not None
            or position.get('upload_verified') is False
            or 'book_id' in position and identity(position['book_id']) != key):
        raise ProgressError('upload_position_invalid')
    uid = identity(position.get('chapter_uid'))
    if uid is None:
        raise ProgressError('upload_position_invalid')
    if any(type(position.get(k)) not in (int, float) for k in ('chapter_idx','chapter_offset','percent')):
        raise ProgressError('upload_position_invalid')
    return dict(book_id=key, chapter_uid=uid,
                chapter_idx=numeric(position.get('chapter_idx'), 1000000, integer=True),
                chapter_offset=numeric(position.get('chapter_offset'), 2147483647, integer=True),
                percent=math.floor(numeric(position.get('percent'), 100)))


def check(data, target):
    try:
        value = project(data, target['book_id'])
        node = find_node(data, target['book_id'])
        if (not any(k in node for k in ('chapterUid', 'chapterId', 'chapter_uid'))
                or not any(k in node for k in ('chapterIdx', 'chapterIndex', 'chapter_idx'))
                or not value['has_chapter_offset']):
            return dict(matches=False, reason='upload_readback_incomplete')
        matches = (identity(value['chapter_uid']) == target['chapter_uid']
                   and value['chapter_idx'] == target['chapter_idx']
                   and value['chapter_offset'] == target['chapter_offset'])
        return dict(matches=matches, reason='confirmed_coordinate' if matches else 'upload_readback_differs')
    except (ProgressError, KeyError, TypeError):
        return dict(matches=False, reason='upload_readback_invalid')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.lua_command and not args.saved_session:
        parser.error('--lua-command requires --saved-session and must be last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes_attempted=0, authentication_posts_attempted=0,
                  private_responses_saved=False, credentials_written_to_files=False)
    web = saved = payload = None
    try:
        if args.saved_session:
            store, web = SessionStore(), WebSourceProbe()
            saved = store.load(); web.vid = saved['vid']
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            web.verify_account()
            shelf = web.request('shelf', BASE + '/web/shelf/sync')
            rows = shelf.get('books') if isinstance(shelf, dict) else None
            if not isinstance(rows, list) or not 1 <= len(rows) <= 5000: raise ValueError()
            samples, positions, reads = [], 0, 0
            for row in rows:
                if reads >= 8: break
                try: key = identifier(row.get('bookId'))
                except (PreflightError, AttributeError): continue
                web.book_id = key
                raw = web.request('selection_progress', BASE + '/web/book/getProgress?bookId=' + key); reads += 1
                try: value = project(raw, key)
                except ProgressError as exc:
                    if str(exc) == 'progress_not_found': continue
                    raise
                if not value.get('chapter_uid') or not value['has_chapter_offset']: continue
                target = expected(key, value)
                if not check(raw, target)['matches']: continue
                positions += 1
                samples.append(dict(raw=raw, target=target))
                for field in ('chapter_idx', 'chapter_offset'):
                    changed = dict(target); changed[field] += 1
                    samples.append(dict(raw=raw, target=changed))
            if not positions: raise ValueError()
            web.verify_account()
            report['cookie_rotation_saved'] = save_refreshed_web_session(store, saved, web)
            if args.lua_command:
                payload = dict(samples=samples)
                encoded = json.dumps(payload).encode()
                if len(encoded) > 256*1024: raise ValueError()
                child = subprocess.run(args.lua_command, input=encoded, capture_output=True, timeout=60)
                if child.returncode or len(child.stdout) > 65536 or child.stdout.count(FRAME) != 1: raise ValueError()
                if json.loads(child.stdout.split(FRAME)[1]) != [check(sample['raw'],sample['target']) for sample in samples]: raise ValueError()
                report['lua_comparison_matches'] = True
            report.update(result='PROGRESS_READBACK_CONTRACT_VERIFIED', same_owner_verified=True,
                          positions=positions, comparisons=len(samples), comparison_basis='exact_chapter_uid_index_offset')
    except Exception:
        report.update(result='UNVERIFIED', reason='progress_readback_unverified')
    finally:
        if web:
            report['stages'] = [{k: row[k] for k in ('stage','status') if k in row} for row in web.report['stages']]
            web.close()
        for value in (saved, payload):
            if value: value.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','PROGRESS_READBACK_CONTRACT_VERIFIED') else 1


if __name__ == '__main__': raise SystemExit(main())
