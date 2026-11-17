"""Real-clock/native-ledger provenance boundaries; no account or Keychain."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import base64,hashlib,io,json,stat,unittest,zipfile
from unittest.mock import patch
from urllib.parse import quote
from annotation_experiment_model import canonical
from native_time_capture import NativeCaptureStore,SERVICE,PROTOCOL,validate,next_cst_day
from readtime_history_capture import SERVICE as OLD_SERVICE
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_owner_reading import stage as reading_stage
import run_native_time_capture as runner
import verify_native_time_capture as task


def sha(v):return hashlib.sha256(v).hexdigest()
def capture():
    raw=b'An original synthetic chapter for real statistics capture. '*30
    rendered=b'<html><body><p>Synthetic body</p></body></html>'
    identity='schema=1\nbook_id=900001\nbook_version=7\nchapter_count=1\ntext_digest='+sha(rendered)+'\n'
    file_id=sha(identity.encode());identity+='source_id='+file_id+'\n'
    receipt='schema=1\nbook_id=900001\nchapter_uid=2\nformat=web_txt\nraw_bytes='+str(len(raw))+'\nraw_sha256='+sha(raw)+'\n'
    meta=receipt+'capture_id='+sha(receipt.encode())+'\nbook_version=7\nfile_id='+file_id+'\nrender_path='+quote('OEBPS/text/chapter.xhtml',safe='')+'\nrender_sha256='+sha(rendered)+'\n'
    meta+='metadata_sha256='+sha(meta.encode())+'\n'
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr('OEBPS/weread-source.txt',identity)
        z.writestr('OEBPS/weread-position/uid-'+sha(b'2')+'.meta',meta)
        z.writestr('OEBPS/weread-position/raw-'+sha(raw)+'.txt',raw)
        z.writestr('OEBPS/text/chapter.xhtml',rendered)
    archive=out.getvalue();start=1794878000
    row=dict(id=1,book_id='900001',start_time=start,duration=6,time_zone='+08:00',book_version=7,file_id=file_id,version_source='epub_snapshot')
    return dict(protocol=PROTOCOL,owner='900000',baseline_sha256='c'*64,device_sha256='a'*64,book_id='900001',chapter_uid='2',chapter_idx=2,book_version=7,
        file_id=file_id,raw_sha256=sha(raw),rows=[row],start_time=start,ended_at=start+6,monotonic_elapsed_ms=6050,seconds=6,
        not_before=next_cst_day(start)+1,archive_base64=base64.b64encode(archive).decode(),archive_sha256=sha(archive))


def payload():
    p=capture()
    return dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'),book_id='900001',chapter_uid='2',source_format='web_txt',
        source_raw_sha256=p['raw_sha256'],native_time_capture=dict(device_sha256='a'*64,baseline_sha256='c'*64,book_version=7))


class CaptureTests(unittest.TestCase):
    def test_default_has_no_credential_or_network_access(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'NativeCaptureStore') as store,patch.object(task,'execute') as execute,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();store.assert_not_called();execute.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
    def test_incomplete_cli_rejected_before_work(self):
        for args in (['--saved-session'],['--capture'],['--mock'],['--native-ui-command','anything']):
            with self.subTest(args=args),redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)
    def test_distinct_immutable_store_and_no_dispatch_methods(self):
        self.assertNotEqual(SERVICE,OLD_SERVICE);p=capture();validate(p)
        store=NativeCaptureStore(Backend());receipt=store.capture(p)
        self.assertEqual(store.read()[0]['plan'],p)
        with self.assertRaises(StoreError):store.capture(p)
        self.assertEqual(store.read()[1],receipt)
        for name in ('claim','advance','finish','send'):self.assertFalse(hasattr(store,name))
    def test_corruption_and_failed_readback_rejected(self):
        for changed in ({'phase':'acknowledged'},{'schema':True},{'scope':'foreign'}):
            store=NativeCaptureStore(Backend());store.capture(capture());v=store.read()[0];v.update(changed);store.backend.data=canonical(v)
            with self.subTest(changed=changed),self.assertRaises(StoreError):store.read()
        backend=Backend();backend.save=lambda _data:None
        with self.assertRaises(StoreError):NativeCaptureStore(backend).capture(capture())
    def test_clock_day_zone_row_identity_and_duration_edits_rejected(self):
        patches=[('protocol','old'),('seconds',True),('seconds',5),('start_time',1794791600),('not_before',1),('monotonic_elapsed_ms',2000),
                 ('monotonic_elapsed_ms',12000),('file_id','b'*64),('owner','0'),('chapter_idx',True),('extra',1)]
        for key,value in patches:
            p=capture();p[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):validate(p)
        for key,value in [('duration',5),('duration',True),('time_zone','+00:00'),('file_id','b'*64),('book_version',8),('start_time',1794878001),('version_source','library')]:
            p=capture();p['rows'][0][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate(p)
    def test_contiguous_real_multiple_rows_allowed_overlap_gap_duplicates_rejected(self):
        p=capture();row=deepcopy(p['rows'][0]);row.update(id=2,start_time=row['start_time']+3,duration=3);p['rows'][0]['duration']=3;p['rows'].append(row)
        validate(p)
        for key,value in [('id',1),('start_time',row['start_time']-1),('start_time',row['start_time']+1)]:
            q=deepcopy(p);q['rows'][1][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate(q)
    def test_archive_hash_raw_metadata_identity_symlink_and_traversal_rejected(self):
        for mode in ('bytes','raw','metadata','identity','symlink','traversal','oversize'):
            p=capture();raw=base64.b64decode(p['archive_base64']);out=io.BytesIO()
            if mode=='bytes':raw=raw[:-5]
            else:
                with zipfile.ZipFile(io.BytesIO(raw)) as original,zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED) as target:
                    for item in original.infolist():
                        value=original.read(item)
                        if mode=='raw' and '/raw-' in item.filename:value+=b'changed'
                        if mode=='metadata' and item.filename.endswith('.meta'):value=value.replace(b'web_txt',b'web_xhtml')
                        if mode=='identity' and item.filename.endswith('weread-source.txt'):value=value.replace(b'book_version=7',b'book_version=8')
                        if mode=='symlink':item.external_attr=(stat.S_IFLNK|0o777)<<16
                        target.writestr(item,value)
                    if mode=='traversal':target.writestr('../outside',b'no')
                    if mode=='oversize':target.writestr('huge',b'0'*(2*1024*1024+1))
                raw=out.getvalue()
            p['archive_base64']=base64.b64encode(raw).decode();p['archive_sha256']=sha(raw)
            with self.subTest(mode=mode),self.assertRaises(ValueError):validate(p)
    def test_payload_rejects_grants_other_operations_and_mock_mismatch(self):
        runner.payload_valid(payload())
        for key,value in [('native_grant',{}),('full_manifest',[]),('selection_preview',{}),('source_format','web_xhtml')]:
            p=payload();p[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):runner.payload_valid(p)
        with self.assertRaises(ValueError):runner.payload_valid(payload(),12345)
    def test_private_frame_is_bound_to_input_and_actual_native_stage(self):
        p=payload();stage=reading_stage();stage['native_time_capture']=dict(phase='complete',real_statistics=True,actual_clock=True,
            exact_source=True,ledger_reopened=True,same_day_deferred=True,seconds=6,rows=1,archive_bytes=len(base64.b64decode(capture()['archive_base64'])),failed_line=0)
        envelope=dict(report=stage,cookies=p['cookies'],candidate_private=capture())
        encode=lambda:b'\nWEREAD_OWNER_READING_RESULT='+json.dumps(envelope).encode()
        runner.decode(encode(),p)
        for change in ('owner','raw','device','seconds','clock','reader'):
            v=deepcopy(envelope)
            if change=='reader':v['report']['native_reader']=False
            elif change=='seconds':v['report']['native_time_capture']['seconds']=7
            elif change=='clock':v['report']['native_time_capture']['actual_clock']=False
            else:v['candidate_private'][{'owner':'owner','raw':'raw_sha256','device':'device_sha256'}[change]]='12345678' if change=='owner' else 'f'*64
            with self.subTest(change=change),self.assertRaises(ValueError):runner.decode(b'\nWEREAD_OWNER_READING_RESULT='+json.dumps(v).encode(),p)

if __name__=='__main__':unittest.main()
