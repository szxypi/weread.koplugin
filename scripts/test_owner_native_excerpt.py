"""Reader excerpt proof/privacy boundaries with synthetic account fixtures."""
from contextlib import redirect_stdout,redirect_stderr
import hashlib
import io
import json
import unittest
from unittest.mock import patch
from txt_coordinates import PlainSource
from test_owner_reading import OWNER,COOKIES,stage,frame
import owner_native_excerpt_contract as contract
import verify_owner_native_excerpt as task

RAW='\ufeffLiteral <tag>&amp;😀\r\n　 Exact source excerpts remain independent of display words.尾'


def records():
    rows=[];model=PlainSource(RAW)
    for name,co in zip(contract.STAGES,(1,8,3)):
        p=dict(book_id='900001',chapter_uid='11',chapter_offset=co,file_id='a'*64,book_version=7,
               raw_sha256=hashlib.sha256(RAW.encode()).hexdigest(),render_path='OEBPS/text/chapter.xhtml',
               basis='raw_txt_utf16',upload_verified=False)
        rows.append(dict(stage=name,packet=dict(position=p,excerpt=model.excerpt(co)),
                         legacy=dict(chapter_uid='11',chapter_idx=0,chapter_offset=2,percent=37)))
    return dict(records=rows)


def envelope():
    stages=[stage(),stage('reopen')]
    for row in stages:row['native_source_excerpt']=dict(**dict.fromkeys(contract.FLAGS,True),background_workers=3,excerpts=3,failed_line=0,
                                                     denied_shape=0,denied_checks=0,denied_api=0,currentness_checks=int(row['mode']=='live'))
    return dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,stages=stages,runner_error='none',
                            installed_package=dict(files=275,bytes_match=True)),cookies=COOKIES.copy(),candidate_private=[records(),records()])


def payload():return dict(book_id='900001',chapter_uid='11',source_raw_sha256=hashlib.sha256(RAW.encode()).hexdigest())


class NativeExcerptTests(unittest.TestCase):
    def test_complete_frame_and_independent_raw_model(self):
        value=contract.decode(frame(envelope()),OWNER)
        contract.compare(value['candidate_private'],RAW,payload())

    def test_all_proofs_required_with_strict_counts(self):
        for key in contract.FLAGS:
            v=envelope();v['report']['stages'][0]['native_source_excerpt'][key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):contract.decode(frame(v),OWNER)
        for key,bad in (('excerpts',2),('background_workers',True),('failed_line',1),('extra','private')):
            v=envelope();v['report']['stages'][0]['native_source_excerpt'][key]=bad
            with self.assertRaises(ValueError):contract.decode(frame(v),OWNER)

    def test_cleanup_package_and_offline_no_http_are_required(self):
        for change in ('profile','package','bytes','network'):
            v=envelope()
            if change=='profile':v['report']['profile_removed']=False
            elif change=='package':v['report'].pop('installed_package')
            elif change=='bytes':v['report']['installed_package']['bytes_match']=False
            else:v['report']['stages'][1]['requests'][0]=1
            with self.subTest(change=change),self.assertRaises(ValueError):contract.decode(frame(v),OWNER)

    def test_private_rows_cannot_change_basis_units_or_fields(self):
        for change in ({'basis':'filtered_xhtml_utf16'},{'chapter_offset':True},{'upload_verified':True},{'file_id':'bad'},{'summary':'private'}):
            v=envelope();v['candidate_private'][0]['records'][0]['packet']['position'].update(change)
            with self.assertRaises(ValueError):contract.decode(frame(v),OWNER)
        for change in ({'text':'A\x00B'},{'scalars':True},{'end_co':999},{'co':True},{'upload_verified':True},{'raw':'private'}):
            v=envelope();v['candidate_private'][0]['records'][0]['packet']['excerpt'].update(change)
            with self.assertRaises(Exception):contract.decode(frame(v),OWNER)

    def test_offline_private_change_and_wrong_order_rejected(self):
        v=envelope();v['candidate_private'][1]['records'][0]['packet']['excerpt']['text']='changed'
        with self.assertRaises(Exception):contract.decode(frame(v),OWNER)
        v=envelope();v['candidate_private'][0]['records'].reverse()
        with self.assertRaises(ValueError):contract.decode(frame(v),OWNER)

    def test_model_does_not_accept_a_valid_slice_from_another_position(self):
        v=envelope();v['candidate_private'][0]['records'][0]['packet']['excerpt']['text']='x'*30
        with self.assertRaises(ValueError):contract.compare(v['candidate_private'],RAW,payload())
        for key,bad in (('book_id','900002'),('chapter_uid','22'),('source_raw_sha256','b'*64)):
            p=payload();p[key]=bad
            with self.assertRaises(ValueError):contract.compare(envelope()['candidate_private'],RAW,p)

    def test_default_never_loads_credentials_or_launches_process(self):
        with patch.object(task,'SessionStore') as store,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();child.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_display_only_cb_reads_require_actual_shelf_membership(self):
        web=task.Preflight()
        try:
            with patch.object(task.TxtReadingPreflight,'request',return_value=dict(books=[dict(bookId='900001'),
                    dict(bookId='CB_Synthetic1'),dict(bookId='CB_Synthetic1'),dict(bookId='CB_bad/route'),dict(bookId=True)])):
                web.request('shelf',task.BASE+'/web/shelf/sync')
            self.assertEqual(web.display_ids,['CB_Synthetic1'])
            with patch.object(task.TxtReadingPreflight,'prepare',return_value=dict(shelf_ids=['900001'])):
                self.assertEqual(web.prepare()['shelf_ids'],['900001','CB_Synthetic1'])
        finally:web.close()

    def test_no_apply_or_automatic_renewal_mode_and_no_private_diagnostic(self):
        for args in (['--apply'],['--saved-session'],['--permit-renewal']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)
        with patch.object(task,'SessionStore',side_effect=ValueError('PRIVATE_COOKIE')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main(['--saved-session','--lua-command','synthetic']),1)
        self.assertNotIn('PRIVATE_COOKIE',out.getvalue())


if __name__=='__main__':unittest.main()
