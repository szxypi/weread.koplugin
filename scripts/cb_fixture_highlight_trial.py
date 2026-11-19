"""One source-bound highlight on a freshly uploaded synthetic CB fixture.

This module has no network client. A caller must additionally bind every
dispatch to the owned upload receipt and the durable two-step reservation.
Unknown effects leave both the reservation and fixture in place.
"""
import hashlib
import re
from pathlib import Path
import tempfile

from annotation_experiment_model import digest
from highlight_trial_model import observe
from my_mark_span import project as span_project
from my_mark_target import project as target_project
from secure_highlight_trial import HighlightTrialStore
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain
from synthetic_upload_epub import TEXT
from verify_cb_progress import cb_id

PROTOCOL = 'cb-synthetic-highlight-create-remove-v1'
SERVICE = 'org.codex.weread.cb-fixture-highlight-v1'
FIELDS = {'protocol', 'owner_sha256', 'book_sha256', 'attempt', 'source_sha256',
          'baseline_sha256', 'request_sha256'}


def validate_plan(value):
    if not isinstance(value, dict) or set(value) != FIELDS or value['protocol'] != PROTOCOL:
        raise ValueError('cb_highlight/plan')
    if not isinstance(value['attempt'], str) or not re.fullmatch('[a-f0-9]{32}', value['attempt']):
        raise ValueError('cb_highlight/plan')
    for name in FIELDS - {'protocol', 'attempt'}:
        if not isinstance(value[name], str) or not re.fullmatch('[a-f0-9]{64}', value[name]):
            raise ValueError('cb_highlight/plan')
    return value


class Intent(HighlightTrialStore):
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service=SERVICE, account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-cb-fixture-highlight-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend, lock)

    def validate_plan(self, value):
        return validate_plan(value)


def prepare(owner, book, attempt, sample, version, baseline):
    if (not isinstance(owner, str) or not re.fullmatch('[1-9][0-9]{0,19}', owner)
            or not cb_id(book) or not isinstance(sample, dict) or sample.get('book_id') != book
            or sample.get('source_format') != 'web_xhtml' or not isinstance(sample.get('source'), str)
            or type(version) is not int or not 0 <= version <= 2147483647
            or not isinstance(baseline, dict) or set(baseline) != {'shelf', 'position', 'thoughts', 'marks'}
            or baseline['thoughts'] != {} or not isinstance(baseline['marks'], dict)
            or baseline['marks'].get('updated') != {} or baseline['marks'].get('chapters') != {}):
        raise ValueError('cb_highlight/scope')
    chapter = sample.get('chapter_uid'); raw = sample['source']
    if (not isinstance(chapter, str) or not re.fullmatch('[1-9][0-9]{0,9}', chapter)
            or int(chapter) > 2147483647 or raw.count(TEXT) != 1
            or not isinstance(sample.get('chapters'), list)
            or sum(str(row.get('chapterUid')) == chapter for row in sample['chapters'] if isinstance(row, dict)) != 1):
        raise ValueError('cb_highlight/source')
    source = raw.removeprefix('\ufeff'); start = source.index(TEXT); end = start + len(TEXT)
    row = dict(type=1, chapterUid=int(chapter), range=f'{start}-{end}', markText=TEXT)
    span = span_project(raw, book, chapter, row); target = target_project(raw, book, chapter, row)
    if span['first'] != target['chapter_offset'] or span['last'] <= span['first']:
        raise ValueError('cb_highlight/source')
    body = dict(bookId=book, chapterUid=int(chapter), bookVersion=version, type=1, style=1,
                colorStyle=0, range=row['range'], markText=TEXT)
    source_sha = hashlib.sha256(raw.encode()).hexdigest()
    if sample.get('source_raw_sha256') != source_sha:
        raise ValueError('cb_highlight/source')
    plan = validate_plan(dict(protocol=PROTOCOL, owner_sha256=digest(owner), book_sha256=digest(book),
                              attempt=attempt, source_sha256=source_sha, baseline_sha256=digest(baseline),
                              request_sha256=digest(body)))
    return plan, body


def execute(plan, body, baseline, intent, owned, read, send):
    """Dispatch at most two ordered writes; exceptions never retry or clean up."""
    validate_plan(plan)
    if digest(body) != plan['request_sha256'] or digest(baseline) != plan['baseline_sha256']:
        raise ValueError('cb_highlight/changed')
    if not owned() or intent.read()[0] is not None or read() != baseline or read() != baseline or not owned():
        raise ValueError('cb_highlight/preflight')
    receipt = intent.reserve(plan)
    if not owned() or not intent.owns(receipt, 'create_pending'):
        raise ValueError('cb_highlight/ownership')
    send('create_pending', body, receipt)
    if not owned() or not intent.owns(receipt, 'create_pending'):
        raise ValueError('cb_highlight/ownership')
    target = observe(baseline, read(), body)
    if not target:
        raise ValueError('cb_highlight/unconfirmed')
    receipt = intent.advance(receipt, 'created', target=target)
    if not owned() or observe(baseline, read(), body, target=target) != target:
        raise ValueError('cb_highlight/changed')
    receipt = intent.advance(receipt, 'delete_pending')
    if not owned() or not intent.owns(receipt, 'delete_pending'):
        raise ValueError('cb_highlight/ownership')
    send('delete_pending', {'bookmarkIds': [target['id']]}, receipt)
    if not owned() or not intent.owns(receipt, 'delete_pending'):
        raise ValueError('cb_highlight/ownership')
    observe(baseline, read(), body, deleted=True, target=target)
    receipt = intent.advance(receipt, 'verified')
    intent.finish(receipt)
    return {'result': 'PASS', 'writes': 2, 'original_records_restored': True}
