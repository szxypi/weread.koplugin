"""Offline boundaries for unmarked source selection and zero-write native proof."""
from contextlib import redirect_stdout,redirect_stderr
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import MagicMock,patch

import owner_selection_preview as contract
import verify_owner_selection_preview as task
from annotation_experiment_model import note_text
from test_owner_reading import OWNER,COOKIES,stage,frame

RAW='<body><p>Unique source text for a completely new selection 😀 and extra letters for independent checks.</p></body>'


def payload():
    selected=contract.choose(RAW,{},'41','2',2);row=selected['reference']
    return dict(vid=OWNER,book_id='41',chapter_uid='2',source_format='web_xhtml',source_raw_sha256=hashlib.sha256(RAW.encode()).hexdigest(),
        cookies=COOKIES.copy(),selection_preview=dict(first=selected['first'],last=selected['last'],reference=row,
            credentials=dict(vid=OWNER,accessToken='synthetic-native-access',refreshToken='synthetic-native-refresh',deviceId='eink334691225'+'1'*19),
            body=dict(bookId='41',chapterUid='2',bookVersion=700,type=1,range=row['range'],abstract=row['markText'],isPrivate=1,content=note_text('1'*32))))


def addon(mode):
    live=mode=='live';value=dict.fromkeys(contract.FLAGS,True)
    for key in ('live_preflight','exact_body','blocked_dispatch','repeat_submit_blocked'):value[key]=live
    value['fresh_offline_restore']=not live
    value.update(native_gets=7 if live else 0,blocked_posts=int(live),native_denied=0,account_data_posts=0,failed_line=0,phase='complete')
    return value


def envelope():
    cfg=payload()['selection_preview'];stages=[stage(),stage('reopen')];privates=[]
    for row in stages:
        row['selection_preview']=addon(row['mode'])
        privates.append(dict(reference=copy.deepcopy(cfg['reference']),body=copy.deepcopy(cfg['body']) if row['mode']=='live' else None,
            native_text=cfg['reference']['markText'],draft_text=cfg['body']['content']))
    return dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,runner_error='none',stages=stages,
        installed_package=dict(files=236,bytes_match=True)),cookies=COOKIES.copy(),selection_private=privates)


