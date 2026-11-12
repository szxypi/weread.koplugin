"""Private real-chapter preparation and strict public acceptance fields."""
import hashlib
import json
import time
from urllib.parse import urlencode

from verify_native_annotations import AnnotationProbe, BASE, batch_for, project
from annotation_source_quotes import SourceQuotes


FLAGS = {'source_data_matches', 'picker_and_matching', 'all_records_checked',
         'real_overlay_tap', 'popup_matches_cached_items', 'position_restored', 'source_quote_recheck_verified'}
COUNTS = {'underlines': 4096, 'thought_items': 122880, 'located': 4096, 'unmatched': 4096,
          'partial': 4096, 'native_underlines_requests': 1, 'native_thought_requests': 137,
          'native_denied_requests': 1024, 'failed_line': 10000}
COUNTS.update(dict.fromkeys(('unmatched_missing_quote', 'unmatched_quote_search_hits',
                            'unmatched_original_quote_differs', 'unmatched_original_search_hits',
                            'source_quote_recheck_located', 'source_quote_recheck_unmatched'), 4096))
COUNTS.update(dict.fromkeys(('source_quote_miss_overlap', 'source_quote_miss_equal_start',
                            'source_quote_miss_earlier_hit', 'source_quote_miss_outside_chapter',
                            'sealed_chapter_recheck_located'), 4096))


def digest(underlines, reviews):
    """Length-prefixed UTF-8; exclude mutable likes/heat and added source quotes."""
    parts = []
    def add(value):
        if value is None:
            value = ''
        if type(value) not in (str, int):
            raise ValueError('annotation_digest_scalar')
        raw = str(value).encode()
        parts.append(str(len(raw)).encode() + b':' + raw)
    for marker in sorted(row['range'] for row in underlines):
        add('underline'); add(marker)
    for row in sorted(reviews, key=lambda row: row['range']):
        add('range'); add(row['range']); add(len(row['pageReviews']))
        for page in row['pageReviews']:
            review = page.get('review', page)
            for value in (review.get('reviewId'), review.get('content'), review.get('abstract'), review.get('contextAbstract')):
                add(value)
    return hashlib.sha256(b''.join(parts)).hexdigest()


def prepare(payload, credentials, raw_source):
    probe = AnnotationProbe()
    probe.book_id, probe.chapter_uid = payload['book_id'], payload['chapter_uid']
    raw = probe.request('underlines', BASE + '/book/underlines?' + urlencode(dict(
        bookId=probe.book_id, chapterUid=probe.chapter_uid, synckey=0)), credentials=credentials)
    underlines = project('underlines', raw, probe.book_id, probe.chapter_uid)['underlines']
    if not underlines:
        raise ValueError('annotations_no_current_chapter_ranges')
    probe.samples.append(dict(kind='underlines', expected=dict(underlines=underlines)))
    reviews = []
    private_bytes = len(json.dumps(raw, ensure_ascii=False).encode())
    for start in range(0, len(underlines), 30):
        probe.batch = batch_for(underlines[start:start+30])
        time.sleep(1)
        raw = probe.request('thoughts', BASE + '/book/readreviews', dict(
            bookId=probe.book_id, chapterUid=int(probe.chapter_uid), cht2sMode='', reviews=probe.batch), credentials)
        private_bytes += len(json.dumps(raw, ensure_ascii=False).encode())
        if private_bytes > 5*1024*1024:
            raise ValueError('annotations_private_response_limit')
        rows = project('thoughts', raw, probe.book_id, probe.chapter_uid, probe.batch)
        reviews.extend(rows['reviews'])
        probe.samples.append(dict(kind='thoughts', expected=rows, requested=probe.batch))
    summary = probe.summary(payload['shelf_books'])
    if not summary['all_requested_range_pages_complete'] or not summary['thought_items']:
        raise ValueError('annotations_incomplete_page_scope')
    return dict(credentials=credentials, ranges=[row['range'] for row in underlines],
                source_quotes_digest=SourceQuotes(raw_source).digest([row['range'] for row in underlines]),
                digest=digest(underlines, reviews), underlines=len(underlines), thought_items=summary['thought_items'])


def validate(value, mode, complete):
    if not isinstance(value, dict) or set(value) != FLAGS | set(COUNTS):
        raise ValueError('annotations_report_schema')
    if (any(type(value[key]) is not bool for key in FLAGS)
            or any(type(value[key]) is not int or not 0 <= value[key] <= limit for key, limit in COUNTS.items())):
        raise ValueError('annotations_report_type')
    if mode == 'reopen' and (value['native_underlines_requests'] or value['native_thought_requests']):
        raise ValueError('annotations_offline_http')
    if complete and (not all(value[key] for key in FLAGS) or not value['underlines'] or not value['thought_items']
            or value['located']+value['unmatched'] != value['underlines'] or not value['located']
            or value['partial'] > value['located'] or value['native_denied_requests'] or value['failed_line']
            or mode == 'live' and (value['native_underlines_requests'] != 1
                or value['native_thought_requests'] != (value['underlines']+29)//30)):
        raise ValueError('annotations_incomplete')


def decode(raw, owner, *, mode=None, full_chapters=1):
    """Strip only the explicit addon, then reuse the unchanged reading contract."""
    from verify_owner_reading import FRAME, decode_envelope
    if full_chapters != 1 or not isinstance(raw, bytes) or len(raw) > 2*1024*1024 or raw.count(FRAME) != 1:
        raise ValueError('annotations_frame')
    envelope = json.loads(raw.split(FRAME)[1])
    report = envelope['report']
    stages = [report] if mode else report['stages']
    addons = []
    for index, stage in enumerate(stages):
        item = stage.pop('annotations')
        validate(item, mode or ('live', 'reopen')[index], stage.get('result') == 'PASS')
        addons.append(item)
    checked = decode_envelope(FRAME+json.dumps(envelope).encode(), owner, mode=mode)
    target = [checked['report']] if mode else checked['report']['stages']
    for stage, item in zip(target, addons):
        stage['annotations'] = item
    if mode is None and report.get('result') == 'PASS':
        for key in ('underlines', 'thought_items', 'located', 'unmatched', 'partial'):
            if addons[0][key] != addons[1][key]:
                raise ValueError('annotations_offline_changed')
    return checked
