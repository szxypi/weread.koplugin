#!/usr/bin/env python3
"""Run with python3 scripts/test_mock_weread.py; no KOReader or network account."""
import json
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

from fetch_weread_epub import decode_content_shards, decode_style_shard, weread_e
from mock_weread import BOOK_ID, CHAPTERS, MockServer, annotation, chapter_html, shards
from verify_bookstore import categories as verify_categories, page as verify_page


class MockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = MockServer(0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.opener = build_opener(ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, path, data=None):
        request = Request(self.base + path, data=None if data is None else json.dumps(data).encode(),
                          headers={"Content-Type": "application/json"})
        try:
            response = self.opener.open(request, timeout=3)
        except HTTPError as exc:
            response = exc
        with response:
            body = response.read()
            if response.headers["Content-Type"] == "application/json":
                body = json.loads(body)
            return response.status, body

    def gateway(self, api, **params):
        return self.request("/api/agent/gateway", dict(api_name=api, **params))

    def setUp(self):
        self.request("/__control", dict(delay=0, match="", status=503, times=0,
                                        empty_shelf=False, empty_annotations=False))

    def test_mp_verification_failure_after_successful_web_renewal(self):
        code,result=self.request('/web/login/renewal',dict(rq='%2Fweb%2Fbook%2Fread',ql=False))
        self.assertEqual((code,result),(200,{'succ':1}))
        code,result=self.request('/web/mp/articles?bookId=MP_WXS_900001&maxIdx=0&count=100')
        self.assertEqual(code,200)
        self.assertEqual(result['errCode'],-2041)
        self.assertEqual(self.request('/web/login/renewal',{})[0],400)

    def test_mp_catalog_synthetic_shapes_are_explicit(self):
        base='/web/mp/articles?maxIdx=0&count=100&bookId='
        code,page=self.request(base+'MP_WXS_900096')
        self.assertEqual(code,200);self.assertEqual(len(page['reviews'][0]['subReviews']),2)
        self.assertEqual(self.request(base+'MP_WXS_900095')[1],{'reviews':[]})
        self.assertEqual(self.request(base+'MP_WXS_900093')[1],{'reviews':{}})
        self.assertEqual(self.request(base+'MP_WXS_900092')[1],{'errCode':-2012})
        self.assertEqual(len(self.request(base+'MP_WXS_900089')[1]['reviews'][0]['subReviews']),100)
        self.assertEqual(self.request(base.replace('count=100','count=20')+'MP_WXS_900096')[0],400)

    def test_mp_content_samples_remain_distinct(self):
        from urllib.parse import quote
        bodies=[]
        for identity in ('cache-fixture-a/b','cache-fixture-a_b'):
            code,body=self.request('/web/mp/content?reviewId='+quote(identity,safe=''))
            self.assertEqual(code,200);bodies.append(body)
        self.assertNotEqual(*bodies)
        self.assertEqual(self.request('/web/mp/content?reviewId=unknown')[0],400)

    def test_contract_and_real_reference_decoder(self):
        status, shelf = self.gateway("/shelf/sync")
        self.assertEqual(status, 200)
        self.assertEqual(len(shelf["books"]), 26)
        self.assertEqual(len(shelf["archive"]), 3)
        _, catalog = self.request("/web/book/chapterInfos", dict(bookIds=[BOOK_ID]))
        self.assertEqual(catalog["data"][0]["updated"], CHAPTERS)
        for uid in range(1, 7):
            params = dict(b=weread_e(BOOK_ID), c=weread_e(uid))
            parts = [self.request("/web/book/chapter/" + part, params)[1].decode()
                     for part in ("e_0", "e_1", "e_3")]
            self.assertEqual(decode_content_shards(*parts), chapter_html(uid))
            mark = annotation(uid)
            begin, end = map(int, mark["range"].split("-"))
            self.assertEqual(chapter_html(uid)[begin:end], mark["markText"])
        self.assertIn("line-height", decode_style_shard(self.request("/web/book/chapter/e_2", params)[1].decode()))
        for text in ("", "a", "你好", "🌿" * 31, "abcdef" * 103):
            self.assertEqual(decode_content_shards(*shards(text)), text)

    def test_discovery_batches(self):
        status, first = self.gateway("/book/recommend", count=20, maxIdx=0)
        self.assertEqual(status, 200)
        self.assertEqual(len(first["books"]), 20)
        self.assertTrue(first["hasMore"])
        cursor = first["books"][-1]["searchIdx"]
        _, second = self.gateway("/book/recommend", count=20, maxIdx=cursor)
        self.assertEqual(len(second["books"]), 6)
        self.assertFalse(second["hasMore"])
        self.assertNotEqual(first["books"][0]["bookId"], second["books"][0]["bookId"])
        _, found = self.gateway("/store/search", keyword="合成读物", count=5)
        self.assertEqual(len(found["results"][0]["books"]), 5)
        self.assertTrue(found["hasMore"])
        _, empty = self.gateway("/store/search", keyword="nonexistent")
        self.assertEqual(empty["results"][0]["books"], [])
        self.assertFalse(empty["hasMore"])

    def test_keyless_web_shelf_contract(self):
        status, account = self.request('/api/userInfo?userVid=900000')
        self.assertEqual((status,account['vid']),(200,900000))
        self.assertEqual(self.request('/api/skills/apikeyGet?only_show=1'),(200,{}))
        status,shelf=self.request('/web/shelf/sync')
        self.assertEqual((status,len(shelf['books']),len(shelf['archive'])),(200,26,3))
        self.assertEqual(shelf['books'][0]['version'],800)
        self.assertNotIn('bookVersion',shelf['books'][0])
        self.assertEqual(self.request('/web/shelf/sync',{})[0],501)

    def test_native_authorization_fixture_validates_signature(self):
        status, ticket = self.server.route("GET", "https://i.weread.qq.com/wxticket?nonceStr=weread", {})
        self.assertEqual(status, 200)
        self.assertIn("signature", ticket)
        _, qr = self.server.route("GET", "https://open.weixin.qq.com/connect/sdk/qrconnect?appid=wxab9b71ad2b90ff34&signature=mock-native-ticket", {})
        self.assertEqual(qr["errcode"], 0)
        _, approved = self.server.route("GET", "https://long.open.weixin.qq.com/connect/l/qrconnect?uuid=mock-native-qr", {})
        device, install = "eink334691225" + "1"*19, "eink31" + "1"*26
        body = dict(code=approved["wx_code"], deviceId=device, installId=install, timestamp=1794100000123, random=112)
        import hashlib
        body["signature"] = hashlib.sha256(f"{body['timestamp']}{device}{body['random']}".encode()).hexdigest()
        self.assertEqual(self.server.route("POST", "https://i.weread.qq.com/login", body)[1]["vid"], 900000)
        body["signature"] = "incorrect"
        with self.assertRaises(ValueError):
            self.server.route("POST", "https://i.weread.qq.com/login", body)
        self.assertEqual(len(self.server.route("GET", "https://i.weread.qq.com/shelf/sync", {})[1]["books"]), 26)
        native = "https://i.weread.qq.com/shelf/sync"
        snapshot = self.server.route("GET", native, {})[1]
        self.assertEqual(snapshot["books"][0]["version"], 700)
        self.assertEqual(len(snapshot["archive"]), 3)
        self.assertNotIn("bookVersion", snapshot["books"][0])
        body.pop("code")
        body.pop("installId")
        body.update(refreshToken="mock-native-refresh", inBackground=0, kickType=1, refCgi="")
        body["signature"] = hashlib.sha256(f"{int(body['timestamp'])}{device}{body['random']}".encode()).hexdigest()
        renewed = self.server.route("POST", "https://i.weread.qq.com/login", body)[1]
        self.assertEqual(renewed["accessToken"], "mock-native-access")
        self.assertNotIn("refreshToken", renewed)

    def test_native_discovery_contract_and_continuation(self):
        base='https://i.weread.qq.com'
        _,first=self.server.route('GET',base+'/store/search?keyword=测试作者&scope=10&count=20&maxIdx=0',{})
        self.assertEqual(len(first['books']),20)
        self.assertNotIn('results',first)
        _,second=self.server.route('GET',base+'/store/search?keyword=测试作者&scope=10&count=20&maxIdx=20',{})
        self.assertEqual(len(second['books']),6)
        _,similar=self.server.route('GET',base+f'/book/detailinfo?bookId={BOOK_ID}&listtypes=2&synckey=0&count=20&maxIdx=0',{})
        session=similar['booksimilar']['sessionId']
        self.assertEqual(len(similar['booksimilar']['books']),20)
        _,last=self.server.route('GET',base+f'/book/detailinfo?bookId={BOOK_ID}&listtypes=2&synckey=0&count=20&maxIdx=20&sessionId={session}',{})
        self.assertEqual(len(last['booksimilar']['books']),5)
        for query in ('count=21&maxIdx=0','count=20&maxIdx=-1','count=20&maxIdx=0&extra=1'):
            with self.assertRaises(ValueError):self.server.route('GET',base+'/book/recommend?'+query,{})

    def test_native_metadata_has_distinct_version_and_word_field(self):
        base='https://i.weread.qq.com/book/info?'
        _,value=self.server.route('GET',base+'bookId='+BOOK_ID,{})
        self.assertEqual(value['totalWords'],12000)
        self.assertEqual(value['version'],700)
        self.assertNotIn('bookVersion',value);self.assertNotIn('wordCount',value)
        for query in ('bookId='+BOOK_ID+'&other=1','bookId='+BOOK_ID+'&bookId='+BOOK_ID,'bookId=not-a-book'):
            with self.assertRaises(ValueError):self.server.route('GET',base+query,{})

    def test_annotations_and_progress_write_read(self):
        _, result = self.gateway("/book/underlines", bookId=BOOK_ID, chapterUid=2)
        mark = result["underlines"][0]
        self.assertIn("metadata", mark)
        self.assertIsNone(mark["metadata"])
        _, thoughts = self.gateway("/book/readreviews", bookId=BOOK_ID, chapterUid=2, reviews=[dict(range=mark["range"])])
        self.assertEqual(thoughts["reviews"][0]["range"], mark["range"])
        self.assertIn("metadata", thoughts["reviews"][0])
        self.assertIsNone(thoughts["reviews"][0]["metadata"])
        self.assertGreater(len(thoughts["reviews"][0]["pageReviews"][0]["review"]["content"]), 100)
        self.request("/web/book/read", dict(b=weread_e(BOOK_ID), c=weread_e(2), ci=2, co=120, pr=25))
        _, progress = self.gateway("/book/getprogress", bookId=BOOK_ID)
        self.assertEqual(progress["book"]["chapterOffset"], 120)

    def test_similar_session_and_batches(self):
        status, first = self.gateway("/book/similar", bookId=BOOK_ID, count=20)
        self.assertEqual(status, 200)
        first = first["booksimilar"]
        self.assertEqual(len(first["books"]), 20)
        self.assertTrue(first["hasMore"])
        self.assertTrue(all(row["book"]["bookInfo"]["bookId"] != BOOK_ID for row in first["books"]))
        cursor, session = first["books"][-1]["idx"], first["sessionId"]
        _, second = self.gateway("/book/similar", bookId=BOOK_ID, maxIdx=cursor, sessionId=session)
        self.assertEqual(len(second["booksimilar"]["books"]), 5)
        self.assertFalse(second["booksimilar"]["hasMore"])
        self.assertEqual(self.gateway("/book/similar", bookId=BOOK_ID, maxIdx=cursor)[0], 400)
        self.assertEqual(self.gateway("/book/similar", bookId="900002", maxIdx=cursor, sessionId=session)[0], 400)
        self.assertEqual(self.gateway("/book/similar", bookId="unknown")[0], 400)

    def test_public_categories_and_rank_pages(self):
        status, data = self.request("/web/categories?rank=1&synckey=0")
        self.assertEqual(status, 200)
        self.assertEqual(data["data"][1]["categories"][0]["sublist"][0]["CategoryId"], "100001")
        self.assertEqual(verify_categories(data), [("rising", True), ("100000", False), ("100001", False)])
        with self.assertRaises(ValueError):
            verify_categories({"data": [{"CategoryId": "../invalid", "title": "Invalid"}]})
        for cid, rank in (("rising", 1), ("100000", 0)):
            _, first = self.request(f"/web/bookListInCategory/{cid}?rank={rank}&maxIndex=0")
            self.assertEqual(len(first["books"]), 20)
            self.assertTrue(first["hasMore"])
            self.assertEqual(verify_page(first)[1], 20)
            cursor = first["books"][-1]["searchIdx"]
            _, last = self.request(f"/web/bookListInCategory/{cid}?rank={rank}&maxIndex={cursor}")
            self.assertEqual(len(last["books"]), 6)
            self.assertFalse(last["hasMore"])
            self.assertEqual(verify_page(last)[1], 26)
        _, sub = self.request("/web/bookListInCategory/100001?rank=0&maxIndex=0")
        self.assertEqual(len(sub["books"]), 15)
        self.assertFalse(sub["hasMore"])
        self.assertEqual(self.request("/web/bookListInCategory/unknown?rank=0")[0], 400)
        self.assertEqual(self.request("/web/bookListInCategory/rising?rank=0")[0], 400)

    def test_reading_statistics_natural_periods(self):
        for mode in ("weekly", "monthly", "annually", "overall"):
            status, data = self.gateway("/readdata/detail", mode=mode)
            self.assertEqual(status, 200)
            self.assertEqual(sum(data["readTimes"].values()), data["totalReadTime"])
            self.assertEqual(sum(data["dailyReadTimes"].values()), data["totalReadTime"])
            self.assertTrue(all((int(stamp) + 28800) % 86400 == 0 for stamp in data["readTimes"]))
        _, historical = self.gateway("/readdata/detail", mode="monthly", baseTime=1706716800)
        self.assertEqual(len(historical["readTimes"]), 29)  # February 2024, leap year
        self.assertEqual(self.gateway("/readdata/detail", mode="invalid")[0], 400)

    def test_native_statistics_exact_get_contract(self):
        from verify_native_statistics import project
        base='https://i.weread.qq.com/readdata/detail?'
        for mode in ('weekly','monthly','annually','overall'):
            status,raw=self.server.route('GET',base+f'mode={mode}&baseTime=0',{})
            self.assertEqual(status,200)
            self.assertEqual(project(raw,mode)['totalReadTime'],raw['totalReadTime'])
        _,raw=self.server.route('GET',base+'mode=monthly&baseTime=1706716800',{})
        self.assertEqual(len(project(raw,'monthly',1706716800)['readTimes']),29)
        for query in ('mode=other&baseTime=0','mode=monthly&baseTime=-1','mode=monthly&baseTime=0&extra=1',
                      'mode=monthly&baseTime=0&baseTime=0'):
            with self.assertRaises(ValueError):self.server.route('GET',base+query,{})

    def test_fault_once_delay_and_recovery(self):
        self.request("/__control", dict(match="/book/info", times=1, status=503, delay=0.02))
        start = time.monotonic()
        self.assertEqual(self.gateway("/book/info", bookId=BOOK_ID)[0], 503)
        self.assertGreaterEqual(time.monotonic() - start, 0.02)
        self.assertEqual(self.gateway("/book/info", bookId=BOOK_ID)[0], 200)
        self.assertEqual(self.gateway("/shelf/sync")[0], 200)
        self.request("/__control", dict(empty_shelf=True, empty_annotations=True))
        self.assertEqual(self.gateway("/shelf/sync")[1]["books"], [])
        self.assertEqual(self.gateway("/book/underlines", bookId=BOOK_ID, chapterUid=1)[1]["underlines"], [])

    def test_unknown_routes_and_malformed_control_fail(self):
        with self.assertRaises(ValueError):
            MockServer(0, bind="8.8.8.8")
        lan_server = MockServer(0, bind="0.0.0.0")
        self.assertEqual(lan_server.server_address[0], "0.0.0.0")
        lan_server.server_close()
        self.assertEqual(self.request("/unknown")[0], 501)
        self.assertEqual(self.request("/__proxy?url=https%3A%2F%2Fexample.invalid%2Fx")[0], 501)
        self.assertEqual(self.gateway("/unknown")[0], 501)
        self.assertEqual(self.gateway("/book/info", bookId="unknown")[0], 400)
        self.assertEqual(self.gateway("/book/underlines", chapterUid=1)[0], 400)
        self.assertEqual(self.request("/web/book/chapterInfos", dict(bookIds=["unknown"]))[0], 400)
        self.assertEqual(self.request("/__control", dict(delay=-1))[0], 400)
        self.assertEqual(self.request("/__control", dict(times="forever"))[0], 400)
        self.assertEqual(self.request("/__control", dict(unknown=True))[0], 400)
        self.assertEqual(self.request("/web/book/chapter/e_0", dict(b="unknown", c="bad"))[0], 400)
        self.assertEqual(self.request("/__control", [1, 2])[0], 400)
        self.assertEqual(self.request("/__proxy?url=http%3A%2F%2F%5Bbad")[0], 400)
        _, state = self.request("/__state")
        self.assertTrue(any(event["status"] == 501 for event in state["requests"]))
        self.assertTrue(all("headers" not in event for event in state["requests"]))


if __name__ == "__main__":
    unittest.main()
