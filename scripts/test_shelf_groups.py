"""Offline group model, privacy and complete native-page proof boundaries."""
from contextlib import redirect_stdout,redirect_stderr
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from shelf_groups_contract import project,summary
from shelf_groups_ui_contract import COUNTS,FLAGS
from verify_persistent_ui import FRAME,decode_result,validate_stage
from test_persistent_ui import full_stage
from verify_shelf_groups import main


def shelf():
    return dict(books=[dict(bookId=str(i),title='Synthetic') for i in range(1,5)]+[dict(bookId='MP_WXS_1',title='Synthetic account')],
                archive=[dict(archiveId=1,name=' A ',bookIds=['2','1','2','missing']),
                         dict(archiveId=2,name='Empty',bookIds=[]),dict(archiveId=3,name='Account',bookIds=['MP_WXS_1'])])


def group_stage(mode='live'):
    value=full_stage(mode);value['shelf_groups']=6
    coverage=dict(groups=6,memberships=137,selected_groups=6,forward_pages=24,reverse_pages=18 if mode=='reopen' else 0,
                  selector_views=7,checked_memberships=137,empty_groups=0,**dict.fromkeys(FLAGS,True))
    value['group_coverage']=coverage;value['painted_views']+=24+coverage['reverse_pages']+7
    return value


class GroupTests(unittest.TestCase):
    def test_membership_deduplicates_and_preserves_reference_order(self):
        result=project(shelf())
        self.assertEqual(result,[dict(key='archive:1',label='A',members=['2','1']),dict(key='archive:2',label='Empty',members=[]),
                                 dict(key='__ungrouped__',label='Uncategorized',members=['3','4'])])
        self.assertEqual(summary(shelf(),result)['unavailable_references'],1)

    def test_unavailable_regular_references_do_not_hide_user_groups(self):
        source=shelf();source['archive']=[dict(archiveId=1,name='Missing',bookIds=['unknown']),dict(archiveId=2,name='Mixed',bookIds=['unknown','MP_WXS_1'])]
        self.assertEqual([group['members'] for group in project(source)],[[],[],['1','2','3','4']])

    def test_ungrouped_shelf_and_fallback_labels(self):
        source=shelf();source['archive']=[];self.assertEqual(project(source),[])
        source['archive']=[dict(name=' ',bookIds=[])]
        self.assertEqual(project(source,'未命名分组','未分组')[0],dict(key='name:未命名分组',label='未命名分组',members=[]))

    def test_wide_spaces_in_group_names_are_preserved(self):
        source=shelf();source['archive']=[dict(archiveId=1,name='　组名　',bookIds=[])]
        self.assertEqual(project(source)[0]['label'],'　组名　')

    def test_ambiguous_group_identity_is_not_accepted_as_a_reference(self):
        source=shelf();source['archive']*=2
        with self.assertRaises(ValueError):project(source)

    def test_schema_rejects_malformed_members_and_shelf(self):
        for source in ({},dict(books=[],archive={}),dict(books=[dict(bookId='1',title='Synthetic')],archive=[dict(bookIds=[True])])):
            with self.assertRaises(ValueError):project(source)

    def test_public_native_proof_requires_every_group_and_page(self):
        value=group_stage();self.assertEqual(validate_stage(value,'live',all_shelf_pages=True,all_groups=True),value)
        for key in COUNTS:
            bad=group_stage();bad['group_coverage'][key]=True
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(bad,'live',all_shelf_pages=True,all_groups=True)
        for key in FLAGS:
            bad=group_stage();bad['group_coverage'][key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(bad,'live',all_shelf_pages=True,all_groups=True)
        for key in ('selected_groups','checked_memberships','selector_views','reverse_pages'):
            bad=group_stage();bad['group_coverage'][key]+=1
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(bad,'live',all_shelf_pages=True,all_groups=True)

    def test_group_private_fields_and_wrong_scope_are_rejected(self):
        for key in ('title','book_id','raw','key'):
            value=group_stage();value['group_coverage'][key]='private'
            with self.assertRaises(ValueError):validate_stage(value,'live',all_shelf_pages=True,all_groups=True)
        with self.assertRaises(ValueError):validate_stage(group_stage(),'live',all_shelf_pages=True)
        with self.assertRaises(ValueError):validate_stage(group_stage(),'live',all_groups=True)

    def test_fresh_offline_proof_has_same_groups_and_no_network(self):
        value=dict(result='PASS',tmpfs_profile=True,profile_removed=True,runner_error='none',stages=[group_stage(),group_stage('reopen')])
        self.assertEqual(decode_result(FRAME+json.dumps(value).encode(),all_shelf_pages=True,all_groups=True),value)
        value['stages'][1]['group_coverage']['memberships']=136;value['stages'][1]['group_coverage']['checked_memberships']=136
        with self.assertRaises(ValueError):decode_result(FRAME+json.dumps(value).encode(),all_shelf_pages=True,all_groups=True)

    def test_default_offline_never_opens_stores_or_network(self):
        with patch('verify_shelf_groups.SessionStore') as store,patch('verify_shelf_groups.NativeSessionStore') as native,patch('verify_shelf_groups.WebFlagsProbe') as web,redirect_stdout(io.StringIO()):
            self.assertEqual(main([]),0)
        for mock in (store,native,web):mock.assert_not_called()
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(['--lua-command','synthetic'])

    def test_failure_output_has_no_private_capture(self):
        saved=dict(vid='900000',cookies={'wr_skey':'XXX'});credentials=dict(vid='900000',accessToken='synthetic-private-token')
        web=SimpleNamespace(vid=None,set_cookie=lambda *_:None,verify_account=lambda:None,request=lambda *_:shelf(),close=lambda:None,report=dict(stages=[]))
        native=SimpleNamespace(request=lambda *_a,**_k:shelf(),report=dict(stages=[]))
        with patch('verify_shelf_groups.SessionStore') as store,patch('verify_shelf_groups.NativeSessionStore') as ns,patch('verify_shelf_groups.WebFlagsProbe',return_value=web),patch('verify_shelf_groups.NativeFlagsProbe',return_value=native),patch('verify_shelf_groups.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=b'private-body')),redirect_stdout(io.StringIO()) as output:
            store.return_value.load.return_value=saved;ns.return_value.load.return_value=credentials
            self.assertEqual(main(['--saved-session','--lua-command','synthetic']),1)
        self.assertEqual(saved,{});self.assertEqual(credentials,{})
        self.assertNotIn('private-body',output.getvalue());self.assertNotIn('synthetic-private-token',output.getvalue());self.assertNotIn('900000',output.getvalue())


if __name__=='__main__':unittest.main()
