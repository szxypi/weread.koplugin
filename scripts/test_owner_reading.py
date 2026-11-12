"""Offline boundaries for private real-book acceptance. No owner credentials."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import hashlib
import base64
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError

import verify_owner_reading as probe
from check_owner_full_book import FullBookIncomplete, Images, inspect_full_book, member_path
from mock_weread import shards
from test_web_source_progress import Opener

OWNER = '900000'
COOKIES = dict(wr_vid=OWNER, wr_skey='synthetic-only-key')


def stage(mode='live', full=False):
    value=dict(result='PASS', phase='complete', mode=mode, requests=[1, 4, 3, 2, 4, 6, 0] if mode=='live' else [0]*7,
                shelf_books=139, pages=12, profile_files_audited=40, failed_line=0,
                screenshots=0, last_http_status=200 if mode=='live' else 0, denied_kind=0,denied_route=0,denied_flags=0,
                **dict.fromkeys(probe.FLAGS, True))
    if full:
        if mode=='live':value['requests'][4]=6
        value.update(native_images_decoded=2,download_error='none',download_error_module='none',download_error_line=0,
                     download_error_chapter=0,reader_context_failure='none',reader_identity_shape=dict(field='none',kind='none',zero=False,null=False),
                     reader_python_projection=dict(checked=False,valid=False,reason='none'),
                     reader_cookie_snapshot=dict(checked=False,same_login=False,same_header=False))
    return value


def envelope():
    return dict(report=dict(result='PASS', tmpfs_profile=True, profile_removed=True,
                            stages=[stage(), stage('reopen')], runner_error='none'), cookies=COOKIES.copy())


def frame(value):
    return probe.FRAME + json.dumps(value).encode() + b'\n'


class OwnerReadingTests(unittest.TestCase):
    def test_default_never_accesses_owner_or_starts_child(self):
        with patch.object(probe, 'SessionStore') as store, patch.object(probe, 'ReadingPreflight') as web, \
                patch.object(probe.subprocess, 'run') as child, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(probe.main([]), 0)
        store.assert_not_called(); web.assert_not_called(); child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_txt_selection_stays_offline_without_saved_session(self):
        with patch.object(probe, 'SessionStore') as store, patch.object(probe, 'TxtReadingPreflight') as web, \
                patch.object(probe.subprocess, 'run') as child, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(probe.main(['--book-format', 'txt']), 0)
        store.assert_not_called(); web.assert_not_called(); child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['book_format'], 'txt')

    def test_opt_in_requires_both_session_and_command(self):
        for args in (['--saved-session'], ['--lua-command', 'synthetic']):
            with self.subTest(args=args), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                probe.main(args)

    def test_private_fields_cannot_enter_public_reports(self):
        for key in ('title', 'book_id', 'source_text', 'cookies', 'raw'):
            value=stage(); value[key]='private'
            with self.assertRaises(ValueError): probe.validate_stage(value, 'live')
            value=envelope(); value['report'][key]='private'
            with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)

    def test_success_requires_each_proof_and_no_forbidden_request(self):
        for key in probe.FLAGS:
            value=stage(); value[key]=False
            with self.subTest(flag=key), self.assertRaises(ValueError): probe.validate_stage(value, 'live')
        for key, bad in (('shelf_books', 0), ('pages', 1), ('screenshots', 1), ('failed_line', 1),
                         ('profile_files_audited', 0), ('denied_kind', 1), ('phase', 'native'), ('pages', True)):
            value=stage(); value[key]=bad
            with self.subTest(key=key), self.assertRaises(ValueError): probe.validate_stage(value, 'live')
        for index in (0, 2, 3, 4):
            value=stage(); value['requests'][index]=0
            with self.assertRaises(ValueError): probe.validate_stage(value, 'live')
        value=stage(); value['requests'][-1]=1
        with self.assertRaises(ValueError): probe.validate_stage(value, 'live')

    def test_offline_reopen_forbids_every_network_category(self):
        for index in range(7):
            value=stage('reopen'); value['requests'][index]=1
            with self.assertRaises(ValueError): probe.validate_stage(value, 'reopen')

    def test_fresh_process_and_cleanup_are_mandatory(self):
        for key in ('tmpfs_profile', 'profile_removed'):
            value=envelope(); value['report'][key]=False
            with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)
        for key in ('shelf_books', 'pages'):
            value=envelope(); value['report']['stages'][1][key]+=1
            with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)
        value=envelope(); value['report']['stages'].pop()
        with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)

    def test_cookie_envelope_is_strict_and_owner_bound(self):
        for change in (dict(wr_vid='900001'), dict(extra='private'), dict(wr_skey='bad\nvalue'), dict(wr_skey=''),
                       dict(wr_skey='synthetic-\U0001f600-value')):
            value=envelope(); value['cookies'].update(change)
            with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)
        self.assertEqual(probe.decode_envelope(frame(envelope()), OWNER)['cookies'], COOKIES)

    def test_frame_limits_duplicates_and_private_trailers(self):
        raw=frame(envelope())
        for invalid in (raw+raw, raw+b'private', b'x'*(2*1024*1024)+raw, b'private'):
            with self.assertRaises(ValueError): probe.decode_envelope(invalid, OWNER)

    def test_source_sample_ignores_head_and_script(self):
        parser=probe.SourceText()
        parser.feed('<head><title>'+'A'*40+'</title></head><script>'+'B'*40+'</script><p>'+'正文示例'*12+'</p>')
        self.assertEqual(parser.samples, [('正文示例'*12)[:32]])

    def run_online(self, child_result=None, after=None, rotated=None, book_format='epub', full_book=False):
        web=MagicMock()
        web.report=dict(stages=[])
        web.prepare.return_value=dict(book_id='900001', chapter_uid='2', source_text='private source',
                                      shelf_ids=['900001'], shelf_books=139,
                                      source_format='web_txt' if book_format == 'txt' else 'web_xhtml')
        if full_book:
            web.prepare.return_value['full_manifest']=[dict(chapter_uid=str(uid),image_references=1) for uid in (1,2)]
        web.book_id='900001'; web.baseline=dict(chapter='2', offset=10, percent=20)
        web.request.return_value=after or dict(bookId='900001', chapterUid=2, chapterOffset=10, progress=20)
        accepted=envelope()
        if full_book:
            accepted['report']['stages'][0]['requests'][4]=6
            for item in accepted['report']['stages']:
                item.update(native_images_decoded=2,download_error='none',download_error_module='none',download_error_line=0,
                            download_error_chapter=0,reader_context_failure='none',
                            reader_identity_shape=dict(field='none',kind='none',zero=False,null=False))
                item.update(reader_python_projection=dict(checked=False,valid=False,reason='none'),
                            reader_cookie_snapshot=dict(checked=False,same_login=False,same_header=False))
            accepted['report']['full_book']=dict(chapters=2,source_image_references=2,local_image_references=3,
                                                body_image_references=2,converted_footnote_images=0,
                                                unexplained_image_references=0,source_text_runs_verified=2,
                                                unexplained_text_runs=0,packaged_images=2,
                                                **dict.fromkeys(probe.FULL_FLAGS,True))
        result=child_result or SimpleNamespace(returncode=0, stdout=frame(accepted), stderr=b'private child diagnostics')
        snapshots=iter((dict(vid=OWNER, cookies=COOKIES.copy()), dict(vid=OWNER, cookies=rotated or COOKIES.copy())))
        factory = 'FullBookPreflight' if full_book else ('TxtReadingPreflight' if book_format == 'txt' else 'ReadingPreflight')
        with patch.object(probe, 'SessionStore') as store, patch.object(probe, factory, return_value=web), \
                patch.object(probe, 'save_refreshed_web_session', return_value=False), \
                patch.object(probe.subprocess, 'run', **({'side_effect':result} if isinstance(result, Exception)
                                                      else {'return_value':result})) as child, redirect_stdout(io.StringIO()) as output:
            store.return_value.load.side_effect=lambda: next(snapshots)
            code=probe.main(['--saved-session', '--book-format', book_format]+(['--full-book'] if full_book else [])+['--lua-command', 'synthetic'])
        public=output.getvalue()
        self.assertNotIn('synthetic-only-key', public)
        self.assertNotIn('private source', public)
        self.assertNotIn('private child diagnostics', public)
        self.assertEqual(web.close.call_count, 1)
        return code, json.loads(public), child

    def test_success_verifies_owner_again_and_unchanged_cloud(self):
        code, public, child=self.run_online()
        self.assertEqual(code, 0)
        self.assertTrue(public['cloud_position_unchanged'])
        self.assertEqual(public['result'], 'OWNER_NATIVE_READING_VERIFIED')
        self.assertEqual(child.call_args.kwargs['timeout'], 320)

    def test_child_receives_verified_keychain_readback_after_rotation(self):
        rotated=dict(COOKIES, wr_skey='synthetic-rotated-value')
        code, _public, child=self.run_online(rotated=rotated)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['cookies'], rotated)

    def test_txt_native_probe_requires_txt_receipt_and_private_preflight(self):
        code, public, child = self.run_online(book_format='txt')
        self.assertEqual(code, 0)
        self.assertEqual(public['book_format'], 'txt')
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['source_format'], 'web_txt')
        self.assertTrue(public['ui']['stages'][0]['source_receipt_verified'])

    def test_full_native_probe_requires_independent_full_report_and_bounded_timeout(self):
        code,public,child=self.run_online(full_book=True)
        self.assertEqual(code,0)
        self.assertEqual((public['reading_scope'],public['chapters'],public['source_image_references']),('full',2,2))
        self.assertEqual(child.call_args.kwargs['timeout'],920)
        self.assertEqual(len(json.loads(child.call_args.kwargs['input'])['full_manifest']),2)
        code,public,_child=self.run_online(full_book=True,child_result=SimpleNamespace(returncode=0,stdout=frame(envelope()),stderr=b''))
        self.assertEqual(code,1);self.assertEqual(public['result'],'UNVERIFIED')

    def test_failed_child_or_changed_cloud_cannot_pass(self):
        code, public, _child=self.run_online(SimpleNamespace(returncode=1, stdout=frame(envelope()), stderr=b''))
        self.assertEqual(code, 1); self.assertEqual(public['result'], 'UNVERIFIED')
        code, public, _child=self.run_online(after=dict(bookId='900001', chapterUid=2, chapterOffset=11, progress=20))
        self.assertEqual(code, 1); self.assertFalse(public['cloud_position_unchanged'])

    def test_timeout_and_invalid_private_output_are_sanitized(self):
        code, public, _child=self.run_online(SimpleNamespace(returncode=1, stdout=b'private secret', stderr=b'private'))
        self.assertEqual(code, 1); self.assertEqual(public['reason'], 'owner_reading_unverified')
        code, public, _child=self.run_online(subprocess.TimeoutExpired('private command', 320, output=b'private key'))
        self.assertEqual(code, 1); self.assertEqual(public['reason'], 'owner_reading_unverified')


class FullBookReadingTests(unittest.TestCase):
    def test_private_rejection_diagnostic_only_crosses_native_failure_pipe(self):
        native=stage(full=True);native['result']='UNVERIFIED'
        encoded=base64.b64encode(b'private original reader page').decode()
        value=dict(report=native,cookies=COOKIES.copy(),rejected_html=encoded)
        actual=probe.decode_envelope(frame(value),OWNER,mode='live',full_chapters=2)
        self.assertEqual(actual['rejected_html'],encoded)
        for kwargs in ({},{'full_chapters':2},{'mode':'live'}):
            with self.assertRaises(ValueError):probe.decode_envelope(frame(value),OWNER,**kwargs)
        native['result']='PASS'
        with self.assertRaises(ValueError):probe.decode_envelope(frame(value),OWNER,mode='live',full_chapters=2)

    def test_private_rejection_diagnostic_is_bounded_and_not_raw_text(self):
        for raw in ('private body\n','<html>private</html>','x'*(6*1024*1024+1)):
            native=stage(full=True);native['result']='UNVERIFIED'
            with self.assertRaises(ValueError):
                probe.decode_envelope(frame(dict(report=native,cookies=COOKIES,rejected_html=raw)),OWNER,mode='live',full_chapters=2)

    def test_full_preflight_paces_successful_reads_without_retrying_errors(self):
        web=self.web(self.rows());web.request_interval=1
        with patch.object(probe.time,'sleep') as wait:
            web.prepare()
        self.assertEqual(wait.call_count,len(web.opener.calls))
        self.assertTrue(all(call.args==(1,) for call in wait.call_args_list))
        for interval in (-1,6,True,float('nan')):
            with self.assertRaises(ValueError):probe.FullBookPreflight(interval)

    def archive(self):
        buffer=io.BytesIO()
        with zipfile.ZipFile(buffer,'w') as archive: archive.writestr('pixel.png',b'\x89PNG\r\n\x1a\nsynthetic')
        return buffer.getvalue()

    def test_protected_archive_authentication_stays_on_exact_trusted_host(self):
        url='https://res.weread.qq.com/resource.tar'
        for target in ('http://101.32.1.1/resource.tar?signature=synthetic','https://cdn.qq.com/resource.tar',
                       'https://other.weread.qq.com/resource.tar'):
            web=self.web([]);web.book_id='900001';web.set_cookie('wr_vid',OWNER);web.set_cookie('wr_skey',COOKIES['wr_skey'])
            web.archive_opener=Opener([HTTPError(url,302,'redirect',{'Location':target},None),self.archive()])
            with patch.object(web.cookies,'extract_cookies'):
                self.assertEqual(web.check_protected_archive(url,'1'),1)
            first,second=[row[0] for row in web.archive_opener.calls]
            self.assertIn('wr_skey=',first.get_header('Cookie'))
            self.assertIsNone(second.get_header('Cookie'))
            self.assertEqual((first.get_method(),second.get_method()),('GET','GET'))
            self.assertIsNone(first.get_header('Authorization'))

    def test_archive_redirect_limits_and_private_targets_are_rejected(self):
        url='https://res.weread.qq.com/resource.tar'
        for target in ('http://127.0.0.1/private','https://10.0.0.1/private','https://user:secret@cdn.qq.com/image',
                       'https://cdn.local/resource','https://cdn.qq.com/resource#fragment'):
            web=self.web([]);web.book_id='900001'
            web.archive_opener=Opener([HTTPError(url,302,'redirect',{'Location':target},None)])
            with self.subTest(target=target),self.assertRaises(probe.PreflightError): web.check_protected_archive(url,'1')
            self.assertEqual(len(web.archive_opener.calls),1)
        web=self.web([]);web.book_id='900001'
        web.archive_opener=Opener([HTTPError(url,302,'redirect',{'Location':url},None) for _i in range(6)])
        with self.assertRaises(probe.PreflightError): web.check_protected_archive(url,'1')
        self.assertEqual(len(web.archive_opener.calls),6)

    def test_resource_scope_rejects_other_hosts_downgrade_and_nonarchives(self):
        for value in ('https://cdn.qq.com/image','http://res.weread.qq.com/image','https://res.weread.qq.com/image#fragment',
                      'https://user:secret@res.weread.qq.com/image','https://res.weread.qq.com:443/image','bad\nurl'):
            self.assertIsNone(probe.FullBookPreflight.protected_resource_url(value))
        web=self.web([]);web.book_id='900001';web.archive_opener=Opener([b'<html>no archive</html>'])
        with patch.object(web.cookies,'extract_cookies'),self.assertRaises(probe.PreflightError):
            web.check_protected_archive('https://res.weread.qq.com/resource.tar','1')

    def catalog(self, book='900001'):
        return dict(data=[dict(bookId=book, book=dict(bookId=book, format='epub'), bookVersion=7,
                               updated=[dict(chapterUid=9, title='封面', wordCount=100),
                                        dict(chapterUid=1, title='Chapter one', wordCount=500),
                                        dict(chapterUid=2, title='Chapter two', wordCount=500)])])

    def rows(self, *, unstarted=False):
        point = dict(bookId='900001', chapterUid=0 if unstarted else 1, chapterIdx=0 if unstarted else 1,
                     chapterOffset=0, progress=0)
        values = [dict(books=[dict(bookId='900001', format='epub')]), self.catalog(), dict(book=point.copy())]
        for uid in (1, 2):
            reader = dict(reader=dict(bookInfo=dict(bookId='900001'), currentChapter=dict(chapterUid=uid),
                                      psvts='synthetic-full-session'))
            values += [('window.__INITIAL_STATE__=' + json.dumps(reader) + ';(function(){})();').encode()]
            values += [part.encode() for part in shards(f'<html><body><p>Full chapter {uid} original body text with enough distinct characters.</p><img src="pic.jpg"/></body></html>')]
        return values + [self.catalog(), dict(book=point.copy())]

    def web(self, values):
        web = probe.FullBookPreflight(request_interval=0); web.authenticated=True; web.vid=OWNER
        web.opener=Opener(values)
        return web

    def test_full_default_is_offline_and_requires_epub(self):
        with patch.object(probe, 'SessionStore') as store, patch.object(probe, 'FullBookPreflight') as web, \
                redirect_stdout(io.StringIO()) as output:
            self.assertEqual(probe.main(['--full-book']), 0)
        store.assert_not_called(); web.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            probe.main(['--full-book', '--book-format', 'txt'])

    def test_full_preflight_reads_every_readable_chapter_and_stable_catalog(self):
        for unstarted in (False, True):
            web=self.web(self.rows(unstarted=unstarted)); payload=web.prepare()
            self.assertEqual([row['chapter_uid'] for row in payload['full_manifest']], ['1','2'])
            self.assertEqual(sum(row['image_references'] for row in payload['full_manifest']), 2)
            self.assertEqual(len(web.opener.calls), 13)
            self.assertEqual(payload['chapter_uid'], '1')
            self.assertNotIn('raw', payload['full_manifest'][0])

    def test_full_preflight_refuses_failure_in_second_chapter_without_skipping(self):
        values=self.rows(); values[8]=b'{}'; web=self.web(values)
        with self.assertRaises(probe.PreflightError): web.prepare()
        self.assertEqual(len(web.opener.calls), 11)

    def test_full_preflight_rejects_catalog_or_cloud_changes(self):
        for kind in ('version','chapter','progress'):
            values=self.rows()
            if kind=='version': values[-2]['data'][0]['bookVersion']=8
            elif kind=='chapter': values[-2]['data'][0]['updated'][1]['wordCount']=501
            else: values[-1]['book']['chapterOffset']=1
            web=self.web(values)
            with self.subTest(kind=kind), self.assertRaises(probe.PreflightError): web.prepare()

    def test_full_preflight_rejects_duplicate_chapters_and_source_limit(self):
        values=self.rows(); values[1]['data'][0]['updated'][2]['chapterUid']=1
        web=self.web(values)
        with self.assertRaises(probe.PreflightError): web.prepare()
        self.assertEqual(len(web.opener.calls), 2)
        web=self.web(self.rows()); web.MAX_TOTAL_BYTES=10
        with self.assertRaises(probe.PreflightError): web.prepare()
        self.assertEqual(len(web.opener.calls), 7)

    def test_full_selection_stops_after_twelve_catalogs(self):
        ids=[str(900001+i) for i in range(13)]
        values=[dict(books=[dict(bookId=key, format='epub') for key in ids])]
        for key in ids[:12]:
            catalog=self.catalog(key); catalog['data'][0]['book']['format']='pdf'; values.append(catalog)
        web=self.web(values)
        with self.assertRaises(probe.PreflightError): web.prepare()
        self.assertEqual(len(web.opener.calls), 13)

    def fixture(self, *, source='../images/pixel.png', reverse=False, raw_body=None, render_body=None, source_images=1):
        temporary=tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        profile=Path(temporary.name); path=profile/'book.epub'
        files={'OEBPS/images/pixel.png':b'\x89PNG\r\n\x1a\nsynthetic-image-reference-only'}
        identity=('schema=1\nbook_id=900001\nbook_version=7\nchapter_count=2\ntext_digest='+hashlib.sha256(b'synthetic-rendered').hexdigest()+'\n').encode()
        source_id=hashlib.sha256(identity).hexdigest()
        files['OEBPS/weread-source.txt']=identity+b'source_id='+source_id.encode()+b'\n'
        expected=[]; members=[]
        for uid in ('1','2'):
            text=f'Private original chapter {uid} contains enough visible text to verify retention.'
            raw=(raw_body.replace('{uid}',uid) if raw_body is not None else f'<p>{text}</p><img src="pic.png"/>').encode()
            digest=hashlib.sha256(raw).hexdigest(); member=f'OEBPS/text/chapter-{uid}.xhtml'
            rendered_body=(render_body.replace('{uid}',uid).replace('{image_source}',source) if render_body is not None
                           else f'<p>{text}</p><img src="{source}"/>')
            rendered=f'<html><body>{rendered_body}</body></html>'.encode()
            files[member]=rendered
            fields=dict(book_id='900001', chapter_uid=uid, format='web_xhtml', raw_bytes=str(len(raw)),
                        raw_sha256=digest, render_path=member, render_sha256=hashlib.sha256(rendered).hexdigest(),
                        file_id=source_id, book_version='7')
            body=''.join(f'{key}={value}\n' for key,value in fields.items()).encode()
            metadata=body+b'metadata_sha256='+hashlib.sha256(body).hexdigest().encode()+b'\n'
            files['OEBPS/weread-position/uid-'+hashlib.sha256(uid.encode()).hexdigest()+'.meta']=metadata
            files['OEBPS/weread-position/path-'+hashlib.sha256(member.encode()).hexdigest()+'.meta']=metadata
            files['OEBPS/weread-position/raw-'+digest+'.txt']=raw
            expected.append(dict(chapter_uid=uid, raw_sha256=digest, raw_bytes=len(raw), image_references=source_images)); members.append(member)
        order=('2','1') if reverse else ('1','2')
        files['OEBPS/content.opf']=('''<package xmlns="http://www.idpf.org/2007/opf"><manifest>'''
            + ''.join(f'<item id="c{uid}" href="text/chapter-{uid}.xhtml" media-type="application/xhtml+xml"/>' for uid in ('1','2'))
            + '<item id="img" href="images/pixel.png" media-type="image/png"/></manifest><spine>'
            + ''.join(f'<itemref idref="c{uid}"/>' for uid in order)+'</spine></package>').encode()
        (profile/'checkpoint.json').write_text(json.dumps(dict(file=str(path))))
        payload=dict(book_id='900001', full_manifest=expected)
        return profile,path,files,payload

    def inspect(self, profile, path, files, payload):
        with zipfile.ZipFile(path,'w') as archive:
            for name,raw in files.items(): archive.writestr(name,raw)
        return inspect_full_book(profile,payload)

    def test_independent_package_checks_sources_spine_and_all_image_references(self):
        report,digest=self.inspect(*self.fixture())
        self.assertEqual((report['chapters'],report['source_image_references'],report['local_image_references'],report['packaged_images']),(2,2,2,1))
        self.assertFalse(report['fresh_offline_package_identical'])
        self.assertEqual(report['source_text_runs_verified'],2)
        self.assertTrue(report['text_runs_verified'])
        self.assertEqual(len(digest),64)

    def test_image_inventory_uses_visible_dom_and_includes_svg_images(self):
        parser=Images()
        parser.feed('''<html><head><img src="head.png"/></head><body>
            <!-- <img src="comment.png"/> --><script>"<img src='script.png'>"</script>
            <style>img { content: '<img src="style.png">' }</style>
            <template><img src="template.png"/></template><img src="body.png"/>
            <svg><image xlink:href="vector.png"/></svg></body></html>''')
        self.assertEqual(parser.sources,['body.png','vector.png'])
        fragment=Images();fragment.feed('<p>Fragment</p><img src="fragment.png"/>')
        self.assertEqual(fragment.sources,['fragment.png'])

    def note_fixture(self, *, note='A native note preserves its original meaning.', mutation=None):
        raw='<p>Ordinary body text remains visible throughout this conversion.</p>'
        raw+='<img src="pic.png"/><img class="qqreader-footnote" src="marker.png" alt="'+note+'"/>'
        rendered='<p>Ordinary body text remains visible throughout this conversion.</p><img src="{image_source}"/>'
        rendered+='<a epub:type="noteref" id="wrfnref-{uid}-1" href="#wrfn-{uid}-1">[1]</a>'
        rendered+='<aside epub:type="footnote" id="wrfn-{uid}-1"><p>'+note+'</p><a href="#wrfnref-{uid}-1">↩</a></aside>'
        if mutation:rendered=mutation(rendered)
        return self.fixture(raw_body=raw,render_body=rendered,source_images=2)

    def test_native_footnote_accounts_for_marker_image_only_after_validation(self):
        report,_digest=self.inspect(*self.note_fixture())
        self.assertEqual((report['source_image_references'],report['body_image_references'],report['converted_footnote_images']),(4,2,2))
        self.assertEqual(report['unexplained_image_references'],0)
        self.assertTrue(report['image_references_verified'])
        # Attribute entities must remain literal note text after a single decode.
        report,_digest=self.inspect(*self.note_fixture(note='A note with &lt;literal-tag&gt; and &amp; preserved text.'))
        self.assertEqual(report['converted_footnote_images'],2)

    def test_removed_marker_needs_note_text_unique_target_and_backlink(self):
        mutations=(lambda value:value.replace('A native note preserves its original meaning.','Wrong note content.'),
                   lambda value:value.replace('href="#wrfnref-{uid}-1"','href="#missing"'),
                   lambda value:value.replace('epub:type="footnote"','epub:type="other"'),
                   lambda value:value+'<span id="wrfn-{uid}-1"></span>')
        for mutation in mutations:
            with self.subTest(mutation=mutation),self.assertRaises(FullBookIncomplete) as caught:
                self.inspect(*self.note_fixture(mutation=mutation))
            report=caught.exception.summary
            self.assertEqual(report['converted_footnote_images'],0)
            self.assertEqual(report['unexplained_image_references'],2)
            self.assertFalse(report['image_references_verified'])

    def test_explicit_note_link_can_replace_its_image_with_numbered_text(self):
        raw='<p>Ordinary body text remains visible throughout this conversion.</p>'
        raw+='<a id="old-ref" epub:type="noteref" href="#old-note"><img src="marker.png"/></a>'
        raw+='<p id="old-note">A substantial original note is preserved in the native footnote.</p>'
        rendered='<p>Ordinary body text remains visible throughout this conversion.</p>'
        rendered+='<span id="old-ref"><a epub:type="noteref" id="wrfnref-{uid}-1" href="#wrfn-{uid}-1">[1]</a></span>'
        rendered+='<aside epub:type="footnote" id="wrfn-{uid}-1"><span id="old-note"></span>'
        rendered+='<p>A substantial original note is preserved in the native footnote.</p><a href="#wrfnref-{uid}-1">↩</a></aside>'
        report,_digest=self.inspect(*self.fixture(raw_body=raw,render_body=rendered))
        self.assertEqual((report['converted_footnote_images'],report['local_image_references']),(2,0))
        self.assertEqual(report['source_text_runs_verified'],4)
        for changed in (rendered.replace('id="old-ref"','id="wrong-ref"'),rendered.replace('href="#wrfnref-{uid}-1"','href="#missing"'),
                        rendered.replace('A substantial original note is preserved in the native footnote.','Wrong note.')):
            with self.assertRaises(FullBookIncomplete):self.inspect(*self.fixture(raw_body=raw,render_body=changed))

    def test_hidden_text_cannot_replace_visible_body_or_footnote_text(self):
        hidden='<script>Private original chapter {uid} contains enough visible text to verify retention.</script>'
        with self.assertRaises(FullBookIncomplete):
            self.inspect(*self.fixture(render_body=hidden+'<p>Unrelated.</p><img src="{image_source}"/>'))
        for hidden in ('script','style','template'):
            mutation=lambda value: value.replace('<p>A native note preserves its original meaning.</p>',
                                                '<'+hidden+'>A native note preserves its original meaning.</'+hidden+'>')
            with self.subTest(hidden=hidden),self.assertRaises(FullBookIncomplete):self.inspect(*self.note_fixture(mutation=mutation))

    def test_ordinary_image_cannot_be_excused_by_unrelated_native_note(self):
        rendered='<p>Private original chapter {uid} contains enough visible text to verify retention.</p>'
        rendered+='<a epub:type="noteref" id="wrfnref-{uid}-1" href="#wrfn-{uid}-1">[1]</a>'
        rendered+='<aside epub:type="footnote" id="wrfn-{uid}-1">Unrelated note<a href="#wrfnref-{uid}-1">↩</a></aside>'
        with self.assertRaises(FullBookIncomplete) as caught:self.inspect(*self.fixture(render_body=rendered))
        self.assertEqual(str(caught.exception),'full_missing_image_references')
        self.assertEqual(caught.exception.summary['unexplained_image_references'],2)

    def test_package_rejects_missing_substantial_original_text(self):
        with self.assertRaises(FullBookIncomplete) as caught:
            self.inspect(*self.fixture(render_body='<p>Unrelated text.</p><img src="{image_source}"/>'))
        self.assertEqual(str(caught.exception),'full_source_text_missing')
        self.assertEqual(caught.exception.summary['unexplained_text_runs'],2)
        self.assertTrue(caught.exception.summary['image_references_verified'])
        self.assertFalse(caught.exception.summary['text_runs_verified'])
        self.assertEqual(probe.validate_full_book(caught.exception.summary,2,complete=False),caught.exception.summary)
        with self.assertRaises(ValueError):probe.validate_full_book(caught.exception.summary,2)

    def test_independent_inventory_rejects_wrong_preflight_count(self):
        with self.assertRaisesRegex(ValueError,'full_source_image_count'):
            self.inspect(*self.fixture(source_images=2))

    def test_package_rejects_remote_missing_and_unrecognized_images(self):
        for source in ('https://res.qpic.cn/pic.png','//res.qpic.cn/pic.png','../images/missing.png'):
            with self.subTest(source=source), self.assertRaises(ValueError): self.inspect(*self.fixture(source=source))
        for raw in (None,b'<html>not an image</html>'):
            values=self.fixture(); files=values[2]
            if raw is None: files.pop('OEBPS/images/pixel.png')
            else: files['OEBPS/images/pixel.png']=raw
            with self.assertRaises(ValueError): self.inspect(*values)

    def test_package_rejects_changed_original_render_metadata_and_spine(self):
        for suffix in ('.txt','.xhtml','.meta'):
            values=self.fixture(); files=values[2]
            key=next(name for name in files if name.endswith(suffix)); files[key]+=b'changed'
            with self.subTest(suffix=suffix), self.assertRaises(ValueError): self.inspect(*values)
        with self.assertRaises(ValueError): self.inspect(*self.fixture(reverse=True))

    def test_resource_paths_reject_escape_and_external_references(self):
        for value in ('../../../secret','/absolute','file:///secret','../images/x?token=private','\\secret',''):
            with self.subTest(value=value), self.assertRaises(ValueError): member_path('OEBPS/text/chapter.xhtml',value)
        self.assertEqual(member_path('OEBPS/text/chapter.xhtml','../images/a%20b.png#point'),'OEBPS/images/a b.png')

    def test_full_report_requires_all_proofs_and_exact_scope(self):
        report,_hash=self.inspect(*self.fixture()); report['fresh_offline_package_identical']=True
        self.assertEqual(probe.validate_full_book(report,2),report)
        for key in probe.FULL_FLAGS:
            value=dict(report); value[key]=False
            with self.subTest(key=key), self.assertRaises(ValueError): probe.validate_full_book(value,2)
        for change in (dict(chapters=1),dict(local_image_references=1),dict(packaged_images=0),dict(title='private')):
            with self.assertRaises(ValueError): probe.validate_full_book(dict(report,**change),2)

    def test_full_transport_counts_do_not_relax_single_chapter_limits(self):
        value=stage();value['requests'][2]=40;value['requests'][4]=120;value['requests'][5]=200
        with self.assertRaises(ValueError): probe.validate_stage(value,'live')
        value.update(native_images_decoded=2,download_error='none',download_error_module='none',download_error_line=0,
                     download_error_chapter=0,reader_context_failure='none',
                     reader_identity_shape=dict(field='none',kind='none',zero=False,null=False))
        value.update(reader_python_projection=dict(checked=False,valid=False,reason='none'),
                     reader_cookie_snapshot=dict(checked=False,same_login=False,same_header=False))
        self.assertEqual(probe.validate_stage(value,'live',full_chapters=30),value)
        value['requests'][4]=181
        with self.assertRaises(ValueError): probe.validate_stage(value,'live',full_chapters=30)


if __name__ == '__main__':
    unittest.main()