class SelectionPreviewTests(unittest.TestCase):
    def test_point_bookmarks_are_exclusions_without_becoming_text_ranges(self):
        selected=contract.choose(RAW,{},'41','2',2);first=int(selected['reference']['range'].split('-')[0])
        extended=RAW.replace('</body>','<p>Another unique paragraph with sufficient plain letters for the bookmark point exclusion.</p></body>')
        marks={'point':dict(type=0,chapterUid=2,range=str(first))}
        other=contract.choose(extended,marks,'41','2',2);a,b=map(int,other['reference']['range'].split('-'))
        self.assertFalse(a<=first<b)
        marks['point']['range']='01'
        with self.assertRaises(ValueError):contract.choose(extended,marks,'41','2',2)

    def test_selects_unique_unmarked_raw_range_with_source_coordinates(self):
        value=contract.choose(RAW,{},'41','2',2);row=value['reference'];a,b=map(int,row['range'].split('-'))
        self.assertEqual(RAW[a:b],row['markText'])
        emoji_raw=RAW.replace('<body>','<body><p>😀</p>',1)
        offset=contract.choose(emoji_raw,{},'41','2',2)
        self.assertNotEqual(int(offset['reference']['range'].split('-')[0]),offset['first'])
        excluded={'original':dict(chapterUid=2,range=row['range'])}
        other=contract.choose(RAW.replace('</body>','<p>Another unique paragraph with sufficient plain letters to avoid every existing saved mark.</p></body>'),excluded,'41','2',2)
        c,d=map(int,other['reference']['range'].split('-'));self.assertTrue(d<=a or c>=b)

    def test_no_disjoint_or_unique_source_is_rejected(self):
        for raw,marks in [(RAW,{'a':dict(chapterUid=2,range=f'0-{len(RAW)}')}),('<body><p>'+('a'*200)+'</p></body>',{}),
                          ('<body><p>'+('a'*41)+'</p></body>',{}),
                          ('<body>short</body>',{})]:
            with self.assertRaises(ValueError):contract.choose(raw,marks,'41','2',2)
        with self.assertRaises(ValueError):contract.choose(RAW,{'a':dict(chapterUid=2,range='unknown')},'41','2',2)

    def test_independent_native_text_reference_and_body_are_compared(self):
        e=envelope();self.assertTrue(contract.compare(e['selection_private'],RAW,payload()))
        for kind in ('native_text','reference','draft_text','body'):
            changed=envelope();value=changed['selection_private'][0]
            if kind=='reference':value[kind]['range']='1-2'
            elif kind=='body':value[kind]['bookVersion']=701
            else:value[kind]='different'
            with self.assertRaises(ValueError):contract.compare(changed['selection_private'],RAW,payload())

    def test_configuration_rejects_foreign_owner_source_body_and_native_index_guess(self):
        contract.validate_input(payload())
        for kind in ('owner','sha','chapter','private','index','extra'):
            p=payload();cfg=p['selection_preview']
            if kind=='owner':cfg['credentials']['vid']='900001'
            elif kind=='sha':cfg['reference']['source']['raw_sha256']='a'*64
            elif kind=='chapter':cfg['body']['chapterUid']='3'
            elif kind=='private':cfg['body']['isPrivate']=0
            elif kind=='index':cfg['body']['chapterIdx']=2
            else:cfg['cookie']='PRIVATE'
            with self.assertRaises(ValueError):contract.validate_input(p)

    def test_strict_public_proof_schema(self):
        contract.decode(frame(envelope()),OWNER)
        for key in contract.FLAGS:
            e=envelope();e['report']['stages'][0]['selection_preview'][key]=not addon('live')[key]
            with self.assertRaises(ValueError):contract.decode(frame(e),OWNER)
        for key,value in [('blocked_posts',0),('native_gets',True),('account_data_posts',1),('native_denied',1),('failed_line',1),('source_text','PRIVATE')]:
            e=envelope();e['report']['stages'][0]['selection_preview'][key]=value
            with self.assertRaises(ValueError):contract.decode(frame(e),OWNER)

    def test_cleanup_fresh_process_zero_http_and_package_match_required(self):
        for kind in ('cleanup','fresh','offline','package','content'):
            e=envelope()
            if kind=='cleanup':e['report']['profile_removed']=False
            elif kind=='fresh':e['report']['stages'].pop();e['selection_private'].pop()
            elif kind=='offline':e['report']['stages'][1]['selection_preview']['native_gets']=1
            elif kind=='package':e['report']['installed_package']['bytes_match']=False
            else:e['selection_private'][1]['draft_text']='changed'
            with self.assertRaises(ValueError):contract.decode(frame(e),OWNER)

    def test_private_extra_fields_and_offline_request_bodies_are_rejected(self):
        for kind in ('credentials','body','reference','text'):
            e=envelope();v=e['selection_private'][1]
            if kind=='credentials':v['credentials']='PRIVATE'
            elif kind=='body':v['body']=payload()['selection_preview']['body']
            elif kind=='reference':v['reference']['source']['chapter_idx']=True
            else:v['native_text']='different'
            with self.assertRaises(ValueError):contract.decode(frame(e),OWNER)

    def test_default_cannot_load_credentials_network_or_native_process(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'NativeSessionStore') as native,patch.object(task,'Preflight') as web,\
                patch.object(task,'AnnotationProbe') as notes,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        for mocked in (store,native,web,notes,child):mocked.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_installed_package_requires_equal_regular_files(self):
        from run_owner_reading_probe import check_installed
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);candidate=root/'candidate.zip';file=root/'profile/plugins/weread.koplugin/main.lua'
            file.parent.mkdir(parents=True);file.write_bytes(b'return {}')
            with zipfile.ZipFile(candidate,'w') as archive:archive.writestr('weread.koplugin/main.lua',b'return {}')
            self.assertEqual(check_installed(candidate,root/'profile'),dict(files=1,bytes_match=True))
            file.write_bytes(b'return {changed=true}')
            with self.assertRaises(ValueError):check_installed(candidate,root/'profile')
            file.unlink();target=root/'outside.lua';target.write_bytes(b'return {}');file.symlink_to(target)
            with self.assertRaises(ValueError):check_installed(candidate,root/'profile')

    def test_no_apply_renewal_or_unpaired_modes(self):
        for args in (['--apply'],['--saved-session'],['--native-ui-command','synthetic'],['--permit-renewal']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def run_saved(self,*,changed=False,failed=False):
        p=payload();saved=dict(vid=OWNER,cookies=COOKIES.copy());web=MagicMock();web.vid=OWNER;web.book_id='41'
        web.cookies={};web.chapters=[dict(chapterUid=2,chapterIdx=2)];web.report={'stages':[]};web.shards=dict.fromkeys(('e_0','e_1','e_3'),'synthetic')
        web.baseline={'position':'original'};web.prepare.return_value={k:v for k,v in p.items() if k not in ('selection_preview','vid','cookies')}
        notes=MagicMock();notes.report={'stages':[]};observed=dict(marks={'updated':{}},thoughts={},shelf={},position={})
        notes.observe.side_effect=[copy.deepcopy(observed),copy.deepcopy(observed),dict(observed,shelf={'changed':True}) if changed else copy.deepcopy(observed)]
        notes.request.return_value=dict(bookId='41',version=700)
        native=SimpleNamespace(returncode=int(failed),stdout=b'PRIVATE_DIAGNOSTIC' if failed else frame(envelope()),stderr=b'PRIVATE_DIAGNOSTIC')
        with patch.object(task,'SessionStore') as store,patch.object(task,'NativeSessionStore') as credentials,patch.object(task,'Preflight',return_value=web),\
                patch.object(task,'AnnotationProbe',return_value=notes),patch.object(task,'decode_content_shards',return_value=RAW),\
                patch.object(task,'reading_position',return_value=web.baseline),patch.object(task,'save_refreshed_web_session',return_value=True),\
                patch.object(task.secrets,'token_hex',return_value='1'*32),patch.object(task.subprocess,'run',return_value=native) as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.side_effect=lambda:copy.deepcopy(saved)
            credentials.return_value.load.return_value=copy.deepcopy(p['selection_preview']['credentials'])
            code=task.main(['--saved-session','--native-ui-command','synthetic'])
        return code,json.loads(out.getvalue()),child

    def test_complete_saved_preview_is_public_and_does_not_dispatch_python_writes(self):
        code,report,child=self.run_saved();self.assertEqual(code,0);self.assertEqual(child.call_count,1)
        self.assertTrue(report['production_submit_boundary']);self.assertEqual(report['account_data_posts'],0)
        for secret in (RAW,COOKIES['wr_skey'],'synthetic-native-access','selection_private','Unique source text'):
            self.assertNotIn(secret,json.dumps(report))

    def test_cloud_change_or_private_diagnostic_is_never_success_or_retried(self):
        for options in (dict(changed=True),dict(failed=True)):
            code,report,child=self.run_saved(**options);self.assertEqual(code,1);self.assertEqual(child.call_count,1)
            self.assertEqual(report['result'],'UNVERIFIED');self.assertNotIn('PRIVATE_DIAGNOSTIC',json.dumps(report))


if __name__=='__main__':unittest.main()
