#!/usr/bin/env python3
"""Synthetic WeRead HTTP server and isolated KOReader launcher (stdlib only).

No upstream requests. Unknown routes fail with HTTP 501. This models the
contracts consumed by this plugin, not authentication or the real service.
"""

from __future__ import annotations

import argparse
import base64
import calendar
from collections import Counter, deque
import hashlib
from datetime import datetime, timedelta, timezone
import ipaddress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlsplit
import zipfile
import zlib

from fetch_weread_epub import swap_positions, weread_e

REPO = Path(__file__).resolve().parent.parent
BOOK_ID = "900001"
TITLES = ["启程", "雨中的小站", "山间来信", "海边的夜晚", "重逢", "归途"]
QUOTE = "窗外的风穿过树梢，带来远处山谷的回声。"
BOOKS = [dict(bookId=str(900001 + i), title=("山谷来信 · 离线测试" if i == 0 else f"合成读物 {i:02d}：用于长标题与分页验证"),
              author="测试作者", cover="https://weread.qq.com/mock/cover.png",
              category="文学", intro="自写合成内容，用于 KOReader 集成测试。", wordCount=12000,
              totalChapter=6, type=0, bookVersion=7, updateTime=1700000000 + i, readUpdateTime=1700000000 + i) for i in range(26)]
BOOKS[0].update(isTop=True,secret=1,finishReading=0,finished=1)
BOOKS[1].update(isTop=False,secret=0,finishReading=True,finished=0)
BOOKS[2].update(secret=2,finishReading=0,finished=1)
BOOKS[3].update(secret=False,finishReading=False,finished=1)
METADATA_BOOKS=[dict(BOOKS[0],bookId='CB_SyntheticMetadata',title='CB 编号合成详情')]
CB_READING_ID='CB_SyntheticResume'
CB_READING_BOOKS=[dict(BOOKS[0],bookId=CB_READING_ID,title='CB 合成缓存续读')]


def book_metadata(book):
    return dict(book,publisher="合成出版社",isbn="9780000000000",publishTime="2026-01-01",newRating=860,newRatingCount=12,
                translator="合成译者",categoryName="文学 · 合成",intro="<p>自写合成简介，用于原生控件验证。</p><p>第二段文字与 &amp; 符号。</p>")


CHAPTERS = [dict(chapterUid=i, chapterIdx=i, title=f"第{i}章 {title}", level=1,
                 wordCount=1800) for i, title in enumerate(TITLES, 1)]
CATEGORIES = dict(data=[
    dict(title="榜单", categories=[dict(CategoryId="rising", title="合成飙升榜", type=0)]),
    dict(title="分类", categories=[dict(CategoryId="100000", title="合成文学", type=0, sublist=[
        dict(CategoryId="100001", title="合成小说", type=0)])]),
])


def reading_statistics(mode, base_time=0):
    """Synthetic natural periods, using the API's fixed Beijing timezone."""
    zone = timezone(timedelta(hours=8))
    now = datetime.now(zone)
    seed = datetime.fromtimestamp(base_time, zone) if base_time else now
    day = seed.replace(hour=0, minute=0, second=0, microsecond=0)
    if mode == "monthly":
        start = day.replace(day=1)
        count = calendar.monthrange(start.year, start.month)[1]
    elif mode == "weekly":
        start, count = day - timedelta(days=day.weekday()), 7
    elif mode == "annually":
        start = day.replace(month=1, day=1)
        count = 366 if calendar.isleap(start.year) else 365
    elif mode == "overall":
        start = day.replace(year=now.year - 2, month=1, day=1)
        count = (day - start).days + 1
    else:
        raise ValueError("invalid statistics mode")
    daily, buckets = {}, {}
    for index in range(count):
        date = start + timedelta(days=index)
        if date.date() > now.date():
            break
        seconds = 0 if date.day % 7 == 0 else 300 + (date.day % 4) * 900
        daily[str(int(date.timestamp()))] = seconds
        bucket = date.replace(day=1) if mode == "annually" else date.replace(month=1, day=1) if mode == "overall" else date
        key = str(int(bucket.timestamp()))
        buckets[key] = buckets.get(key, 0) + seconds
    total = sum(daily.values())
    return dict(baseTime=0 if mode == "overall" else int(start.timestamp()), readTimes=buckets, dailyReadTimes=daily,
                totalReadTime=total, readDays=sum(value > 0 for value in daily.values()),
                dayAverageReadTime=total // max(1, len(daily)), readLongest=[dict(book=BOOKS[0], readTime=total)])


def chapter_html(uid):
    heading = CHAPTERS[uid - 1]["title"]
    paragraphs = [f"<p>{QUOTE}这是第{uid}章的第{i}段。我们沿着小路慢慢前行，"
                  "记下沿途的灯光、溪水和陌生人的问候。每一次翻页，都能看见新的文字。</p>"
                  for i in range(1, 19)]
    return ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            f'<head><title>{heading}</title></head><body><h1>{heading}</h1>'
            + "\n".join(paragraphs)
            + '<p>脚注验证<a href="#note1" epub:type="noteref">[1]</a></p>'
              '<aside id="note1" epub:type="footnote"><p>这是自写的原书脚注。</p></aside>'
              '<p><img src="https://weread.qq.com/mock/illustration.png" alt="合成插图"/></p>'
              '</body></html>')


def chapter_txt(uid):
    return '\ufeff' + CHAPTERS[uid-1]['title'] + '\r\n\r\n' + '\r\n\r\n'.join(
        f'这是第{uid}章的第{i}段。' + QUOTE + '我们沿着小路慢慢前行，记下沿途的灯光、溪水和陌生人的问候。'
        + '字面标签<tag>与实体&amp;和😀保持原样。\t  ' for i in range(1,25)) + '\r\n'


def annotation(uid):
    source = chapter_html(uid)
    start = source.index(QUOTE)
    return dict(range=f"{start}-{start + len(QUOTE)}", markText=QUOTE, count=12, metadata=None)


def native_annotations(uid, many=False):
    if not many: return [annotation(uid)]
    source = chapter_html(uid)
    rows = []
    for index in range(1, 19):
        text = QUOTE + f'这是第{uid}章的第{index}段。'
        start = source.index(text)
        rows.append(dict(range=f'{start}-{start+len(QUOTE)}', markText=QUOTE, count=12, metadata=None))
    for index in range(1, 14):
        text = f'这是第{uid}章的第{index}段。'; start = source.index(text)
        rows.append(dict(range=f'{start}-{start+len(text)}', markText=text, count=12, metadata=None))
    return rows


