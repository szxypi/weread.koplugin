"""Single-operation preparation and full-state readback, no real account."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from finish_change_contract import flags,flags_hash,make,check,request
from test_annotation_experiment import shelf,position
from test_secure_native_session import credentials
from test_eink_login import Opener
from annotation_experiment_model import digest
import verify_finish_change as task


def two_books():
    value=shelf();value['books'].append(dict(bookId='42',title='Synthetic finished',finishReading=1,secret=0));return value


def other_position():
    value=position();value['book']['bookId']='42';return value


class FinishChangeTests(unittest.TestCase):
    def test_exact_bodies_and_opposite_readbacks(self):
        for before in (0,1):
            source=shelf();source['books'][0]['finishReading']=before;plan=make(source,position(),'41',not bool(before))
            self.assertEqual(plan['body'],dict(bookId='41',auto=0,finishInfo=0,isCancel=before,status=4))
            self.assertFalse(check(source,position(),plan['metadata']))
            source['books'][0]['finishReading']=1-before
            self.assertTrue(check(source,position(),plan['metadata']))

    def test_unrelated_flags_members_and_precise_position_cannot_be_hidden(self):
        source=two_books();plan=make(source,position(),'41',True)
        for mutation in ('member','other_finished','private','pinned','position','target_private'):
            after=deepcopy(source);after['books'][0]['finishReading']=1;progress=position()
            if mutation=='member':after['books'].pop()
            elif mutation=='other_finished':after['books'][1]['finishReading']=0
            elif mutation=='private':after['books'][1]['secret']=1
            elif mutation=='pinned':after['books'][1]['isTop']=1
            elif mutation=='position':progress=position(101)
            else:after['books'][0]['secret']=1
            with self.subTest(mutation=mutation):self.assertFalse(check(after,progress,plan['metadata']))

    def test_unknown_target_or_nonordinary_identity_is_refused(self):
        for value in (None,'0','1',2,[],{}):
            source=shelf();source['books'][0]['finishReading']=value
            with self.subTest(value=value),self.assertRaises(ValueError):make(source,position(),'41',True)
        for identity,desired in [('0',True),('CB_1',True),('41',1),(41,True),('41',None)]:
            with self.assertRaises(ValueError):request(identity,desired)

    def test_duplicates_invalid_ids_and_position_mismatch_are_refused(self):
        source=shelf();source['books'].append(deepcopy(source['books'][0]))
        with self.assertRaises(ValueError):flags(source)
        for identity in (True,None,[],9007199254740992):
            source=shelf();source['books'][0]['bookId']=identity
            with self.assertRaises(ValueError):flags(source)
        with self.assertRaises(ValueError):make(shelf(),other_position(),'41',True)
        for fields in [dict(errcode=1),dict(errCode=False),dict(succ=0),dict(errcode=None)]:
            with self.assertRaises(ValueError):flags(dict(shelf(),**fields))

    def test_unknown_unrelated_fields_are_bound_without_becoming_false(self):
        source=two_books();before=flags_hash(flags(source));source['books'][1]['isTop']='0'
        self.assertNotEqual(flags_hash(flags(source)),before)
        self.assertNotEqual(flags_hash(flags(source)),flags_hash(flags(two_books())))
        source['books'][1]['isTop']=None
        self.assertEqual(flags(source)['42']['pinned'],{'reason':'invalid'})
        with self.assertRaises(ValueError):make(source,position(),'41',True)

    def fixture(self,changed=False):
        final=two_books()
        if changed:final['books'][1]['secret']=1
        opener=Opener([two_books(),position(),other_position(),final,position(),other_position()]);probe=task.Preview(opener)
        return opener,probe

    def test_preparation_is_all_gets_and_plan_is_bound_to_independent_reads(self):
        opener,probe=self.fixture();payload=probe.prepare(credentials())
        self.assertEqual(len(payload['samples']),2);self.assertEqual(probe.gets,6)
        self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))
        self.assertEqual([row['plan']['metadata']['before'] for row in payload['samples']],[False,True])
        opener,probe=self.fixture(True)
        with self.assertRaises(ValueError):probe.prepare(credentials())
        self.assertEqual(len(opener.requests),4)

    def test_read_guard_has_no_write_or_other_endpoint_capability(self):
        opener,probe=self.fixture();probe.grant=digest(credentials())
        for body,path in [({},'/book/markstatus'),(None,'/book/getProgress?bookId=41'),(None,'/login'),(None,'/shelf/add')]:
            with self.assertRaises(ValueError):probe.request('invalid',task.BASE+path,body,credentials())
        self.assertFalse(opener.requests)

    def test_offline_mode_and_arguments_never_load_credentials(self):
        with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        web.assert_not_called();native.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--lua-command','forbidden'])
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--apply'])

    def test_captured_comparison_failure_redacts_data_and_never_dispatches(self):
        for bad in (False,True):
            opener,probe=self.fixture()
            def child(_command,**options):
                payload=json.loads(options['input']);plans=[row['plan'] for row in payload['samples']]
                return SimpleNamespace(returncode=int(bad),stdout=b'\nWEREAD_FINISH_CHANGE_RESULT='+json.dumps(plans).encode())
            with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,patch.object(task,'Preview',return_value=probe),patch.object(task.subprocess,'run',side_effect=child),redirect_stdout(io.StringIO()) as out:
                web.return_value.load.return_value=dict(vid='900000');native.return_value.load.return_value=credentials()
                self.assertEqual(task.main(['--saved-session','--lua-command','synthetic']),int(bad))
            public=out.getvalue()
            for value in ('Private title',credentials()['accessToken'],'chapter_offset','before_hash'):self.assertNotIn(value,public)
            self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))


if __name__=='__main__':unittest.main()
