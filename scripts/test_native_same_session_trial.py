"""Host gate requires the exact new target, unchanged shelf and full proof."""
from copy import deepcopy
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from combined_upload_read_trial import SameSessionJournal as Journal,prepare
from native_same_session_trial import launch,synthetic_source_verified
from synthetic_format_trial import TargetReceipt
from test_native_personal_upload_trial import FakeProbe
from test_native_personal_upload_ui_trial import stage as upload_stage
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials

TARGET='CB_synthetic'


def reading():
    return dict(book_id=TARGET,chapter_uid='1',source_format='web_xhtml',source_text='Synthetic source text long enough for native matching.',
        source_raw_sha256='a'*64,source_sample_offset=0,shelf_ids=['41',TARGET],shelf_books=2,cb_reading=True,vid='900000',
        cookies=dict(wr_vid='900000',wr_skey='mock_key'),combined_upload_read=True)


def result():
    upload=upload_stage(True);upload['target']=TARGET
    upload.update(continuous_reading=True,read_text_visible=True,read_page_turn=True,source_bytes_bound=True,
                  web_cookies=dict(wr_vid='900000',wr_skey='mock_key'))
    return dict(result='PASS',profile_removed=True,installed=dict(files=300,bytes_match=True),upload=upload,
                stages=[],error='none',cookies=dict(wr_vid='900000',wr_skey='mock_key'))


class CombinedTrialTest(unittest.TestCase):
    def test_distinct_scope_cannot_be_replayed(self):
        from secure_weread_session import StoreError
        journal=Journal(Backend());plan=prepare(credentials(),source(),'KOReaderSynthetic-0123456789abcdef.epub')
        receipt=journal.reserve(plan);receipt=journal.advance(receipt,'launched')
        target=TargetReceipt('epub',Backend(),scope='same-session-ui');target.record(journal,receipt,plan,TARGET)
        for phase in ('imported','cleanup_pending','restored'):
            receipt=journal.advance(receipt,phase,**({'target':TARGET} if phase=='imported' else {}))
        with self.assertRaises(StoreError):journal.reserve(plan)
        with self.assertRaises(ValueError):TargetReceipt('pdf',Backend(),scope='same-session-ui')

    def test_source_binds_every_synthetic_passage_in_order(self):
        import io,zipfile
        from synthetic_upload_epub import build_reading
        with zipfile.ZipFile(io.BytesIO(build_reading())) as archive:source_html=archive.read('EPUB/chapter.xhtml').decode()
        self.assertTrue(synthetic_source_verified(source_html))
        self.assertFalse(synthetic_source_verified(source_html.replace('Passage 17 has an individual opening','Changed passage')))
        self.assertFalse(synthetic_source_verified(source_html.replace('</body>','<p>Passage 48 has an individual opening for safe position checks.</p></body>')))
        self.assertFalse(synthetic_source_verified(None))
    def exercise(self,*,changed=False,bad_result=False):
        grant=credentials();plan=prepare(grant,source(),'KOReaderSynthetic-0123456789abcdef.epub')
        journal=Journal(Backend());receipt=journal.reserve(plan);journal.advance(receipt,'launched')
        class GateProbe(FakeProbe):
            def shelf(self,credentials):
                value=super().shelf(credentials)
                if self.reads==1:value['books']=[row for row in value['books'] if row['bookId']!=TARGET]
                elif changed:value['books'][0]['secret']=1
                return value
        owned=TargetReceipt('epub',Backend(),scope='same-session-ui');probe=GateProbe();probe.grant_check=lambda _:True
        probe.state['books'].append(dict(bookId=TARGET,title='Synthetic',finishReading=0))
        output=result()
        if bad_result:output['upload']['read_page_turn']=False
        frames=SimpleNamespace(next=unittest.mock.Mock(side_effect=[('STEP',dict(seq=1,target=TARGET)),('RESULT',output)]))
        child=SimpleNamespace(stdin=object(),stdout=object(),wait=lambda timeout:0)
        with patch('native_same_session_trial.upload_preview',return_value={'preview':True}), \
             patch('native_same_session_trial.subprocess.Popen',return_value=child), \
             patch('native_same_session_trial.Frames',return_value=frames), \
             patch('native_same_session_trial.write_initial'),patch('native_same_session_trial.reply') as sent, \
             patch('native_same_session_trial.stop') as stopped, \
             patch('native_same_session_trial._prepare_read',return_value=(reading(),{'chapter':'0','offset':0,'percent':0})) as preflight, \
             patch('native_same_session_trial._verify_after',return_value=True) as after:
            if changed or bad_result:
                with self.assertRaises(ValueError):launch(plan,grant,journal,owned,probe,store=object())
            else:
                value=launch(plan,grant,journal,owned,probe,store=object());self.assertEqual(value['target'],TARGET)
            self.assertIsNotNone(owned.backend.load());stopped.assert_called_once_with(child)
            if changed:sent.assert_not_called();preflight.assert_not_called();after.assert_not_called()
            elif bad_result:sent.assert_called_once();after.assert_not_called()
            else:sent.assert_called_once();preflight.assert_called_once();after.assert_called_once()

    def test_matching_target_and_complete_proof_succeed(self):self.exercise()
    def test_foreign_shelf_change_stops_before_reader(self):self.exercise(changed=True)
    def test_incomplete_live_proof_is_not_accepted(self):self.exercise(bad_result=True)


if __name__=='__main__':unittest.main()
