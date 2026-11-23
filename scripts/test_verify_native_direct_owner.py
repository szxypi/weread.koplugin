"""Opt-in native-only owner verification and redacted reporting."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import verify_native_direct_owner as task


class NativeDirectOwnerTests(unittest.TestCase):
    def test_public_sample_excludes_shelf_and_paid_chapters(self):
        def sample(book,chapters):
            return {'book_id':book,'expected':{'format':'epub','version':1,'chapters':chapters}}
        selected=sample('42',[{'uid':1,'wordCount':900,'free_or_owned':False},
                              {'uid':2,'wordCount':900,'free_or_owned':True}])
        discovery=SimpleNamespace(samples=[sample('10',[{'uid':1,'wordCount':900,'free_or_owned':True}]),selected],
                                  inspect=lambda *_args:None)
        source=SimpleNamespace(archive_url=None,download=lambda url,_credentials:(url.encode(),'envelope'))
        with patch.object(task,'TranslationProbe',return_value=discovery),patch.object(task,'ChapterProbe',return_value=source),\
                patch.object(task,'password',return_value='password'),patch.object(task,'read',return_value={'html':True,'source':b'x'}):
            book,chapter,_body,keyword=task.select_public_sample({'vid':'123'}, {'10'})
        self.assertEqual(book,selected)
        self.assertEqual(chapter['uid'],2)
        self.assertIn('stopAutoPayWhenBNE=1',source.archive_url)
        self.assertIn('preview=0',source.archive_url)
        self.assertEqual(keyword,task.PUBLIC_QUERIES[0])

    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                patch.object(task,'ChapterProbe') as probe,patch.object(task.subprocess,'run') as child,\
                redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        saved.assert_not_called();native.assert_not_called();probe.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_private_payload_is_not_reported(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'<p>private text</p>'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,offline_reopen=True,
            offline_network_guard=True,web_coordinates=False,manual_time_blocked=True,credential_file_audit=True,
            installed_bytes_match=True,missing_images=0,warning_verified=True)
        child=SimpleNamespace(returncode=0,stdout=task.FRAME+json.dumps(result).encode()+b'\n')
        with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child) as run,\
                redirect_stdout(io.StringIO()) as output:
            saved.return_value.load.return_value={'vid':'123'}
            native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
            self.assertEqual(task.main(['--saved-session','--lua-command','runner']),0)
        self.assertIn('private-token',run.call_args.kwargs['input'].decode())
        for value in ('private-token','private text','"42"'):
            self.assertNotIn(value,output.getvalue())
        report=json.loads(output.getvalue())
        self.assertEqual(report['result'],'NATIVE_DIRECT_OWNER_READONLY_VERIFIED')
        self.assertTrue(report['offline_network_guard'])

    def test_explicit_session_requires_private_command(self):
        with self.assertRaises(SystemExit),redirect_stdout(io.StringIO()):task.main(['--saved-session'])

    def test_home_requires_every_private_verification(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'<p>private text</p>'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,home_record=True,
            offline_home_resume=True,page_restored=True,network_blocked=True,credential_file_audit=True,installed_bytes_match=True)
        marker=b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
        for valid in (True,False):
            result['page_restored']=valid
            child=SimpleNamespace(returncode=0,stdout=marker+json.dumps(result).encode()+b'\n')
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123'}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                self.assertEqual(task.main(['--saved-session','--home','--lua-command','runner']),0 if valid else 1)
            report=json.loads(output.getvalue())
            self.assertEqual(report['result'],'NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED' if valid else 'UNVERIFIED')
            self.assertNotIn('private text',output.getvalue())
            self.assertNotIn('private-token',output.getvalue())

    def test_full_ui_cannot_be_claimed_by_fixture_only_runner(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'<p>private text</p>'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,home_record=True,
            offline_home_resume=True,page_restored=True,network_blocked=True,credential_file_audit=True,installed_bytes_match=True)
        marker=b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
        for full in (False,True):
            if full:result['full_ui']=True
            child=SimpleNamespace(returncode=0,stdout=marker+json.dumps(result).encode()+b'\n')
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123'}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                self.assertEqual(task.main(['--saved-session','--home','--home-full-ui','--lua-command','runner']),0 if full else 1)
            self.assertEqual(json.loads(output.getvalue())['result'],
                'NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED' if full else 'UNVERIFIED')

    def test_home_web_progress_is_independently_compared(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'<p>private text</p>'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,home_record=True,
            offline_home_resume=True,page_restored=True,network_blocked=True,credential_file_audit=True,installed_bytes_match=True,
            full_ui=True)
        marker=b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
        child=SimpleNamespace(returncode=0,stdout=marker+json.dumps(result).encode()+b'\n')
        for changed in (False,True):
            calls=[]
            web=SimpleNamespace(cookies=SimpleNamespace(clear=lambda:None),set_cookie=lambda *_args:None,
                verify_account=lambda:None,request=lambda stage,*_args: calls.append(stage) or {'stage':stage})
            def project(value,*_args,**_kwargs):
                return 2 if changed and value['stage']=='progress_after' else 1
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'WebSourceProbe',return_value=web),patch.object(task,'reading_position',side_effect=project),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123','cookies':{'wr_skey':'private-token'}}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                code=task.main(['--saved-session','--home','--home-full-ui','--compare-web-progress','--lua-command','runner'])
            self.assertEqual(code,1 if changed else 0)
            self.assertEqual(calls,['progress_before','progress_after'])
            report=json.loads(output.getvalue())
            self.assertEqual(report['result'],'UNVERIFIED' if changed else 'NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED')
            self.assertEqual(report.get('web_position_unchanged'),None if changed else True)
            self.assertNotIn('private-token',output.getvalue())

    def test_store_search_requires_off_shelf_result_and_web_shelf_recheck(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]})
        result=dict(result='PASS',profile_removed=True,native_requests=7,source_matches=True,home_record=True,
            offline_home_resume=True,page_restored=True,network_blocked=True,credential_file_audit=True,installed_bytes_match=True,
            full_ui=True,store_search=True,inline_style_verified=True)
        child=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_DIRECT_HOME_OWNER_RUN='+json.dumps(result).encode()+b'\n')
        for changed in (False,True):
            calls=[]
            web=SimpleNamespace(cookies=SimpleNamespace(clear=lambda:None),set_cookie=lambda *_args:None,
                verify_account=lambda:None,request=lambda stage,*_args: calls.append(stage) or {'stage':stage})
            def shelf_hash(value):
                if changed and value.get('stage')=='shelf' and calls.count('shelf')==2:return 'changed'
                return 'same'
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',side_effect=shelf_hash),\
                    patch.object(task,'shelf_ids',return_value=['2']),patch.object(task,'WebSourceProbe',return_value=web),\
                    patch.object(task,'observation',return_value={'position_present':False}),\
                    patch.object(task,'select_public_sample',return_value=(sample,{'uid':37},
                        {'html':True,'source':b'<style>p{color:red}</style><p>private</p>'},'Synthetic')),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child) as run,\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123','cookies':{'wr_skey':'private-token'}}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                code=task.main(['--saved-session','--home','--home-full-ui','--compare-web-progress','--store-search','--lua-command','runner'])
            self.assertEqual(code,1 if changed else 0)
            self.assertEqual(calls,['shelf','progress_before','progress_after','shelf'])
            report=json.loads(output.getvalue())
            self.assertEqual(report['result'],'UNVERIFIED' if changed else 'NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED')
            self.assertEqual(report.get('store_search'),None if changed else True)
            self.assertNotIn('private-token',output.getvalue())
            self.assertIn('store_search_keyword',run.call_args.kwargs['input'].decode())

    def test_quick_search_requires_explicit_runner_result(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]})
        result=dict(result='PASS',profile_removed=True,native_requests=8,source_matches=True,home_record=True,
            offline_home_resume=True,page_restored=True,network_blocked=True,credential_file_audit=True,installed_bytes_match=True,
            full_ui=True,store_search=True,inline_style_verified=True)
        for checked in (False,True):
            if checked:result['quick_search']=True
            child=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_DIRECT_HOME_OWNER_RUN='+json.dumps(result).encode()+b'\n')
            web=SimpleNamespace(cookies=SimpleNamespace(clear=lambda:None),set_cookie=lambda *_args:None,
                verify_account=lambda:None,request=lambda *_args:{})
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'shelf_ids',return_value=['2']),patch.object(task,'WebSourceProbe',return_value=web),\
                    patch.object(task,'observation',return_value={'position_present':False}),\
                    patch.object(task,'select_public_sample',return_value=(sample,{'uid':37},
                        {'html':True,'source':b'<style>p{color:red}</style><p>private</p>'},'Synthetic')),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123','cookies':{'wr_skey':'private-token'}}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                code=task.main(['--saved-session','--home','--home-full-ui','--compare-web-progress','--store-search',
                                '--quick-search','--lua-command','runner'])
            self.assertEqual(code,0 if checked else 1)
            self.assertEqual(json.loads(output.getvalue()).get('quick_search_verified'),True if checked else None)

    def test_offline_search_requires_explicit_result_and_rechecks_progress(self):
        rows=[dict(uid=37,wordCount=900,free_or_owned=True),dict(uid=38,wordCount=900,free_or_owned=True)]
        sample={'book_id':'42','expected':{'format':'epub','version':1,'chapters':rows}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,rows[0],{'html':True,'source':b'private first'}),
            download=lambda *_args:(b'archive','envelope'))
        result=dict(result='PASS',profile_removed=True,native_requests=7,source_matches=True,offline_reopen=True,
            offline_network_guard=True,web_coordinates=False,manual_time_blocked=True,credential_file_audit=True,
            installed_bytes_match=True,missing_images=0,warning_verified=True,neighbor_matches=True,
            neighbor_offline_roundtrip=True,neighbor_missing_images=0)
        for checked,changed in ((False,False),(True,False),(True,True)):
            if checked:result['offline_search']=True
            child=SimpleNamespace(returncode=0,stdout=task.FRAME+json.dumps(result).encode()+b'\n')
            calls=[]
            web=SimpleNamespace(cookies=SimpleNamespace(clear=lambda:None),set_cookie=lambda *_args:None,
                verify_account=lambda:None,request=lambda stage,*_args:calls.append(stage) or {})
            def position(*_args,**_kwargs):
                return {'offset':2 if changed and calls[-1]=='progress_after' else 1}
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'WebSourceProbe',return_value=web),patch.object(task,'reading_position',side_effect=position),\
                    patch.object(task,'password',return_value='password'),patch.object(task,'read',return_value={'source':b'private second'}),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123','cookies':{'wr_skey':'private-token'}}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                code=task.main(['--saved-session','--neighbor','--offline-search','--compare-web-progress','--lua-command','runner'])
            self.assertEqual(code,0 if checked and not changed else 1)
            self.assertEqual(calls,['progress_before','progress_after'] if checked else ['progress_before'])
            report=json.loads(output.getvalue())
            self.assertEqual(report.get('offline_search_verified'),True if checked and not changed else None)
            self.assertNotIn('private',output.getvalue())

    def test_copy_check_requires_proof_and_unchanged_web_position(self):
        rows=[dict(uid=37,wordCount=900,free_or_owned=True),dict(uid=38,wordCount=900,free_or_owned=True)]
        sample={'book_id':'42','expected':{'format':'epub','version':1,'chapters':rows}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,rows[0],{'html':True,'source':b'private first'}),
            download=lambda *_args:(b'archive','envelope'))
        result=dict(result='PASS',profile_removed=True,native_requests=7,source_matches=True,offline_reopen=True,
            offline_network_guard=True,web_coordinates=False,manual_time_blocked=True,credential_file_audit=True,
            installed_bytes_match=True,missing_images=0,warning_verified=True,neighbor_matches=True,
            neighbor_offline_roundtrip=True,neighbor_missing_images=0)
        for checked,reader_ok,changed in ((False,False,False),(True,False,False),(True,True,False),(True,True,True)):
            result.pop('copies_offline_verified',None);result.pop('copies_reader_positions',None)
            if checked:result['copies_offline_verified']=True
            if reader_ok:result['copies_reader_positions']=True
            child=SimpleNamespace(returncode=0,stdout=task.FRAME+json.dumps(result).encode()+b'\n')
            calls=[]
            web=SimpleNamespace(cookies=SimpleNamespace(clear=lambda:None),set_cookie=lambda *_args:None,
                verify_account=lambda:None,request=lambda stage,*_args:calls.append(stage) or {})
            def position(*_args,**_kwargs):
                return {'offset':2 if changed and calls[-1]=='progress_after' else 1}
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'WebSourceProbe',return_value=web),patch.object(task,'reading_position',side_effect=position),\
                    patch.object(task,'password',return_value='password'),patch.object(task,'read',return_value={'source':b'private second'}),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123','cookies':{'wr_skey':'private-token'}}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                code=task.main(['--saved-session','--neighbor','--copies','--compare-web-progress','--lua-command','runner'])
            self.assertEqual(code,0 if checked and reader_ok and not changed else 1)
            report=json.loads(output.getvalue())
            self.assertEqual(report.get('copies_offline_verified'),True if checked and reader_ok and not changed else None)
            self.assertNotIn('private',output.getvalue())

    def test_image_refresh_requires_proof_and_unchanged_web_position(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'private text'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,offline_reopen=True,
            offline_network_guard=True,web_coordinates=False,manual_time_blocked=True,credential_file_audit=True,
            installed_bytes_match=True,missing_images=1,warning_verified=True)
        for proof,resumed,changed in ((False,False,False),(True,False,False),(True,True,False),(True,True,True)):
            for key in ('image_refresh_verified','image_refresh_resumed','image_refresh_missing_before','image_refresh_missing_after'):
                result.pop(key,None)
            if proof:result.update(image_refresh_verified=True,image_refresh_missing_before=1,image_refresh_missing_after=0)
            if resumed:result['image_refresh_resumed']=True
            child=SimpleNamespace(returncode=0,stdout=task.FRAME+json.dumps(result).encode()+b'\n');calls=[]
            web=SimpleNamespace(cookies=SimpleNamespace(clear=lambda:None),set_cookie=lambda *_args:None,
                verify_account=lambda:None,request=lambda stage,*_args:calls.append(stage) or {})
            def position(*_args,**_kwargs): return {'offset':2 if changed and calls[-1]=='progress_after' else 1}
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'WebSourceProbe',return_value=web),patch.object(task,'reading_position',side_effect=position),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123','cookies':{'wr_skey':'private-token'}}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                code=task.main(['--saved-session','--image-refresh','--compare-web-progress','--lua-command','runner'])
            self.assertEqual(code,0 if proof and resumed and not changed else 1)
            report=json.loads(output.getvalue())
            self.assertEqual(report.get('image_refresh_verified'),True if proof and resumed and not changed else None)
            self.assertNotIn('private',output.getvalue())

    def test_online_search_requires_proof_and_unchanged_native_progress(self):
        rows=[dict(uid=37,wordCount=900,free_or_owned=True),dict(uid=38,wordCount=900,free_or_owned=True)]
        sample={'book_id':'42','expected':{'format':'epub','version':1,'chapters':rows}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,rows[0],{'html':True,'source':b'private first'}),
            download=lambda *_args:(b'archive','envelope'))
        result=dict(result='PASS',profile_removed=True,native_requests=7,source_matches=True,offline_reopen=True,
            offline_network_guard=True,web_coordinates=False,manual_time_blocked=True,credential_file_audit=True,
            installed_bytes_match=True,missing_images=0,warning_verified=True,neighbor_matches=True,
            neighbor_offline_roundtrip=True,neighbor_missing_images=0)
        for checked,changed,missing,missing_checked in ((False,False,False,False),(True,False,False,False),
                (True,True,False,False),(True,False,True,False),(True,False,True,True)):
            result.pop('online_search',None);result.pop('online_missing',None)
            if checked:result['online_search']=True
            if missing_checked:result['online_missing']=True
            child=SimpleNamespace(returncode=0,stdout=task.FRAME+json.dumps(result).encode()+b'\n')
            cookies=[SimpleNamespace(name='wr_vid',value='123'),SimpleNamespace(name='wr_skey',value='private-cookie')]
            web=SimpleNamespace(cookies=cookies,set_cookie=lambda *_args:None,verify_account=lambda:None,
                request=lambda *_args:{})
            progress_calls=[]
            native_probe=SimpleNamespace(request=lambda *_args,**_kwargs:progress_calls.append('read') or {'count':len(progress_calls)})
            def native_point(value,*_args):
                return {'chapter_offset':2 if changed and value['count']==2 else 1}
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'SearchProbe',return_value=web),patch.object(task,'reading_position',return_value={'offset':1}),\
                    patch.object(task,'password',return_value='password'),patch.object(task,'read',return_value={'source':b'private second'}),\
                    patch.object(task,'Native',return_value=native_probe),patch.object(task,'project',side_effect=native_point),\
                    patch.object(task,'find_node',return_value=dict(readingTime=1,recordReadingTime=1,ttsTime=0)),\
                    patch.object(task,'prepare_online_search',return_value={'keyword':'private text','allowed':[{}]}),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123','cookies':{'wr_skey':'private-token'}}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                flags=['--saved-session','--neighbor','--online-search','--compare-web-progress']
                if missing:flags.append('--online-missing')
                code=task.main(flags+['--lua-command','runner'])
            passed=checked and not changed and (not missing or missing_checked)
            self.assertEqual(code,0 if passed else 1)
            self.assertEqual(len(progress_calls),2 if checked and (not missing or missing_checked) else 1)
            report=json.loads(output.getvalue())
            self.assertEqual(report.get('online_search_verified'),True if passed else None)
            self.assertEqual(report.get('missing_download_verified'),True if passed and missing else None)
            self.assertNotIn('private',output.getvalue())


if __name__=='__main__':unittest.main()