def shards(text, count=3):
    """Inverse of the existing decoder; real Client still checks MD5 and decodes."""
    encoded = base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")
    chars = list(encoded)
    positions = swap_positions(encoded)
    for i in range(0, len(positions), 2):
        for k in (0, 1):
            a, b = positions[i] + k, positions[i + 1] + k
            chars[a], chars[b] = chars[b], chars[a]
    body = "0" + "".join(chars)
    parts = [body[len(body) * i // count:len(body) * (i + 1) // count] for i in range(count)]
    return [hashlib.md5(part.encode()).hexdigest().upper() + part for part in parts]


def png():
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    pixels = b"".join(b"\0" + bytes((60 + y, 120, 90)) * 64 for y in range(96))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 64, 96, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def review(uid=1):
    return dict(reviewId=f"mock-review-{uid}", author={"nick": "合成读者"}, abstract=QUOTE,
                content=("这是一条合成想法，用来检查中文、换行与长文本翻页。🌿\n" * 18),
                createTime=1700000000, likesCount=7, commentsCount=2, star=90)


class MockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port=8765, log_path=None, bind="127.0.0.1"):
        address = ipaddress.IPv4Address(bind)
        if bind != "0.0.0.0" and not any(address in ipaddress.IPv4Network(network) for network in
                                          ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8")):
            raise ValueError("bind must be a LAN/loopback IPv4 address or 0.0.0.0")
        super().__init__((bind, port), Handler)
        self.lock = threading.Lock()
        self.log_path = log_path
        self.events = deque(maxlen=500)
        self.request_totals = Counter()
        self.active_requests = Counter()
        self.progress = {}
        self.control = dict(delay=0, match="", status=503, times=0, skip=0, native_annotation_many=False,
                            empty_shelf=False, empty_annotations=False, web_renewal_mode="plain", mp_article_version=1,
                            progress_response="plain", progress_confirmation="plain", progress_roundtrip_mode="plain", progress_offset_delta=0,
                            shelf_membership_mode='plain',finished_mark_mode='plain',selection_thought_mode='plain',selection_source_revision=1)
        self.progress_confirmation_book = None
        self.progress_confirmation_reads = 0
        self.roundtrip_seed = None
        self.roundtrip_posts = 0
        self.web_renewal_posts = 0
        self.content_format = 'epub'
        self.cb_reading = False
        self.shelf_removed = set()
        self.shelf_added = {}
        self.finish_fixture = False
        self.finished_marks = {}
        self.finished_release = threading.Event()
        self.finished_held = False
        self.selection_fixture=False
        self.selection_posts=0
        self.highlight_posts=0
        self.bookmark_posts=0
        self.selection_marks={'synthetic-existing-highlight':dict(bookmarkId='synthetic-existing-highlight',type=1,style=1,colorStyle=0,
            chapterUid=2,range='99-100',markText='不应改动的原有引用',createTime=1700000000)}
        self.selection_thoughts={'synthetic-existing-thought':dict(reviewId='synthetic-existing-thought',content='原有合成想法',
            abstract='不应改动的原有引用',chapterUid=2,chapterIdx=2,type=1,range='99-100',isPrivate=1,createTime=1700000000)}

    def record(self, event):
        with self.lock:
            key = (event["path"], event.get("api") if isinstance(event.get("api"), str) else "")
            if key not in self.request_totals and len(self.request_totals) >= 256:
                raise ValueError("mock request counter capacity exceeded")
            self.request_totals[key] += 1
            self.events.append(event)
            if self.log_path:
                with self.log_path.open("a") as out:
                    out.write(json.dumps(event, ensure_ascii=False) + "\n")

    def chapter_source(self,uid,revision=None):
        source=chapter_html(uid)
        if self.selection_fixture:
            extra='<p>选区专用开始😀&amp;标记<strong>跨标签文字</strong>结尾🙂</p>\n<p>第二段选区验证。</p>'
            if (self.control['selection_source_revision'] if revision is None else revision)==2:extra+='<p>合成来源已经更新。</p>'
            source=source.replace('</body>',extra+'</body>')
        return source

    def route(self, method, target, data):
        readable_books=BOOKS+(CB_READING_BOOKS if self.cb_reading else [])
        if self.finish_fixture:
            with self.lock:marks=self.finished_marks.copy()
            readable_books=[dict(book,secret=book.get('secret',0) if book.get('secret',0) in (0,1) else 0,
                                 **({'finishReading':marks[book['bookId']]} if book['bookId'] in marks else {})) for book in readable_books]
        url = urlsplit(target)
        path = url.path
        query = parse_qs(url.query)
        if method == "GET" and url.hostname == "mmbiz.qpic.cn" and path == "/synthetic-mp-bitmap.png" and not query:
            return 200, png()
        if method == "GET" and url.hostname == "open.weixin.qq.com" and path == "/connect/sdk/qrconnect":
            if query.get("appid") != ["wxab9b71ad2b90ff34"] or query.get("signature") != ["mock-native-ticket"]:
                raise ValueError("invalid native QR ticket")
            return 200, dict(errcode=0, uuid="mock-native-qr")
        if method == "GET" and url.hostname == "long.open.weixin.qq.com" and path == "/connect/l/qrconnect":
            if query.get("uuid") != ["mock-native-qr"]:
                raise ValueError("invalid native QR session")
            return 200, dict(wx_errcode=405, wx_code="mock-native-code")
        if url.hostname not in {"weread.qq.com", "i.weread.qq.com"}:
            raise LookupError("host is not implemented")
        api = data.get("api_name", "") if path == "/api/agent/gateway" else ""
        with self.lock:
            control = self.control.copy()
            matches = not control["match"] or control["match"] in (api or path)
            fail = matches and control["times"] != 0
            if fail and control['skip'] > 0:
                self.control['skip'] -= 1
                fail = False
            if fail and control["times"] > 0:
                self.control["times"] -= 1
        if matches:
            time.sleep(control["delay"])
        if fail:
            return control["status"], dict(errcode=-1, errmsg="Injected mock failure")

        book_id = str(data.get("bookId") or query.get("bookId", [BOOK_ID])[0])
        if path == "/web/login/renewal" and method == "POST":
            if data != {"rq": "%2Fweb%2Fbook%2Fread", "ql": False}:
                raise ValueError("invalid Web renewal request")
            self.web_renewal_posts += 1
            if control["web_renewal_mode"] == "reject": return 200, dict(succ=0)
            if control["web_renewal_mode"] == "empty": return 200, ""
            if control["web_renewal_mode"] == "foreign": return 200, dict(succ=1), {"Set-Cookie": "wr_vid=900099; Path=/"}
            if control["web_renewal_mode"] in {"rotate", "verify-fail"}:
                return 200, dict(succ=1), {"Set-Cookie": ["wr_skey=XXXrenewed-native; Path=/; Secure", "wr_rt=XXXrefresh-native; Path=/; Secure"],
                                          "x-wr-ticket": "synthetic-renewed-ticket", "x-wrpa-0": "synthetic-renewed-protection"}
            return 200, dict(succ=1)
        if path == "/web/mp/articles" and method == "GET":
            if not book_id.startswith("MP_WXS_"):
                raise ValueError("invalid MP account")
            if book_id in {"MP_WXS_900096", "MP_WXS_900095", "MP_WXS_900094", "MP_WXS_900093", "MP_WXS_900092", "MP_WXS_900091", "MP_WXS_900090", "MP_WXS_900089"}:
                if query != {"bookId": [book_id], "maxIdx": ["0"], "count": ["100"]}:
                    raise ValueError("invalid MP first-page query")
                if book_id == "MP_WXS_900095": return 200, dict(reviews=[])
                if book_id == "MP_WXS_900094": return 200, dict(unexpected=True)
                if book_id == "MP_WXS_900093": return 200, dict(reviews={})
                if book_id == "MP_WXS_900092": return 200, dict(errCode=-2012)
                if book_id == "MP_WXS_900091": return 200, dict(reviews=[dict(subReviews=[dict(reviewId="bad-date", createTime="invalid")])])
                if book_id == "MP_WXS_900090": return 200, " " * (4*1024*1024+1)
                ids = ["cache-fixture-a/b", "cache-fixture-a_b"]
                if book_id == "MP_WXS_900089": ids = [f"catalog-long-{index}" for index in range(100)]
                return 200, dict(errCode=0, reviews=[dict(subReviews=[dict(reviewId=identity, review=dict(
                    reviewId=identity, belongBookId=book_id, createTime=1700000000,
                    mpInfo=dict(title=("合成目录文章甲" if index == 0 else "合成目录文章乙") if len(ids) == 2 else f"合成目录第{index+1}篇 "+"目录文字"*100),
                    private="not retained")) for index, identity in enumerate(ids)])])
            return 200, dict(errCode=-2041, errMsg="Synthetic MP verification unavailable")
        if path == "/web/mp/content" and method == "GET":
            if query == {"reviewId": ["background-fixture"]}:
                version = control["mp_article_version"]
                return 200, f'<html><body><div id="js_content"><p>合成后台文章正文</p><p>合成版本 {version}</p><img src="https://mmbiz.qpic.cn/synthetic-mp-bitmap.png"/><img src="https://mmbiz.qpic.cn/synthetic-mp-bitmap.png"/></div><script>ignored()</script></body></html>'
            samples={"cache-fixture-a/b":"甲", "cache-fixture-a_b":"乙", "cache-fixture-c":"丙", "cache-fixture-d":"丁"}
            if set(query)!={"reviewId"} or len(query["reviewId"])!=1 or query["reviewId"][0] not in samples:
                raise ValueError("unknown synthetic MP article")
            return 200, '<html><head></head><body><div id="js_content"><p>合成公众号正文'+samples[query["reviewId"][0]]+'</p></div><script>ignored()</script></body></html>'
        if path == "/api/userInfo" and method == "GET" and query.get("userVid") == ["900000"]:
            if control["web_renewal_mode"] == "verify-fail" and self.web_renewal_posts:
                return 503, dict(errcode=-1)
            return 200, dict(vid=900000, name="Synthetic Web reader")
        if path == "/api/skills/apikeyGet" and method == "GET" and query == {"only_show": ["1"]}:
            return 200, {}
        if path == "/web/shelf/sync" and method == "GET":
            books = [{key: value for key, value in dict(book, version=800).items() if key != "bookVersion"}
                     for book in ([] if control["empty_shelf"] else readable_books)]
            return 200, dict(books=books, archive=[
                dict(archiveId=1, name="旅途", bookIds=[b["bookId"] for b in BOOKS[:15]]),
                dict(archiveId=2, name="待读", bookIds=[b["bookId"] for b in BOOKS[15:]]),
                dict(archiveId=3, name="空分组", bookIds=[])])
        if url.hostname == "i.weread.qq.com":
            if self.selection_fixture and path=='/book/bookmarklist' and method=='GET':
                if query!={'bookId':[BOOK_ID],'synckey':['0']}:raise ValueError('invalid selection mark query')
                with self.lock:rows=[row.copy() for row in self.selection_marks.values()]
                return 200,dict(bookId=BOOK_ID,updated=rows,chapters=[],hasMore=0)
            if self.selection_fixture and path in {'/book/addBookmark','/book/removeBookmark','/book/updateBookmark'} and method=='POST':
                ids=data.get('bookmarkIds')
                bookmark=path=='/book/addBookmark' and data.get('type')==0 or path=='/book/removeBookmark' and isinstance(ids,list) and any(
                    isinstance(key,str) and key.startswith('synthetic-new-bookmark-') for key in ids)
                if bookmark:
                    if query or self.bookmark_posts>=8:raise ValueError('invalid bookmark scope')
                    if path=='/book/addBookmark':
                        from bookmark_point import from_mark,project
                        required={'bookId','chapterUid','bookVersion','type','style','range','markText'}
                        if (set(data)!=required or data['bookId']!=BOOK_ID or any(type(data[k]) is not int for k in ('chapterUid','bookVersion','type','style'))
                                or data['chapterUid'] not in {row['chapterUid'] for row in CHAPTERS} or data['bookVersion']!=700
                                or data['type']!=0 or data['style']!=0):raise ValueError('invalid bookmark body')
                        raw=self.chapter_source(data['chapterUid']);point=from_mark(raw,BOOK_ID,str(data['chapterUid']),data)
                        if project(raw,point['chapter_offset'])['markText']!=data['markText']:raise ValueError('invalid bookmark preview')
                        identity='synthetic-new-bookmark-'+str(self.bookmark_posts+1)
                        # One supported server shape omits the point preview.
                        row=dict(bookmarkId=identity,type=0,style=0,chapterUid=data['chapterUid'],range=data['range'],createTime=1700000001)
                        with self.lock:
                            if control['selection_thought_mode']!='no_change':self.selection_marks[identity]=row
                        result=dict(bookmarkId=identity)
                    else:
                        ids=data.get('bookmarkIds')
                        if (set(data)!={'bookmarkIds'} or not isinstance(ids,list) or len(ids)!=1 or not isinstance(ids[0],str)
                                or not ids[0].startswith('synthetic-new-bookmark-') or ids[0] not in self.selection_marks):raise ValueError('invalid bookmark deletion')
                        with self.lock:
                            if control['selection_thought_mode']!='no_change':del self.selection_marks[ids[0]]
                        result=dict(succ=1)
                    with self.lock:self.bookmark_posts+=1
                    return 200,'' if control['selection_thought_mode']=='empty' else result
                # Two fresh initial-style roundtrips plus the original six
                # composite dispatches, six color updates and one unknown
                # color receipt. Specialized trial servers bound less.
                if query or self.highlight_posts>=17:raise ValueError('invalid highlight scope')
                if path=='/book/addBookmark':
                    required={'bookId','chapterUid','bookVersion','type','style','colorStyle','range','markText'}
                    if (set(data)!=required or data['bookId']!=BOOK_ID or any(type(data[k]) is not int for k in ('chapterUid','bookVersion','type','style','colorStyle'))
                            or data['chapterUid'] not in {row['chapterUid'] for row in CHAPTERS} or data['bookVersion']!=700
                            or data['type']!=1 or data['style'] not in (0,1,2) or data['colorStyle'] not in (0,1,2,3,4,5)):raise ValueError('invalid highlight body')
                    from annotation_source_quotes import SourceQuotes
                    if SourceQuotes(self.chapter_source(data['chapterUid']),body_only=True).quote(data['range']).strip()!=data['markText']:raise ValueError('invalid highlight source')
                    identity='synthetic-new-highlight-'+str(self.highlight_posts+1)
                    row={k:v for k,v in data.items() if k not in {'bookId','bookVersion'}};row.update(bookmarkId=identity,createTime=1700000001+self.highlight_posts)
                    with self.lock:
                        if control['selection_thought_mode']!='no_change':self.selection_marks[identity]=row
                    result=dict(bookmarkId=identity)
                elif path=='/book/updateBookmark':
                    identity=data.get('bookmarkId')
                    if (set(data)!={'bookmarkId','style','colorStyle'} or type(data['style']) is not int or data['style'] not in (0,1,2)
                            or type(data['colorStyle']) is not int or not 0<=data['colorStyle']<=5
                            or not isinstance(identity,str) or identity not in self.selection_marks or self.selection_marks[identity]['type']!=1):raise ValueError('invalid style update')
                    with self.lock:
                        if control['selection_thought_mode']!='no_change':self.selection_marks[identity].update(style=data['style'],colorStyle=data['colorStyle'])
                    result=dict(succ=1)
                else:
                    ids=data.get('bookmarkIds')
                    if (set(data)!={'bookmarkIds'} or not isinstance(ids,list) or len(ids)!=1
                            or not isinstance(ids[0],str) or not ids[0].startswith('synthetic-new-highlight-') or ids[0] not in self.selection_marks):raise ValueError('invalid highlight deletion')
                    with self.lock:
                        if control['selection_thought_mode']!='no_change':del self.selection_marks[ids[0]]
                    result=dict(succ=1)
                with self.lock:self.highlight_posts+=1
                return 200,'' if control['selection_thought_mode']=='empty' else result
            if self.selection_fixture and path=='/review/list' and method=='GET':
                if query!={'bookId':[BOOK_ID],'listType':['11'],'listMode':['0'],'mine':['1'],'synckey':['0'],'count':['20']}:
                    raise ValueError('invalid selection thought query')
                with self.lock:rows=[dict(review=dict(row,bookId=BOOK_ID,userVid=900000)) for row in self.selection_thoughts.values()]
                return 200,dict(reviews=rows,totalCount=len(rows),hasMore=0)
            if self.selection_fixture and path in {'/review/add','/review/useredit','/review/delete'} and method=='POST':
                if query or self.selection_posts>=12:raise ValueError('invalid selection thought scope')
                if path=='/review/add':
                    required={'bookId','chapterUid','bookVersion','type','range','abstract','isPrivate','content'}
                    if (set(data)!=required or data['bookId']!=BOOK_ID or type(data['chapterUid']) is not str or data['chapterUid'] not in {str(c['chapterUid']) for c in CHAPTERS}
                            or any(type(data[k]) is not int for k in ('bookVersion','type','isPrivate'))
                            or data['bookVersion']!=700 or data['type']!=1 or data['isPrivate']!=1
                            or not isinstance(data['abstract'],str) or not 0<len(data['abstract'].encode())<=4096
                            or not isinstance(data['content'],str) or not 0<len(data['content'].encode())<=131072):raise ValueError('invalid selected quote request')
                    from annotation_source_quotes import SourceQuotes
                    if SourceQuotes(self.chapter_source(int(data['chapterUid'])),body_only=True).quote(data['range']).strip()!=data['abstract']:
                        raise ValueError('selection quote does not address source')
                    identity='synthetic-selection-'+str(self.selection_posts+1)
                    row={k:data[k] for k in ('chapterUid','type','range','abstract','isPrivate','content')}
                    row.update(reviewId=identity,createTime=1700000001+self.selection_posts)
                    with self.lock:
                        if control['selection_thought_mode']!='no_change':self.selection_thoughts[identity]=row
                    result=dict(reviewId=identity)
                else:
                    if (set(data)!=({'reviewId','content'} if path=='/review/useredit' else {'reviewId'})
                            or not isinstance(data.get('reviewId'),str) or not data['reviewId'].startswith('synthetic-selection-')
                            or data['reviewId'] not in self.selection_thoughts
                            or path=='/review/useredit' and (not isinstance(data.get('content'),str) or not 0<len(data['content'].encode())<=131072)):
                        raise ValueError('selection original thought protected')
                    with self.lock:
                        if path=='/review/delete':del self.selection_thoughts[data['reviewId']]
                        else:self.selection_thoughts[data['reviewId']]['content']=data['content']
                    result=dict(succ=1)
                with self.lock:self.selection_posts+=1
                return 200,'' if control['selection_thought_mode']=='empty' else result
            if self.finish_fixture and path=='/book/getProgress' and method=='GET':
                if set(query)!={'bookId'} or query['bookId']!=[book_id] or not any(row['bookId']==book_id for row in BOOKS):
                    raise ValueError('invalid native finished-mark position query')
                return 200,self.get_progress(book_id)
            if self.finish_fixture and path=='/book/markstatus' and method=='POST':
                if (query or set(data)!={'bookId','auto','finishInfo','status','isCancel'} or type(data['bookId']) is not str
                        or not any(row['bookId']==data['bookId'] for row in BOOKS) or data['bookId'] in self.shelf_removed
                        or any(type(data[key]) is not int for key in ('auto','finishInfo','status','isCancel'))
                        or data['auto']!=0 or data['finishInfo']!=0 or data['status']!=4 or data['isCancel'] not in (0,1)):
                    raise ValueError('invalid single-book finished-mark request')
                with self.lock:
                    if control['finished_mark_mode']!='no_change':self.finished_marks[book_id]=1-data['isCancel']
                    if control['finished_mark_mode']=='position':self.control['progress_offset_delta']=1
                if control['finished_mark_mode']=='delayed_ack':time.sleep(6)
                if control['finished_mark_mode']=='hold':
                    with self.lock:self.finished_held=True
                    released=self.finished_release.wait(12)
                    with self.lock:self.finished_held=False
                    if not released:return 503,dict(errcode=-1)
                if control['finished_mark_mode']=='empty':return 200,''
                return 200,dict(status=1)
            if path in {'/shelf/add','/shelf/delete'} and method=='POST':
                if set(data)!={'bookIds'} or not isinstance(data['bookIds'],list) or len(data['bookIds'])!=1 or not re.fullmatch(r'[1-9][0-9]{0,19}',str(data['bookIds'][0])):
                    raise ValueError('invalid single-book membership request')
                identity=str(data['bookIds'][0])
                if path=='/shelf/add':
                    self.shelf_removed.discard(identity)
                    if not any(str(book['bookId'])==identity for book in BOOKS):
                        self.shelf_added[identity]=dict(bookId=identity,title='合成新增书籍',author='合成作者',version=700)
                else:
                    self.shelf_removed.add(identity);self.shelf_added.pop(identity,None)
                return 200,{} if control['shelf_membership_mode']=='noack' else dict(succ=1)
            if path == "/book/underlines" and method == "GET":
                if (set(query)!={"bookId","chapterUid","synckey"} or any(len(value)!=1 for value in query.values())
                        or query["synckey"]!=["0"] or not any(book["bookId"]==book_id for book in BOOKS)
                        or not query["chapterUid"][0].isdigit() or not 1<=int(query["chapterUid"][0])<=len(CHAPTERS)):
                    raise ValueError("invalid native underline query")
                uid=int(query["chapterUid"][0])
                return 200,dict(chapterUid=uid,underlines=[] if control["empty_annotations"] else native_annotations(uid,control['native_annotation_many']))
            if path == "/book/readreviews" and method == "POST":
                if (set(data)!={"bookId","chapterUid","cht2sMode","reviews"} or data["cht2sMode"]!=""
                        or not any(book["bookId"]==book_id for book in BOOKS) or type(data["chapterUid"]) is not int
                        or not 1<=data["chapterUid"]<=len(CHAPTERS)):
                    raise ValueError("invalid native thought query")
                from verify_native_annotations import validate_batch
                validate_batch(data["reviews"])
                uid=data["chapterUid"];marks={row['range'] for row in native_annotations(uid,control['native_annotation_many'])}
                return 200,dict(reviews=[] if control["empty_annotations"] else [
                    dict(range=item["range"],metadata=None,pageReviews=[dict(review=review(uid))])
                    for item in data["reviews"] if item["range"] in marks])
            if path == "/readdata/detail" and method == "GET":
                if set(query) != {"mode", "baseTime"} or any(len(v) != 1 for v in query.values()):
                    raise ValueError("invalid native statistics query")
                base = query["baseTime"][0]
                if not base.isascii() or not base.isdigit() or int(base) > 4102444800:
                    raise ValueError("invalid native statistics period")
                return 200, reading_statistics(query["mode"][0],int(base))
            if path == "/book/info" and method == "GET":
                if set(query) != {"bookId"} or len(query["bookId"]) != 1 or not any(b["bookId"] == book_id for b in readable_books+METADATA_BOOKS):
                    raise ValueError("invalid native metadata query")
                source = book_metadata(next(b for b in readable_books+METADATA_BOOKS if b["bookId"] == book_id))
                source["totalWords"] = source.pop("wordCount")
                source.pop("bookVersion", None)
                source.update(version=700,progress=99,chapterOffset=321,finishReading=1)
                return 200, source
            if path in {"/store/search", "/book/recommend", "/book/detailinfo"} and method == "GET":
                required = {"maxIdx", "count"}
                if path == "/store/search":required |= {"keyword", "scope"}
                if path == "/book/detailinfo":required |= {"bookId", "listtypes", "synckey"}
                optional = {"sessionId"} if path == "/book/detailinfo" else set()
                if not required <= set(query) <= required | optional or any(len(v) != 1 for v in query.values()):
                    raise ValueError("invalid native discovery query")
                start_text = query["maxIdx"][0]
                if not start_text.isascii() or not start_text.isdigit() or int(start_text) > 2147483647 or query["count"] != ["20"]:
                    raise ValueError("invalid native discovery cursor/count")
                start = int(start_text)
                if path == "/store/search" and query["scope"] != ["10"]:raise ValueError("invalid native search scope")
                if path == "/book/detailinfo":
                    session = "mock-native-similar-" + book_id
                    if (query["listtypes"] != ["2"] or query["synckey"] != ["0"] or not any(b["bookId"] == book_id for b in BOOKS)
                            or (start > 0 and query.get("sessionId") != [session]) or query.get("sessionId") not in (None, [session])):
                        raise ValueError("invalid native similar session/seed")
                    candidates = [b for b in BOOKS if b["bookId"] != book_id]
                    batch = candidates[start:start + 20]
                    return 200, dict(booksimilar=dict(sessionId=session,hasMore=start+len(batch)<len(candidates),
                        books=[dict(idx=start+i+1,book=dict(bookInfo=b)) for i,b in enumerate(batch)]))
                keyword = query.get("keyword", [""])[0]
                candidates = [b for b in BOOKS if keyword in b["title"] or keyword in b["author"]]
                batch = candidates[start:start+20]
                return 200, dict(books=[dict(bookInfo=b,searchIdx=start+i+1) for i,b in enumerate(batch)],hasMore=start+len(batch)<len(candidates))
            if path == "/wxticket" and method == "GET":
                return 200, dict(signature="mock-native-ticket", timeStamp=1700000000, expires_in=180)
            if path == "/login" and method == "POST":
                device, install = str(data.get("deviceId", "")), str(data.get("installId", ""))
                timestamp, random = data.get("timestamp"), data.get("random")
                if (len(device) != 32 or not device.startswith("eink334691225") or not device[13:].isdigit()
                        or type(timestamp) not in (int, float) or not 1 <= timestamp <= 4102444800000
                        or timestamp != int(timestamp) or type(random) is not int or not 1 <= random <= 999):
                    raise ValueError("invalid native login fields")
                expected = hashlib.sha256(f"{int(timestamp)}{device}{random}".encode()).hexdigest()
                if data.get("signature") != expected:
                    raise ValueError("invalid native login signature")
                if "refreshToken" in data:
                    if (data["refreshToken"] != "mock-native-refresh" or "code" in data or "installId" in data
                            or data.get("inBackground") != 0 or data.get("kickType") != 1 or data.get("refCgi") != ""):
                        raise ValueError("invalid native renewal fields")
                    return 200, dict(vid=900000, accessToken="mock-native-access")
                if (data.get("code") != "mock-native-code" or len(install) != 32 or not install.startswith("eink31")
                        or not install[6:].isdigit()):
                    raise ValueError("invalid native QR fields")
                return 200, dict(vid=900000, accessToken="mock-native-access", refreshToken="mock-native-refresh")
            if path == "/shelf/sync" and method == "GET":
                books = [{key: value for key, value in dict(book, version=700).items() if key != "bookVersion"}
                         for book in ([] if control["empty_shelf"] else readable_books) if str(book['bookId']) not in self.shelf_removed]
                if not control['empty_shelf']:books.extend(self.shelf_added.values())
                return 200, dict(books=books, archive=[
                    dict(archiveId=1, name="旅途", bookIds=[b["bookId"] for b in BOOKS[:15]]),
                    dict(archiveId=2, name="待读", bookIds=[b["bookId"] for b in BOOKS[15:]]),
                    dict(archiveId=3, name="空分组", bookIds=[])], bookProgress=[], synckey=1)
        if path == "/api/agent/gateway" and method == "POST":
            if api == "/readdata/detail":
                return 200, reading_statistics(data.get("mode", "monthly"), int(data.get("baseTime", 0)))
            if api in {"/book/info", "/book/getprogress", "/review/list", "/book/underlines", "/book/readreviews", "/book/similar"}:
                if "bookId" not in data or not any(b["bookId"] == book_id for b in BOOKS):
                    raise ValueError("missing or unknown bookId")
            if api == "/shelf/sync":
                return 200, dict(books=[] if control["empty_shelf"] else readable_books, archive=[
                    dict(archiveId=1, name="旅途", bookIds=[b["bookId"] for b in BOOKS[:15]]),
                    dict(archiveId=2, name="待读", bookIds=[b["bookId"] for b in BOOKS[15:]]),
                    dict(archiveId=3, name="空分组", bookIds=[])])
            if api == "/book/info":
                return 200, book_metadata(next(b for b in BOOKS if b["bookId"] == book_id))
            if api == "/book/similar":
                start = max(0, int(data.get("maxIdx", 0)))
                count = max(1, min(100, int(data.get("count", 20))))
                session = "mock-similar-" + book_id
                if (start > 0 and data.get("sessionId") != session
                        or data.get("sessionId") not in (None, session)):
                    raise ValueError("missing or mismatched similar session")
                candidates = [b for b in BOOKS if b["bookId"] != book_id]
                batch = candidates[start:start + count]
                return 200, dict(booksimilar=dict(sessionId=session,
                    books=[dict(idx=start + i + 1, book=dict(bookInfo=b)) for i, b in enumerate(batch)],
                    hasMore=start + len(batch) < len(candidates)))
            if api in {"/store/search", "/book/recommend"}:
                keyword = data.get("keyword", "")
                matches = [b for b in BOOKS if keyword in b["title"] or keyword in b["author"]]
                start = max(0, int(data.get("maxIdx", 0)))
                count = max(1, min(100, int(data.get("count", 20))))
                batch = matches[start:start + count]
                more = start + len(batch) < len(matches)
                if api == "/book/recommend":
                    return 200, dict(books=[dict(b, searchIdx=start + i + 1) for i, b in enumerate(batch)], hasMore=more)
                return 200, dict(results=[dict(books=[dict(bookInfo=b, searchIdx=start + i + 1)
                                                      for i, b in enumerate(batch)])], hasMore=more)
            if api == "/book/getprogress":
                return 200, self.get_progress(book_id)
            if api == "/review/list":
                return 200, dict(reviewsCnt=1, reviewsHasMore=0, reviews=[dict(review=review())])
            if api in {"/book/underlines", "/book/readreviews"}:
                uid = int(data["chapterUid"])
                if not 1 <= uid <= len(CHAPTERS):
                    raise ValueError("unknown chapterUid")
                mark = annotation(uid)
                if api == "/book/underlines":
                    return 200, dict(chapterUid=uid, underlines=[] if control["empty_annotations"] else [mark])
                return 200, dict(reviews=[] if control["empty_annotations"] else [
                    dict(range=item["range"], metadata=None, pageReviews=[dict(review=review(uid))])
                    for item in data.get("reviews", []) if item["range"] == mark["range"]])
        if path == "/web/categories" and method == "GET":
            return 200, CATEGORIES
        if path.startswith("/web/bookListInCategory/") and method == "GET":
            cid = path.rsplit("/", 1)[1]
            if cid not in {"rising", "100000", "100001"}:
                raise ValueError("unknown category")
            if query.get("rank", [""])[0] != ("1" if cid == "rising" else "0"):
                raise ValueError("incorrect ranking flag")
            start = max(0, int(query.get("maxIndex", ["0"])[0]))
            candidates = BOOKS[:15] if cid == "100001" else BOOKS
            batch = candidates[start:start + 20]
            return 200, dict(books=[dict(bookInfo=b, searchIdx=start + i + 1) for i, b in enumerate(batch)],
                             hasMore=int(start + len(batch) < len(candidates)))
        if path.startswith("/web/reader/") and method == "GET":
            encoded = path.rsplit("/", 1)[1].split("k")
            book = next(b for b in readable_books+METADATA_BOOKS if weread_e(b["bookId"]) == encoded[0])
            chapter = next((c for c in CHAPTERS if len(encoded) > 1 and weread_e(c["chapterUid"]) == encoded[1]), CHAPTERS[0])
            state = dict(reader=dict(bookInfo=book_metadata(book), psvts="mock-session", pclts="mock-clock",
                                     currentChapter=chapter, progress=self.get_progress(book["bookId"])))
            if self.content_format == 'txt':
                state['reader']['bookInfo']['format'] = 'txt'
            return 200, "<script>window.__INITIAL_STATE__=" + json.dumps(state, ensure_ascii=False) + ";(function(){})();</script>"
        if path == "/web/book/chapterInfos" and method == "POST":
            if not isinstance(data.get("bookIds"), list) or not data["bookIds"] or any(
                not any(b["bookId"] == str(book_id) for b in readable_books) for book_id in data["bookIds"]
            ):
                raise ValueError("missing or unknown bookIds")
            return 200, dict(data=[dict(bookId=str(b), updated=CHAPTERS) for b in data["bookIds"]])
        if path.startswith("/web/book/chapter/") and method == "POST":
            content_book = next((b['bookId'] for b in readable_books if weread_e(b['bookId']) == data.get('b')), None)
            if content_book is None:
                raise ValueError("unknown encoded book")
            uid = next(c["chapterUid"] for c in CHAPTERS if weread_e(c["chapterUid"]) == data["c"])
            part = path.rsplit("/", 1)[1]
            if self.content_format == 'txt':
                if part == 'e_0':
                    return 200, dict(bookId=content_book, chapterUid=uid)
                if part in ('t_0','t_1'):
                    return 200, shards(chapter_txt(uid),2)[('t_0','t_1').index(part)]
                if part != 'e_2':
                    raise LookupError('TXT route is not implemented')
            if part == "e_2":
                return 200, shards("p { line-height: 1.5; } img { max-width: 100%; }", 1)[0]
            if part in {"e_0", "e_1", "e_3"}:
                source=self.chapter_source(uid,control['selection_source_revision'])
                return 200, shards(source)[["e_0", "e_1", "e_3"].index(part)]
        if path == "/web/review/single" and method == "GET":
            return 200, dict(review=review(), comments=[
                dict(commentId=f"mock-comment-{i}", content=f"合成回复 {i}", author={"nick": "测试读者"}, createTime=1700000000)
                for i in range(1, 3)], commentsHasMore=0)
        if path == "/web/book/getProgress" and method == "GET":
            result = self.get_progress(book_id)
            with self.lock:
                if self.progress_confirmation_book == book_id:
                    self.progress_confirmation_reads += 1
                    if control['progress_confirmation'] == 'stale' or control['progress_confirmation'] == 'delayed' and self.progress_confirmation_reads < 3:
                        result['book']['chapterOffset'] += 1
            return 200, result
        if path == "/web/book/read" and method == "POST":
            book_id = next(b["bookId"] for b in BOOKS if weread_e(b["bookId"]) == data["b"])
            uid = next(c["chapterUid"] for c in CHAPTERS if weread_e(c["chapterUid"]) == data["c"])
            with self.lock:
                self.progress[book_id] = dict(chapterUid=uid, chapterIdx=data["ci"],
                                              chapterOffset=data["co"], progress=data["pr"], summary=data.get("sm", ""))
                if self.roundtrip_seed is not None:
                    self.roundtrip_posts += 1
                    roundtrip_stage = self.roundtrip_posts
                    if control['progress_roundtrip_mode']=='concurrent' and roundtrip_stage==3:
                        self.progress[book_id]['chapterOffset'] += 17
                else:roundtrip_stage=0
                if 'rt' in data and control['progress_confirmation'] != 'plain':
                    self.progress_confirmation_book, self.progress_confirmation_reads = book_id, 0
            if 'rt' in data and control['progress_confirmation'] == 'noack': return 200, {}
            if ((control['progress_roundtrip_mode']=='probe-noack' and roundtrip_stage==3)
                    or (control['progress_roundtrip_mode']=='restore-noack' and roundtrip_stage==4)):return 200,{}
            return 200, dict(succ=1)
        if path in {"/mock/cover.png", "/mock/illustration.png"} and method == "GET":
            return 200, png()
        raise LookupError("route is not implemented")

    def get_progress(self, book_id):
        with self.lock:
            book = self.progress.get(book_id, dict(chapterUid=1, chapterIdx=1,
                                                  chapterOffset=0, progress=0, summary="")).copy()
            mode = self.control["progress_response"]
            book['chapterOffset'] += self.control['progress_offset_delta']
        normal = dict(book=book)
        if mode == "foreign": return dict(bookId="900099", data=normal)
        if mode == "aliases": return dict(book=dict(book, bookId=book_id, book_id="900099"))
        if mode == "range": return dict(book=dict(book, progress=140))
        if mode == "offset": return dict(book=dict(book, chapterOffset="invalid"))
        if mode == "ambiguous": return dict(data=[normal, dict(book=book.copy())])
        if mode == "rejected": return dict(normal, errCode=-1)
        return normal


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Structured log below deliberately excludes credentials and headers.

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        target = self.path
        data = {}
        extra_headers = {}
        try:
            size = int(self.headers.get("Content-Length", 0))
            if not 0 <= size <= 1024 * 1024:
                raise ValueError("request too large")
            data = json.loads(self.rfile.read(size)) if size else {}
            if not isinstance(data, dict):
                data = {}
                raise ValueError("request JSON must be an object")
            path = urlsplit(self.path)
            if path.path == "/health" and self.command == "GET":
                status, result = 200, dict(service="weread-mock", fixture_version=1)
            elif path.path == "/__state" and self.command == "GET":
                with self.server.lock:
                    totals = [dict(path=path, api=api, count=count) for (path, api), count in self.server.request_totals.items()]
                    status, result = 200, dict(control=self.server.control.copy(), requests=list(self.server.events),
                                              totals=totals, active_requests=dict(self.server.active_requests),
                                              progress=self.server.progress.copy(), confirmation_reads=self.server.progress_confirmation_reads)
                    result['finished_marks']=self.server.finished_marks.copy()
                    result['finished_held']=self.server.finished_held
                    result['selection_thoughts']=self.server.selection_thoughts.copy()
                    result['selection_posts']=self.server.selection_posts
                    result['highlight_posts']=self.server.highlight_posts
                    result['bookmark_posts']=self.server.bookmark_posts
                    result['selection_marks']=self.server.selection_marks.copy()
            elif path.path == "/__control" and self.command == "POST":
                self.set_control(data)
                status, result = 200, dict(ok=True)
            else:
                if path.path == "/__proxy":
                    target = parse_qs(path.query)["url"][0]
                else:
                    target = "https://weread.qq.com" + self.path
                with self.server.lock:
                    self.server.active_requests[target] += 1
                try:
                    routed = self.server.route(self.command, target, data)
                finally:
                    with self.server.lock:
                        self.server.active_requests[target] -= 1
                        if not self.server.active_requests[target]:
                            del self.server.active_requests[target]
                status, result = routed[:2]
                if len(routed) == 3: extra_headers = routed[2]
        except (ValueError, KeyError, TypeError, StopIteration) as exc:
            status, result = 400, dict(errcode=-1, errmsg="Invalid mock request: " + str(exc))
        except LookupError as exc:
            status, result = 501, dict(errcode=-1, errmsg="Unimplemented mock route: " + str(exc))
        try:
            parsed = urlsplit(target)
        except ValueError:
            parsed = urlsplit("")
        api = data.get("api_name")
        if parsed.path == "/login":
            api = "native_renewal" if "refreshToken" in data else "native_qr"
        self.server.record(dict(method=self.command, host=parsed.hostname, path=parsed.path,
                                api=api, book=data.get("bookId"), chapter=data.get("chapterUid"),
                                encoded_chapter=data.get("c"), status=status))
        if isinstance(result, bytes):
            content_type, body = "image/png", result
        elif isinstance(result, str):
            content_type, body = "text/plain; charset=utf-8", result.encode()
        else:
            content_type, body = "application/json", json.dumps(result, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra_headers.items():
            for item in value if isinstance(value, list) else [value]: self.send_header(name, item)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the real downloader cancels a delayed request.

    def set_control(self, data):
        with self.server.lock:
            candidate = self.server.control | data
            if set(candidate) != set(self.server.control):
                raise ValueError("unknown control key")
            if type(candidate["delay"]) not in (float, int) or not 0 <= candidate["delay"] <= 60:
                raise ValueError("delay must be 0..60 seconds")
            if type(candidate["times"]) is not int or candidate["times"] < -1:
                raise ValueError("times must be -1 (always) or a non-negative integer")
            if type(candidate['skip']) is not int or not 0 <= candidate['skip'] <= 10000:
                raise ValueError('skip must be a bounded non-negative integer')
            if type(candidate["status"]) is not int or not 400 <= candidate["status"] <= 599:
                raise ValueError("status must be 400..599")
            if not isinstance(candidate["match"], str):
                raise ValueError("match must be a string")
            if candidate["web_renewal_mode"] not in {"plain", "rotate", "reject", "empty", "foreign", "verify-fail"}:
                raise ValueError("invalid Web renewal mode")
            if candidate['shelf_membership_mode'] not in {'plain','noack'}:
                raise ValueError('invalid membership mode')
            if candidate['finished_mark_mode'] not in {'plain','empty','no_change','position','delayed_ack','hold'}:
                raise ValueError('invalid finished-mark mode')
            if candidate['selection_thought_mode'] not in {'plain','empty','no_change'} or type(candidate['selection_source_revision']) is not int or candidate['selection_source_revision'] not in (1,2):
                raise ValueError('invalid selection fixture mode')
            if candidate["progress_response"] not in {"plain", "foreign", "aliases", "range", "offset", "ambiguous", "rejected"}:
                raise ValueError("invalid progress response mode")
            if type(candidate['progress_offset_delta']) is not int or not 0 <= candidate['progress_offset_delta'] <= 1000000:
                raise ValueError('invalid progress offset delta')
            if candidate['progress_confirmation'] not in {'plain','delayed','stale','noack'}:
                raise ValueError('invalid progress confirmation mode')
            if candidate['progress_roundtrip_mode'] not in {'plain','probe-noack','restore-noack','concurrent'}:
                raise ValueError('invalid progress roundtrip mode')
            if candidate['progress_roundtrip_mode']!='plain' and self.server.roundtrip_seed is None:
                raise ValueError('roundtrip fixture not enabled')
            if type(candidate["mp_article_version"]) is not int or not 1 <= candidate["mp_article_version"] <= 100:
                raise ValueError("invalid MP article version")
            for key in ("empty_shelf", "empty_annotations", "native_annotation_many"):
                if type(candidate[key]) is not bool:
                    raise ValueError(key + " must be boolean")
            self.server.control = candidate
            if 'finished_mark_mode' in data:
                if candidate['finished_mark_mode']=='hold':self.server.finished_release.clear()
                else:self.server.finished_release.set()
            if 'progress_confirmation' in data:
                self.server.progress_confirmation_book, self.server.progress_confirmation_reads = None, 0
            if 'progress_roundtrip_mode' in data:
                self.server.roundtrip_posts=0
                if self.server.roundtrip_seed is not None:self.server.progress[BOOK_ID]=self.server.roundtrip_seed.copy()


def prepare(run_dir, runtime, port, width=600, height=800, dpi=167):
    """Fresh directory only: never read or overwrite the user's KOReader profile."""
    if not (runtime / "luajit").is_file() or not (runtime / "reader.lua").is_file():
        raise ValueError("--koreader must point to the built runtime containing luajit and reader.lua")
    if (runtime / "plugins/weread.koplugin").exists() or (runtime / "plugins/weread.koplugin").is_symlink():
        raise ValueError("remove the duplicate runtime/plugins/weread.koplugin installation first")
    run_dir.mkdir(parents=True, exist_ok=False)
    profile = run_dir / "profile"
    for name in ("settings", "plugins"):
        (profile / name).mkdir(parents=True)
    (run_dir / "books").mkdir()
    (run_dir / "evidence").mkdir()
    archive = run_dir / "candidate.zip"
    subprocess.run(["bash", str(REPO / "scripts/package_release.sh"), str(archive)], check=True)
    with zipfile.ZipFile(archive) as package:
        package.extractall(profile / "plugins")
    (run_dir / "evidence/package.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  candidate.zip\n")
    (run_dir / "evidence/build.json").write_text(json.dumps(dict(
        fixture_version=1, plugin_sha=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        workspace_status=subprocess.check_output(["git", "status", "--short"], cwd=REPO, text=True),
        runtime=str(runtime), ko_home=str(profile), screen=dict(width=width, height=height, dpi=dpi, bb_type="BB8", grayscale=True),
    ), ensure_ascii=False, indent=2) + "\n")
    (profile / "settings.reader.lua").write_text('return { language = "zh_CN", color_rendering = false, auto_save_settings_interval_minutes = 0 }\n')
    (profile / "settings/weread-environment.lua").write_text(
        f'return {{ enabled = true, host = "127.0.0.1", port = {port} }}\n')
    (run_dir / "books/开始测试.html").write_text('<html><head><meta charset="utf-8"/></head><body><h1>本地微信读书测试</h1><p>按 F1 → 工具 → 微信读书 → 我的书架。</p></body></html>')
    bootstrap = profile / "launch.lua"
    bootstrap.write_text('require("setupkoenv")\ndofile("reader.lua")\n')
    launcher = run_dir / "launch.command"
    launcher.write_text("#!/bin/sh\nset -eu\n" + "\n".join(f"export {key}={shlex.quote(str(value))}" for key, value in {
        "KO_HOME": profile,
        "EMULATE_READER": 1, "EMULATE_READER_W": width, "EMULATE_READER_H": height, "EMULATE_READER_DPI": dpi,
        "EMULATE_BW_SCREEN": 1, "EMULATE_BB_TYPE": "BB8",
    }.items()) + f"\ncd {shlex.quote(str(runtime))}\nexec ./luajit {shlex.quote(str(bootstrap))} {shlex.quote(str(run_dir / 'books'))} > {shlex.quote(str(run_dir / 'evidence/runtime.log'))} 2>&1\n")
    launcher.chmod(0o755)
    app = run_dir / "WeReadMock.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    shutil.copyfile(launcher, app / "MacOS/WeReadMock")
    (app / "MacOS/WeReadMock").chmod(0o755)
    (app / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleExecutable="WeReadMock", CFBundleIdentifier="local.weread.mock", CFBundleName="WeRead Mock", CFBundlePackageType="APPL", NSHighResolutionCapable=True)))
    return launcher


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--bind", default="127.0.0.1", help="listen address; use 0.0.0.0 for Kindle on the same LAN")
    parser.add_argument("--run-dir", type=Path, help="create a NEW isolated candidate installation")
    parser.add_argument("--koreader", type=Path, help="built KOReader runtime directory (not source root)")
    parser.add_argument("--log", type=Path, help="JSONL request log, without headers or private data")
    parser.add_argument("--smoke", action="store_true", help="run real KOReader offscreen smoke, save evidence, then exit")
    parser.add_argument("--width", type=int, default=600)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--dpi", type=int, default=167)
    args = parser.parse_args()
    if min(args.width, args.height, args.dpi) < 1:
        parser.error("screen dimensions and DPI must be positive")
    if bool(args.run_dir) != bool(args.koreader):
        parser.error("--run-dir and --koreader must be provided together")
    if args.smoke and not args.run_dir:
        parser.error("--smoke requires a fresh --run-dir and --koreader")
    if args.run_dir and args.bind not in ("127.0.0.1", "0.0.0.0"):
        parser.error("local launcher requires --bind 127.0.0.1 or 0.0.0.0; use --bind LAN_IP without --run-dir for a device-only server")
    server = MockServer(args.port, args.log, args.bind)
    if args.run_dir:
        args.run_dir = args.run_dir.resolve()
        launcher = prepare(args.run_dir, args.koreader.resolve(), server.server_port, args.width, args.height, args.dpi)
        server.log_path = args.run_dir / "evidence/requests.jsonl"
        print(f"Launch: {launcher}", flush=True)
    print(f"Mock server: http://{args.bind}:{server.server_port} (Ctrl-C to stop)", flush=True)
    if args.smoke:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = os.environ | dict(KO_HOME=str(args.run_dir / "profile"),
                                EMULATE_READER="1", EMULATE_READER_W=str(args.width),
                                EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi),
                                EMULATE_BW_SCREEN="1", EMULATE_BB_TYPE="BB8")
        log = args.run_dir / "evidence/smoke.log"
        try:
            with log.open("w") as out:
                result = subprocess.run(["./luajit", str(REPO / "spec/koreader/weread_mock_smoke.lua")],
                                        cwd=args.koreader, env=env, stdout=out, stderr=subprocess.STDOUT, timeout=150)
            if result.returncode == 0:
                assert b"[WeRead] forceRePaint failed:" not in log.read_bytes(), "native repaint failed; inspect the isolated smoke log"
                for secret in ("mock-native-access", "mock-native-refresh", "mock-native-code", "mock-native-ticket", "mock-native-qr"):
                    assert secret.encode() not in log.read_bytes(), "native fixture credentials entered runtime diagnostics"
                    assert secret not in (args.run_dir / "evidence/requests.jsonl").read_text(), "native fixture credentials entered request log"
                full_books = list((args.run_dir / "profile/weread-mock/cache").rglob("* - full.epub"))
                assert len(full_books) == 1, "expected one completed full EPUB"
                with zipfile.ZipFile(full_books[0]) as epub:
                    assert epub.testzip() is None, "corrupt EPUB"
                    source = epub.read("OEBPS/weread-source.txt").decode()
                    payload, source_id = source.rsplit("source_id=", 1)
                    identity = dict(line.split("=", 1) for line in payload.splitlines())
                    assert identity["book_id"] == "900001" and identity["book_version"] == "7", "download source changed"
                    assert identity["chapter_count"] == "6", "source does not describe full download"
                    assert hashlib.sha256(payload.encode()).hexdigest() == source_id.strip(), "invalid source checksum"
                    pages = [epub.read(name).decode() for name in epub.namelist() if name.startswith("OEBPS/text/") and name.endswith(".xhtml")]
                    for uid in range(1, 7):
                        assert any(f"这是第{uid}章的第1段" in page for page in pages), f"missing chapter {uid}"
                    assert any("images/" in name for name in epub.namelist()), "missing image asset"
            print(("PASS" if result.returncode == 0 else "FAIL") + f": {log}")
            raise SystemExit(result.returncode)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
