"""Bounded read-only screening for an exactly restorable Web position.

Candidate identities and summaries are private and must remain in memory. This
screen does not check source, native progress, or authorize a network write.
"""
import re
from urllib.parse import urlencode

from verify_reader_progress import ProgressError, find_node, project
from verify_web_source_progress import BASE


def screen(web, *, limit=128, max_candidates=2):
    if type(limit) is not int or not 1 <= limit <= 128 or not web.authenticated:
        raise ValueError('ordinary_selection/scope')
    if type(max_candidates) is not int or not 1 <= max_candidates <= 8:
        raise ValueError('ordinary_selection/scope')
    shelf = web.request('shelf', BASE + '/web/shelf/sync')
    rows = shelf.get('books') if isinstance(shelf, dict) else None
    if not isinstance(rows, list) or len(rows) > 5000:
        raise ValueError('ordinary_selection/shelf')
    candidates, seen = [], set()
    counts = dict(checked=0, missing_position=0, missing_summary=0,
                  long_summary=0, incomplete_position=0, candidates=0)
    for row in rows:
        book = row.get('bookId') if isinstance(row, dict) else None
        if not isinstance(book, str) or not re.fullmatch(r'[1-9][0-9]{0,19}', book) or book in seen:
            continue
        seen.add(book)
        if counts['checked'] >= limit:
            break
        web.book_id = book
        raw = web.request('selection_progress', BASE + '/web/book/getProgress?' + urlencode(dict(bookId=book)))
        counts['checked'] += 1
        try:
            node, position = find_node(raw, book), project(raw, book)
        except ProgressError as exc:
            if str(exc) != 'progress_not_found':
                raise
            counts['missing_position'] += 1
            continue
        if 'summary' not in node:
            counts['missing_summary'] += 1
        elif len(node['summary']) > 20:
            counts['long_summary'] += 1
        elif (not position['has_chapter_offset'] or 'chapter_uid' not in position
              or not any(key in node for key in ('chapterIdx', 'chapterIndex', 'chapter_idx'))
              or not float(position['raw_percent']).is_integer()):
            counts['incomplete_position'] += 1
        else:
            candidates.append(book)
            counts['candidates'] += 1
            if len(candidates) >= max_candidates:
                break
    return candidates, counts, len(rows)
