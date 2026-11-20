#!/usr/bin/env python3
"""Bounded real thought/reply UI verification; sensitive data stays in pipes."""
import argparse
import json
import resource
import subprocess
from urllib.parse import parse_qs, urlencode, urlsplit
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE, NativeProbe
from verify_native_annotations import AnnotationProbe

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class SingleProbe(NativeProbe):
    def __init__(self, review_id):
        super().__init__()
        self.review_id = review_id

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        parsed = urlsplit(url)
        query = parse_qs(parsed.query)
        if (stage != 'single' or body is not None or parsed.scheme != 'https' or parsed.netloc != 'i.weread.qq.com'
                or parsed.fragment or parsed.path != '/review/single' or query != {
                    'reviewId': [self.review_id], 'commentsCount': ['21'], 'commentsDirection': ['0'],
                    'likesCount': ['0'], 'synckey': ['0']}):
            raise ValueError('request_outside_scope')
        return super().request(stage, url, body, credentials, timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.saved_session and not args.lua_command:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'requests': 0}))
        return 0
    if not args.saved_session or not args.lua_command:
        parser.error('saved session and private Lua command are required together')
    probe, single, credentials = AnnotationProbe(), None, None
    report = {'result': 'UNVERIFIED', 'account_writes': 0}
    try:
        credentials = NativeSessionStore().load(SessionStore().load()['vid'])
        probe.inspect(credentials)
        target = None
        for sample in probe.samples:
            if sample.get('kind') != 'thoughts':
                continue
            rows = sample.get('source', {}).get('reviews', [])
            for row in rows:
                if not isinstance(row, dict) or not isinstance(row.get('pageReviews'), list):
                    continue
                for index, page in enumerate(row['pageReviews']):
                    if not isinstance(page, dict) or type(page.get('commentsCount')) is not int or page['commentsCount'] <= 0:
                        continue
                    item, rid = page.get('review'), page.get('reviewId')
                    if (isinstance(item, dict) and isinstance(rid, str) and rid and len(rid) <= 256
                            and item.get('reviewId') == rid and str(item.get('bookId')) == probe.book_id
                            and str(item.get('chapterUid')) == probe.chapter_uid and item.get('type') == 1
                            and item.get('isPrivate') in (None, 0)):
                        target = (sample, row, index + 1, rid)
                        break
                if target:
                    break
            if target:
                break
        if not target:
            raise ValueError('no_matching_thought_with_replies')
        sample, row, index, review_id = target
        single = SingleProbe(review_id)
        query = dict(reviewId=review_id, commentsCount=21, commentsDirection=0, likesCount=0, synckey=0)
        result = single.request('single', BASE + '/review/single?' + urlencode(query), credentials=credentials)
        comments = result.get('comments')
        if not isinstance(comments, list) or not 1 <= len(comments) <= 21:
            raise ValueError('no_reply_sample')
        source = dict(book_id=probe.book_id, chapter_uid=probe.chapter_uid, reviews=sample['source']['reviews'])
        payload = json.dumps(dict(credentials=credentials, book_id=probe.book_id, chapter_uid=probe.chapter_uid,
                                  source=source, range=row['range'], item_index=index, review_id=review_id,
                                  expected=result), ensure_ascii=False, separators=(',', ':')).encode()
        if len(payload) > 8 * 1024 * 1024:
            raise ValueError('input_too_large')
        child = subprocess.run(args.lua_command, input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
        marker = b'\nWEREAD_THOUGHT_REPLIES_UI='
        if child.returncode or len(child.stdout) > 65536 or child.stdout.count(marker) != 1:
            raise ValueError('lua_failed')
        outcome = json.loads(child.stdout.split(marker)[1])
        report.update(lua=outcome, independent_requests=len(probe.report['stages']) + len(single.report['stages']),
                      returned_replies=len(comments))
        if outcome.get('result') != 'PASS' or outcome.get('phase') != 'complete' or outcome.get('requests') != 1 \
                or outcome.get('painted') is not True or outcome.get('heartbeat') is not True:
            raise ValueError('comparison_failed')
        report['result'] = 'THOUGHT_REPLIES_UI_VERIFIED'
    except Exception as exc:
        stages = probe.report['stages'] + (single.report['stages'] if single else [])
        report.update(reason=type(exc).__name__, stages=[{'stage': s.get('stage'), 'status': s.get('status')} for s in stages])
    finally:
        if credentials:
            credentials.clear()
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['result'] == 'THOUGHT_REPLIES_UI_VERIFIED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
