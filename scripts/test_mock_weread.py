#!/usr/bin/env python3
"""Run with python3 scripts/test_mock_weread.py; no KOReader or network account."""
import json
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

from fetch_weread_epub import decode_content_shards, decode_style_shard, weread_e
from mock_weread import BOOK_ID, CHAPTERS, MockServer, annotation, chapter_html, chapter_txt, shards
from verify_bookstore import categories as verify_categories, page as verify_page


class MockTests(unittest.TestCase):
    def test_direct_initial_styles_match_the_independently_verified_enum(self):
        base='https://i.weread.qq.com';raw=chapter_html(2);quote='这是第2章的第1段。我们沿着小路慢慢前行，'
        first=raw.index(quote);body=dict(bookId=BOOK_ID,chapterUid=2,bookVersion=700,type=1,style=1,colorStyle=0,
            range=f'{first}-{first+len(quote)}',markText=quote)
        original=json.loads(json.dumps(self.server.selection_marks));self.server.selection_fixture=True
        try:
            for style in (True,-1,3,'2',1.5):
                with self.subTest(style=style),self.assertRaises(ValueError):self.server.route('POST',base+'/book/addBookmark',dict(body,style=style))
            for style in (0,1,2):
                _,result=self.server.route('POST',base+'/book/addBookmark',dict(body,style=style));key=result['bookmarkId']
                self.assertEqual(self.server.selection_marks[key]['style'],style)
                self.server.route('POST',base+'/book/removeBookmark',dict(bookmarkIds=[key]))
            self.assertEqual(self.server.selection_marks,original);self.assertEqual(self.server.highlight_posts,6)
        finally:self.server.selection_fixture=False;self.server.selection_marks=original;self.server.highlight_posts=0
    def test_point_bookmark_fixture_rejects_guesses_and_only_removes_its_new_record(self):
        from bookmark_point import project
        from test_bookmark_point import coordinate
        base='https://i.weread.qq.com';raw=self.server.chapter_source(2);value=project(raw,coordinate(raw,'这是第2章的第1段'))
        body=dict(bookId=BOOK_ID,chapterUid=2,bookVersion=700,type=0,style=0,range=value['range'],markText=value['markText'])
        original=json.loads(json.dumps(self.server.selection_marks));self.server.selection_fixture=True
        try:
            for invalid in (dict(body,colorStyle=0),dict(body,chapterIdx=2),dict(body,range='01'),dict(body,markText='Other preview')):
                with self.assertRaises(ValueError):self.server.route('POST',base+'/book/addBookmark',invalid)
            _,result=self.server.route('POST',base+'/book/addBookmark',body);key=result['bookmarkId']
            self.assertEqual(self.server.selection_marks[key]['type'],0);self.assertNotIn('markText',self.server.selection_marks[key])
            self.server.route('POST',base+'/book/removeBookmark',dict(bookmarkIds=[key]))
            self.assertEqual(self.server.selection_marks,original);self.assertEqual(self.server.bookmark_posts,2)
        finally:self.server.selection_fixture=False;self.server.selection_marks=original;self.server.bookmark_posts=0

    def test_selected_thought_fixture_is_scoped_and_preserves_original(self):
        base='https://i.weread.qq.com';raw=chapter_html(2);quote='这是第2章的第1段。我们沿着小路慢慢前行，'
        first=raw.index(quote);body=dict(bookId=BOOK_ID,chapterUid='2',bookVersion=700,type=1,
            range=f'{first}-{first+len(quote)}',abstract=quote,isPrivate=1,content='Synthetic selected thought')
        with self.assertRaises(LookupError):self.server.route('POST',base+'/review/add',body)
        original=json.loads(json.dumps(self.server.selection_thoughts));self.server.selection_fixture=True
        try:
            for invalid in (dict(body,isPrivate=0),dict(body,bookId='41'),dict(body,chapterIdx=True),dict(body,abstract='Different quote')):
                with self.assertRaises(ValueError):self.server.route('POST',base+'/review/add',invalid)
            _,result=self.server.route('POST',base+'/review/add',body);identity=result['reviewId']
            self.assertEqual(self.server.selection_thoughts[identity]['abstract'],quote)
            with self.assertRaises(ValueError):self.server.route('POST',base+'/review/delete',dict(reviewId='synthetic-existing-thought'))
            with self.assertRaises(ValueError):self.server.route('POST',base+'/review/useredit',dict(reviewId=identity,content={}))
            self.server.route('POST',base+'/review/useredit',dict(reviewId=identity,content='Edited test'))
            self.server.route('POST',base+'/review/delete',dict(reviewId=identity))
            self.assertEqual(self.server.selection_thoughts,original);self.assertEqual(self.server.selection_posts,3)
        finally:self.server.selection_fixture=False;self.server.selection_thoughts=original;self.server.selection_posts=0

    def test_finished_mark_fixture_is_opt_in_and_single_target(self):
        base='https://i.weread.qq.com';body=dict(bookId=BOOK_ID,auto=0,finishInfo=0,status=4,isCancel=0)
        with self.assertRaises(LookupError):self.server.route('POST',base+'/book/markstatus',body)
        self.server.finish_fixture=True
        try:
            original=self.server.get_progress(BOOK_ID)
            self.assertEqual(self.server.route('POST',base+'/book/markstatus',body),(200,dict(status=1)))
            books=self.server.route('GET',base+'/shelf/sync',{})[1]['books']
            self.assertEqual(next(row for row in books if row['bookId']==BOOK_ID)['finishReading'],1)
            self.assertEqual(self.server.route('GET',base+'/book/getProgress?bookId='+BOOK_ID,{})[1],original)
            self.assertEqual(self.server.route('POST',base+'/book/markstatus',dict(body,isCancel=1)),(200,dict(status=1)))
            for changed in [dict(body,isCancel=True),dict(body,auto=0.0),dict(body,status=1),dict(body,bookId='CB_1'),dict(body,bookIds=[BOOK_ID])]:
                with self.assertRaises(ValueError):self.server.route('POST',base+'/book/markstatus',changed)
            self.assertEqual(self.request('/__control',dict(finished_mark_mode='empty'))[0],200)
            self.assertEqual(self.server.route('POST',base+'/book/markstatus',body),(200,''))
            self.assertEqual(self.server.finished_marks[BOOK_ID],1)
            self.assertEqual(self.request('/__control',dict(finished_mark_mode='no_change'))[0],200)
            self.server.route('POST',base+'/book/markstatus',dict(body,isCancel=1));self.assertEqual(self.server.finished_marks[BOOK_ID],1)
            self.assertEqual(self.request('/__control',dict(finished_mark_mode='position'))[0],200)
            self.server.route('POST',base+'/book/markstatus',body)
            self.assertEqual(self.server.get_progress(BOOK_ID)['book']['chapterOffset'],original['book']['chapterOffset']+1)
            self.assertEqual(self.request('/__control',dict(finished_mark_mode='hold'))[0],200)
            result=[]
            worker=threading.Thread(target=lambda:result.append(self.server.route('POST',base+'/book/markstatus',dict(body,isCancel=1))))
            worker.start()
            try:
                deadline=time.monotonic()+2
                while not self.server.finished_held and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(self.server.finished_held)
                self.assertEqual(self.server.finished_marks[BOOK_ID],0)
                self.assertEqual(self.request('/__control',dict(finished_mark_mode='plain'))[0],200)
                worker.join(2)
                self.assertFalse(worker.is_alive());self.assertEqual(result,[(200,dict(status=1))])
            finally:
                self.server.finished_release.set();worker.join(2)
            for invalid in ('unexpected',1,None):self.assertEqual(self.request('/__control',dict(finished_mark_mode=invalid))[0],400)
        finally:
            self.server.finish_fixture=False;self.server.finished_marks.clear()
            self.request('/__control',dict(finished_mark_mode='plain',progress_offset_delta=0))

    def test_single_book_native_membership_and_unknown_ack(self):
        base='https://i.weread.qq.com'
        members=lambda:{str(row['bookId']) for row in self.server.route('GET',base+'/shelf/sync',{})[1]['books']}
        original=members()
        try:
            self.assertEqual(self.server.route('POST',base+'/shelf/delete',dict(bookIds=[BOOK_ID])),(200,dict(succ=1)))
            self.assertEqual(members(),original-{BOOK_ID})
            self.assertEqual(self.server.route('POST',base+'/shelf/add',dict(bookIds=[BOOK_ID])),(200,dict(succ=1)))
            self.assertEqual(members(),original)
            self.request('/__control',dict(shelf_membership_mode='noack'))
            self.assertEqual(self.server.route('POST',base+'/shelf/add',dict(bookIds=['999999999'])),(200,{}))
            self.assertIn('999999999',members())
            for body in (dict(bookIds=[]),dict(bookIds=[BOOK_ID,'2']),dict(bookIds=['MP_1']),dict(bookIds=[True]),dict(bookId=BOOK_ID)):
                with self.assertRaises(ValueError):self.server.route('POST',base+'/shelf/add',body)
        finally:
            self.server.shelf_removed.clear();self.server.shelf_added.clear()
            self.request('/__control',dict(shelf_membership_mode='plain'))

    def test_offset_delta_simulates_another_client_without_changing_stored_progress(self):
        self.server.progress[BOOK_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=100,progress=25)
        self.assertEqual(self.request('/__control',dict(progress_offset_delta=1))[0],200)
        self.assertEqual(self.server.get_progress(BOOK_ID)['book']['chapterOffset'],101)
        self.assertEqual(self.server.progress[BOOK_ID]['chapterOffset'],100)
        self.assertEqual(self.request('/__control',dict(progress_offset_delta=0))[0],200)
        self.assertEqual(self.server.get_progress(BOOK_ID)['book']['chapterOffset'],100)
        for value in (-1,1000001,True,'1',1.5):
            self.assertEqual(self.request('/__control',dict(progress_offset_delta=value))[0],400)

    def test_native_multi_batch_fixture_expires_only_the_second_request(self):
        self.assertEqual(self.request('/__control',dict(native_annotation_many=True,match='/book/readreviews',skip=1,times=1,status=401))[0],200)
        target='https://i.weread.qq.com'
        _,raw=self.server.route('GET',target+'/book/underlines?bookId='+BOOK_ID+'&chapterUid=1&synckey=0',{})
        ranges=[row['range'] for row in raw['underlines']]
        self.assertEqual((len(ranges),len(set(ranges))),(31,31))
        bodies=[dict(bookId=BOOK_ID,chapterUid=1,cht2sMode='',reviews=[dict(range=marker,maxIdx=0,count=30,synckey=0) for marker in batch])
                for batch in (ranges[:30],ranges[30:])]
        status,first=self.server.route('POST',target+'/book/readreviews',bodies[0])
        self.assertEqual((status,len(first['reviews'])),(200,30))
        self.assertEqual(self.server.route('POST',target+'/book/readreviews',bodies[1])[0],401)
        status,last=self.server.route('POST',target+'/book/readreviews',bodies[1])
        self.assertEqual((status,len(last['reviews'])),(200,1))

    def test_native_batch_fault_controls_are_bounded_and_typed(self):
        for value in (True,-1,10001,'1'):
            self.assertEqual(self.request('/__control',dict(skip=value))[0],400)
        self.assertEqual(self.request('/__control',dict(native_annotation_many=1))[0],400)

    def test_native_annotations_match_the_existing_readonly_shapes(self):
        target='https://i.weread.qq.com'
        code,raw=self.server.route('GET',target+'/book/underlines?bookId='+BOOK_ID+'&chapterUid=1&synckey=0',{})
        self.assertEqual((code,raw['chapterUid'],len(raw['underlines'])),(200,1,1))
        body=dict(bookId=BOOK_ID,chapterUid=1,cht2sMode='',reviews=[dict(range=raw['underlines'][0]['range'],maxIdx=0,count=30,synckey=0)])
        code,reviews=self.server.route('POST',target+'/book/readreviews',body)
        self.assertEqual((code,len(reviews['reviews'][0]['pageReviews'])),(200,1))
        for changed in (dict(body,chapterUid=True),dict(body,extra=0),dict(body,reviews=[])):
            with self.assertRaises(ValueError):self.server.route('POST',target+'/book/readreviews',changed)

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
        self.server.roundtrip_seed=None
        self.request("/__control", dict(delay=0, match="", status=503, times=0,skip=0,native_annotation_many=False,
                                        empty_shelf=False, empty_annotations=False, web_renewal_mode="plain", mp_article_version=1,
                                        progress_response="plain",progress_confirmation="plain",progress_roundtrip_mode="plain"))

    def test_roundtrip_faults_apply_a_known_probe_but_lose_only_its_acknowledgement(self):
        self.server.roundtrip_seed=dict(chapterUid=2,chapterIdx=2,chapterOffset=170,progress=37)
        for mode,expected in (('plain',[170,170,171,170]),('probe-noack',[170,170,171,170]),
                              ('restore-noack',[170,170,171,170]),('concurrent',[170,170,188,170])):
            self.assertEqual(self.request('/__control',dict(progress_roundtrip_mode=mode))[0],200)
            seen=[]
            for index,co in enumerate((170,170,171,170)):
                wire=dict(b=weread_e(BOOK_ID),c=weread_e(2),ci=2,co=co,pr=37)
                if index:wire['rt']=0
                status,result=self.server.route('POST','https://weread.qq.com/web/book/read',wire)
                self.assertEqual(status,200)
                self.assertEqual(result,{} if (mode=='probe-noack' and index==2 or mode=='restore-noack' and index==3) else dict(succ=1))
                seen.append(self.server.get_progress(BOOK_ID)['book']['chapterOffset'])
            self.assertEqual(seen,expected)

    def test_roundtrip_faults_need_an_explicit_synthetic_fixture(self):
        self.assertEqual(self.request('/__control',dict(progress_roundtrip_mode='probe-noack'))[0],400)
        self.assertEqual(self.request('/__control',dict(progress_roundtrip_mode='unknown'))[0],400)

    def test_progress_confirmation_faults_apply_only_after_report_and_only_on_web(self):
        wire=dict(b=weread_e(BOOK_ID),c=weread_e(2),ci=2,co=10,pr=25)
        for mode in ('delayed','stale','noack'):
            self.request('/__control',dict(progress_confirmation=mode))
            self.server.route('POST','https://weread.qq.com/web/book/read',wire)
            body=self.server.route('POST','https://weread.qq.com/web/book/read',dict(wire,rt=0))[1]
            self.assertEqual(body,{} if mode=='noack' else dict(succ=1))
            offsets=[self.server.route('GET','https://weread.qq.com/web/book/getProgress?bookId='+BOOK_ID,{})[1]['book']['chapterOffset'] for _ in range(3)]
            self.assertEqual(offsets,[11,11,10] if mode=='delayed' else [11,11,11] if mode=='stale' else [10,10,10])
            self.assertEqual(self.server.get_progress(BOOK_ID)['book']['chapterOffset'],10)

    def test_progress_confirmation_control_is_bounded_and_resettable(self):
        self.assertEqual(self.request('/__control',dict(progress_confirmation='unknown'))[0],400)
        self.assertEqual(self.request('/__control',dict(progress_confirmation=True))[0],400)
        self.request('/__control',dict(progress_confirmation='plain'))
        self.assertEqual(self.request('/__state')[1]['confirmation_reads'],0)

    def test_progress_faults_are_identical_on_web_and_gateway(self):
        for mode in ("foreign", "aliases", "range", "offset", "ambiguous", "rejected", "plain"):
            self.assertEqual(self.request('/__control', dict(progress_response=mode))[0], 200)
            web = self.request('/web/book/getProgress?bookId=' + BOOK_ID)
            gateway = self.gateway('/book/getprogress', bookId=BOOK_ID)
            self.assertEqual(web, gateway)
            self.assertEqual(web[0], 200)
        self.assertEqual(self.request('/__control', dict(progress_response='unknown'))[0], 400)

    def test_txt_marker_and_two_shards_preserve_original_plaintext(self):
        self.server.content_format='txt'
        try:
            params=dict(b=weread_e(BOOK_ID),c=weread_e(2))
            code,marker=self.request('/web/book/chapter/e_0',params)
            self.assertEqual((code,marker),(200,dict(bookId=BOOK_ID,chapterUid=2)))
            parts=[self.request('/web/book/chapter/'+name,params)[1].decode() for name in ('t_0','t_1')]
            self.assertEqual(decode_content_shards(*parts,''),chapter_txt(2))
            self.assertIn('<tag>',chapter_txt(2));self.assertIn('&amp;',chapter_txt(2))
            self.assertEqual(self.request('/web/book/chapter/e_1',params)[0],501)
            other=dict(params,b=weread_e('900002'))
            self.assertEqual(self.request('/web/book/chapter/e_0',other)[1]['bookId'],'900002')
        finally:
            self.server.content_format='epub'

    def test_active_requests_track_delayed_transport_and_route_failure(self):
        entered,release=threading.Event(),threading.Event()
        original=self.server.route
        def held(method,target,data):
            if target=='https://weread.qq.com/mock/cover.png':
                entered.set()
                if not release.wait(3):raise ValueError('synthetic route gate timed out')
            return original(method,target,data)
        results=[]
        worker=threading.Thread(target=lambda: results.append(self.request('/mock/cover.png')))
        with patch.object(self.server,'route',side_effect=held):
            worker.start()
            try:
                self.assertTrue(entered.wait(2))
                self.assertEqual(self.request('/__state')[1]['active_requests'].get('https://weread.qq.com/mock/cover.png'),1)
            finally:
                release.set();worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(results[0][0],200)
        self.assertEqual(self.request('/__state')[1]['active_requests'],{})
        self.assertEqual(self.request('/not-implemented')[0],501)
        self.assertEqual(self.request('/__state')[1]['active_requests'],{})

    def test_mp_article_versions_keep_identity(self):
        code, first = self.request('/web/mp/content?reviewId=background-fixture')
        self.assertEqual(code, 200)
        self.assertIn('合成版本 1', first.decode('utf-8'))
        self.assertEqual(self.request('/__control', dict(mp_article_version=2))[0], 200)
        code, second = self.request('/web/mp/content?reviewId=background-fixture')
        self.assertEqual(code, 200)
        self.assertIn('合成版本 2', second.decode('utf-8'))
        self.assertNotEqual(first, second)
        self.assertEqual(self.request('/__control', dict(mp_article_version=True))[0], 400)

    def test_mp_verification_failure_after_successful_web_renewal(self):
        code,result=self.request('/web/login/renewal',dict(rq='%2Fweb%2Fbook%2Fread',ql=False))
        self.assertEqual((code,result),(200,{'succ':1}))
        code,result=self.request('/web/mp/articles?bookId=MP_WXS_900001&maxIdx=0&count=100')
        self.assertEqual(code,200)
        self.assertEqual(result['errCode'],-2041)
        self.assertEqual(self.request('/web/login/renewal',{})[0],400)

    def test_lifetime_counts_survive_bounded_event_log(self):
        server=MockServer(0)
        try:
            for _ in range(510):server.record({'path':'/synthetic/counter','api':None,'method':'GET','status':200})
            self.assertEqual(len(server.events),500)
            self.assertEqual(server.request_totals[('/synthetic/counter','')],510)
            for index in range(255):server.record({'path':f'/synthetic/counter-{index}','api':'fixed','method':'GET','status':200})
            with self.assertRaises(ValueError):server.record({'path':'/capacity-exceeded','api':None})
            self.assertEqual(len(server.request_totals),256)
        finally:server.server_close()

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

    def test_cb_metadata_fixture_is_readable_without_joining_the_shelf_or_content_scope(self):
        identity='CB_SyntheticMetadata'
        status,value=self.server.route('GET','https://i.weread.qq.com/book/info?bookId='+identity,{})
        self.assertEqual(status,200);self.assertEqual(value['bookId'],identity);self.assertEqual(value['totalWords'],12000)
        status,page=self.server.route('GET','https://weread.qq.com/web/reader/'+weread_e(identity),{})
        self.assertEqual(status,200);self.assertIn(identity,page)
        _,shelf=self.server.route('GET','https://i.weread.qq.com/shelf/sync',{})
        self.assertNotIn(identity,{row['bookId'] for row in shelf['books']})
        with self.assertRaises(ValueError):self.server.route('POST','https://weread.qq.com/web/book/chapterInfos',dict(bookIds=[identity]))

    def test_cb_reading_fixture_requires_explicit_opt_in_and_never_expands_native_membership(self):
        from mock_weread import CB_READING_ID
        identity=CB_READING_ID
        with self.assertRaises(ValueError):self.server.route('POST','https://weread.qq.com/web/book/chapterInfos',dict(bookIds=[identity]))
        self.server.cb_reading=True
        _,shelf=self.server.route('GET','https://weread.qq.com/web/shelf/sync',{})
        self.assertEqual(sum(row['bookId']==identity for row in shelf['books']),1)
        _,catalog=self.server.route('POST','https://weread.qq.com/web/book/chapterInfos',dict(bookIds=[identity]))
        self.assertEqual(len(catalog['data'][0]['updated']),6)
        _,page=self.server.route('GET','https://weread.qq.com/web/reader/'+weread_e(identity),{})
        self.assertIn(identity,page)
        for part in ('e_0','e_1','e_2','e_3'):
            status,value=self.server.route('POST','https://weread.qq.com/web/book/chapter/'+part,dict(b=weread_e(identity),c=weread_e('2')))
            self.assertEqual(status,200);self.assertIsInstance(value,str)
        with self.assertRaises(ValueError):self.server.route('POST','https://i.weread.qq.com/shelf/add',dict(bookIds=[identity]))
        self.server.cb_reading=False
        _,shelf=self.server.route('GET','https://weread.qq.com/web/shelf/sync',{})
        self.assertNotIn(identity,{row['bookId'] for row in shelf['books']})

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
