import copy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import Mock,patch
from cloud_pin_contract import valid_metadata
from run_owner_cloud_pin_preview import validate_payload
from test_native_finish_trial import stage
from test_secure_native_session import credentials
from test_shelf_flag_change import source,point
from verify_cloud_pin_model import plans
from imported_pin_preview_model import plans as imported_plans, valid_metadata as valid_imported_metadata, observation_hash
from verify_eink_login import BASE
import verify_owner_cloud_pin_preview as task


def payload():
    mark,restore=plans(source(),point(),'41')
    return dict(credentials=credentials(),book_id='41',expected_metadata=dict(bookId='41',title='Synthetic'),
                shelf_books=2,mark=mark,restore=restore,permit_writes=False,rpc_token='a'*32)


class PayloadTests(unittest.TestCase):
    def test_payload_is_precise_and_write_disabled(self):
        value=payload();self.assertTrue(valid_metadata(value['mark']));self.assertEqual(validate_payload(value),value)
        for mutate in (lambda x:x.update(permit_writes=True),lambda x:x.update(book_id='42'),
                       lambda x:x['mark'].update(before=True),lambda x:x['restore'].update(position_hash='f'*64),
                       lambda x:x.update(extra=True),lambda x:x['credentials'].update(vid='invalid')):
            item=copy.deepcopy(value);mutate(item)
            with self.subTest(item=list(item)),self.assertRaises(Exception):validate_payload(item)
    def test_pin_metadata_rejects_malformed_and_alternate_true_hash(self):
        value=payload()['mark'];self.assertTrue(valid_metadata(value))
        for mutate in (lambda x:x.update(desired=1),lambda x:x.update(alternate_hash='a'*64),
                       lambda x:x.update(before=0),lambda x:x.update(book_id='CB_1')):
            item=copy.deepcopy(value);mutate(item);self.assertFalse(valid_metadata(item))
    def test_imported_preview_is_explicit_and_write_runner_remains_closed(self):
        shelf=source();shelf['books'][0]['bookId']='CB_synthetic';shelf['archive'][0]['bookIds'][0]='CB_synthetic'
        progress=point();progress['book']['bookId']='CB_synthetic';progress.update(readingTime=12,ttsTime=0)
        mark,restore=imported_plans(shelf,progress,'CB_synthetic')
        value=payload();value.update(book_id='CB_synthetic',expected_metadata={'bookId':'CB_synthetic','title':'Synthetic'},mark=mark,restore=restore)
        self.assertTrue(valid_imported_metadata(mark))
        self.assertEqual(validate_payload(value,allow_imported=True),value)
        with self.assertRaises(ValueError):validate_payload(value)
        changed=copy.deepcopy(progress);changed['readingTime']=13
        self.assertNotEqual(observation_hash(changed,'CB_synthetic'),mark['position_hash'])
        changed=copy.deepcopy(progress);changed['book']['updateTime']=123
        self.assertEqual(observation_hash(changed,'CB_synthetic'),mark['position_hash'])
        changed=copy.deepcopy(progress);changed['book']['summary']=None
        with self.assertRaises(ValueError):observation_hash(changed,'CB_synthetic')
        numeric=payload()
        with self.assertRaises(ValueError):validate_payload(numeric,allow_imported=True)


class HostTests(unittest.TestCase):
    def test_only_exact_read_scope_is_permitted(self):
        probe=task.Probe();probe.target='41'
        for url,body in ((BASE+'/shelf/top',{}),(BASE+'/book/info?bookId=42',None),
                         (BASE+'/book/getProgress?bookId=41',{})):
            with self.subTest(url=url),self.assertRaises(ValueError):probe.request('bad',url,body,credentials={})

    def test_offline_default_does_not_read_accounts_or_network(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'NativeSessionStore') as native,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();native.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_writes'],0)
    def test_unexpected_step_cannot_trigger_reply_or_write(self):
        probe=Mock();child=Mock(stdin=io.BytesIO(),stdout=io.BytesIO());child.wait.return_value=0;sent=[]
        with patch.object(task,'check',return_value=True),patch.object(task.subprocess,'Popen',return_value=child),\
             patch.object(task,'Frames') as frames,patch.object(task,'write_initial') as write,patch.object(task,'stop'):
            frames.return_value.next.return_value=('STEP',{'seq':1})
            write.side_effect=lambda _stream,value:sent.append(copy.deepcopy(value))
            with self.assertRaises(ValueError):task.run(probe,credentials(),{},payload(),['synthetic'],lambda:None)
            self.assertIs(sent[0]['permit_writes'],False)
    def test_success_requires_bound_readback_and_zero_native_writes(self):
        probe=Mock();child=Mock(stdin=io.BytesIO(),stdout=io.BytesIO());child.wait.return_value=0
        result=dict(result='PASS',profile_removed=True,installed=dict(files=1,bytes_match=True),stage=stage(False))
        with patch.object(task,'check',return_value=True) as check,patch.object(task.subprocess,'Popen',return_value=child),\
             patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'stop'):
            frames.return_value.next.return_value=('RESULT',result)
            actual=task.run(probe,credentials(),{},payload(),['synthetic'],lambda:None)
        self.assertEqual(actual['result'],'OWNER_NATIVE_PIN_PREVIEW_VERIFIED');self.assertEqual(check.call_count,2)
        self.assertEqual(actual['native_ui']['stage']['native_posts'],0)
    def test_changed_initial_or_final_state_is_not_success(self):
        probe=Mock();child=Mock(stdin=io.BytesIO(),stdout=io.BytesIO());child.wait.return_value=0
        result=dict(result='PASS',profile_removed=True,installed=dict(files=1,bytes_match=True),stage=stage(False))
        with patch.object(task,'check',side_effect=[True,ValueError('changed')]),patch.object(task.subprocess,'Popen',return_value=child),\
             patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'stop'):
            frames.return_value.next.return_value=('RESULT',result)
            with self.assertRaises(ValueError):task.run(probe,credentials(),{},payload(),['synthetic'],lambda:None)


if __name__=='__main__':unittest.main()
