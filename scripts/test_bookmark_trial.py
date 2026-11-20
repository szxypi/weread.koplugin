"""Two-slot point-bookmark trial; no real credentials or remote requests."""
from contextlib import redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
import unittest
from unittest.mock import Mock,patch
from bookmark_trial_model import bind,observe,validate_plan
from secure_bookmark_trial import BookmarkTrialStore
from secure_highlight_trial import HighlightTrialStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_selection_trial import fixture
from verify_bookmark_trial import BookmarkProbe,main
from verify_eink_login import ProbeError


class BookmarkTrialTests(unittest.TestCase):
    def fixture(self):
        payload,plan=fixture();source=Mock();source.payload=payload;source.plan=plan;source.prepare.return_value=plan
        source.baseline.return_value=plan.baseline;raw='<body><p>Unique bookmark context and some following source text.</p></body>'
        source.payload['source_raw_sha256']=hashlib.sha256(raw.encode()).hexdigest();source.payload['selection_preview']['first']=9
        source.web.shards=dict(e_0='synthetic',e_1='synthetic',e_3='synthetic')
        store=BookmarkTrialStore(Backend());probe=BookmarkProbe(source,store)
        with patch('verify_bookmark_trial.decode_content_shards',return_value=raw):probe.prepare({},{})
        added=deepcopy(plan.baseline);added['marks']['updated']['new-bookmark']=dict(bookmarkId='new-bookmark',type=0,chapterUid=2,style=0,colorStyle=0,range=probe.body['range'])
        return probe,source,store,plan,added

    def test_body_uses_point_type_and_omits_color_and_guessed_native_index(self):
        p,_s,_store,_plan,_added=self.fixture()
        self.assertEqual(set(p.body),{'bookId','chapterUid','bookVersion','type','style','range','markText'})
        self.assertEqual((p.body['type'],p.body['style'],p.body['range']),(0,0,'9'))

    def test_missing_bookmark_text_is_not_synthesized_as_server_returned_text(self):
        p,_s,_store,plan,added=self.fixture();target=observe(plan.baseline,added,p.body)
        self.assertEqual(target['id'],'new-bookmark');self.assertNotIn('markText',added['marks']['updated'][target['id']])
        for field,value in [('range','10'),('type',1),('chapterUid',3),('style',1),('markText','Other text')]:
            bad=deepcopy(added);bad['marks']['updated']['new-bookmark'][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):observe(plan.baseline,bad,p.body)

    def test_original_collections_and_new_target_fingerprint_are_protected(self):
        p,_s,_store,plan,added=self.fixture();target=observe(plan.baseline,added,p.body)
        for group in ('shelf','position','thoughts'):
            bad=deepcopy(added);bad[group]['other']={}
            with self.subTest(group=group),self.assertRaises(ValueError):observe(plan.baseline,bad,p.body)
        added['marks']['updated']['new-bookmark']['createTime']=2
        with self.assertRaises(ValueError):observe(plan.baseline,added,p.body,target=target)

    def test_readonly_has_no_reservation_or_dispatch(self):
        p,source,store,plan,_added=self.fixture()
        with patch('verify_bookmark_trial.reading_position',return_value=plan.web_position):r=p.run({})
        self.assertEqual(r['account_data_posts'],0);self.assertEqual(store.read(),(None,None));source.writer.request.assert_not_called()

    def test_two_writes_roundtrip_and_independent_position_check(self):
        p,source,store,plan,added=self.fixture();source.notes.observe.side_effect=[added,added,plan.baseline]
        with patch('verify_bookmark_trial.reading_position',return_value=plan.web_position):r=p.run({},apply=True)
        self.assertEqual(r['account_data_posts'],2);self.assertTrue(r['source_position_roundtrip']);self.assertFalse(r['bookmark_text_returned'])
        self.assertEqual(store.read(),(None,None));self.assertEqual(source.writer.request.call_count,2)

    def test_lost_receipt_is_read_without_replay(self):
        p,source,store,plan,added=self.fixture();source.notes.observe.side_effect=[added,added,plan.baseline];source.writer.request.side_effect=ProbeError('lost')
        with patch('verify_bookmark_trial.reading_position',return_value=plan.web_position):p.run({},apply=True)
        self.assertEqual(source.writer.request.call_count,2);self.assertEqual(store.read(),(None,None))

    def test_pending_cannot_replay_or_switch_protocol(self):
        p,source,store,plan,_added=self.fixture();source.notes.observe.side_effect=[plan.baseline]*3
        with self.assertRaises(ValueError):p.run({},apply=True)
        self.assertEqual(store.read()[0]['phase'],'create_pending');self.assertEqual(p.posts,1)
        with self.assertRaises(StoreError):store.reserve(p.bound)
        with self.assertRaises(ValueError):p.post({},'create_pending','/book/addBookmark',p.body)
        with self.assertRaises(ValueError):HighlightTrialStore(Backend()).reserve(p.bound)
        with self.assertRaises(ValueError):BookmarkTrialStore(Backend(),native=True).reserve(p.bound)
        self.assertEqual(validate_plan(bind(plan.bound,p.body)),p.bound)

    def test_default_never_opens_account_or_keychain(self):
        with patch('verify_bookmark_trial.SessionStore') as saved,redirect_stdout(io.StringIO()) as out:self.assertEqual(main([]),0)
        saved.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
