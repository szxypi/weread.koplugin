"""Offline integrity and isolation boundaries for remote CI build inputs."""
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import subprocess
import textwrap
import unittest
from unittest.mock import MagicMock,Mock,patch
import bootstrap_ci_tools as task


def archive(entries):
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as tar:
        for name,kind,content in entries:
            member=tarfile.TarInfo(name);member.mode=0o755 if kind=='dir' else 0o644
            if kind=='dir':member.type=tarfile.DIRTYPE;tar.addfile(member)
            elif kind=='link':member.type=tarfile.SYMTYPE;member.linkname=content;tar.addfile(member)
            else:
                raw=content.encode();member.size=len(raw);tar.addfile(member,io.BytesIO(raw))
    return stream.getvalue()


class IntegrityTests(unittest.TestCase):
    def test_locked_tools_have_exact_commits_versions_and_both_architectures(self):
        value=task.load_lock();self.assertEqual(set(value['sources']),{'luajit','luacheck','luafilesystem','argparse'})
        self.assertEqual(set(value['ripgrep']),{'aarch64','x86_64'})
    def test_tampered_or_unpinned_manifest_is_rejected(self):
        for kind in ('hash','commit','schema','tool'):
            value=task.load_lock()
            if kind=='hash':value['sources']['luajit']['sha256']='bad'
            elif kind=='commit':value['sources']['luajit']['commit']='a'*40
            elif kind=='schema':value['schema']=True
            else:value['sources'].pop('luacheck')
            with tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp)/'lock.json';path.write_text(json.dumps(value))
                with self.subTest(kind=kind),self.assertRaises(ValueError):task.load_lock(path)
    def test_cache_is_offline_and_still_checks_bytes_before_use(self):
        raw=b'public synthetic archive';row=dict(url='https://github.com/example/test',sha256=hashlib.sha256(raw).hexdigest())
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);path=root/('fixture-'+row['sha256']+'.tar.gz');path.write_bytes(raw)
            network=Mock();self.assertEqual(task.archive_bytes('fixture',row,root,network),raw);network.open.assert_not_called()
            path.write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError,'hash mismatch'):task.archive_bytes('fixture',row,root,network)
            path.unlink()
            with self.assertRaisesRegex(ValueError,'Missing offline'):task.archive_bytes('fixture',row,root,network)
            network.open.assert_not_called()
    def test_cache_symlink_and_bad_artifact_name_are_refused(self):
        row=dict(sha256='a'*64,url='https://github.com/example/test')
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/('fixture-'+row['sha256']+'.tar.gz')).symlink_to('/etc/passwd')
            with self.assertRaises(ValueError):task.archive_bytes('fixture',row,root)
            with self.assertRaises(ValueError):task.archive_bytes('../fixture',row,root)
    def test_download_limit_and_wrong_hash_never_reach_build(self):
        opener=MagicMock();row=dict(url='https://github.com/example/test',sha256=hashlib.sha256(b'expected').hexdigest())
        opener.open.return_value.__enter__.return_value=io.BytesIO(b'changed')
        with self.assertRaises(ValueError):task.archive_bytes('fixture',row,opener=opener)
        with patch.object(task,'MAX_ARCHIVE',3):
            opener.open.return_value.__enter__.return_value=io.BytesIO(b'expected')
            with self.assertRaises(ValueError):task.archive_bytes('fixture',row,opener=opener)
    def test_redirect_cannot_downgrade_tls_or_leave_upstream(self):
        for url in ('http://github.com/a','https://github.com.invalid/a','https://user:secret@github.com/a','https://github.com:444/a'):
            with self.subTest(url=url),self.assertRaises(ValueError):task.safe_url(url)
        self.assertEqual(task.safe_url('https://release-assets.githubusercontent.com/a'),'https://release-assets.githubusercontent.com/a')


class ExtractionTests(unittest.TestCase):
    def test_valid_single_root_is_extracted_without_changing_parent_files(self):
        raw=archive([('tool','dir',''),('tool/file.lua','file','return true')])
        with tempfile.TemporaryDirectory() as tmp:
            parent=Path(tmp);sentinel=parent/'original';sentinel.write_text('keep')
            root=task.unpack(raw,parent/'source');self.assertEqual((root/'file.lua').read_text(),'return true');self.assertEqual(sentinel.read_text(),'keep')
    def test_traversal_absolute_links_duplicate_and_multiple_roots_fail_before_writes(self):
        cases=[['tool/../../escape','file','bad'],['/escape','file','bad'],['tool/link','link','../../escape']]
        entries=[[(name,kind,content)] for name,kind,content in cases]
        entries.extend([[('tool/file','file','a'),('tool/file','file','b')],[('one/file','file','a'),('two/file','file','b')]])
        for value in entries:
            with self.subTest(value=value),tempfile.TemporaryDirectory() as tmp:
                target=Path(tmp)/'source'
                with self.assertRaises(ValueError):task.unpack(archive(value),target)
                self.assertFalse(target.exists())
    def test_expanded_content_limit_is_checked_before_writing(self):
        raw=archive([('tool/file','file','too large')])
        with tempfile.TemporaryDirectory() as tmp,patch.object(task,'MAX_CONTENT',2):
            target=Path(tmp)/'source'
            with self.assertRaises(ValueError):task.unpack(raw,target)
            self.assertFalse(target.exists())
    def test_existing_prefix_and_repo_location_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent=Path(tmp);sentinel=parent/'keep';sentinel.write_text('original')
            with self.assertRaises(ValueError):task.fresh_prefix(parent)
            with self.assertRaises(ValueError):task.fresh_prefix(task.REPO/'new-toolchain')
            with self.assertRaises(ValueError):task.fresh_prefix(parent/'with space')
            self.assertEqual(sentinel.read_text(),'original');self.assertEqual(task.fresh_prefix(parent/'new'),(parent/'new').resolve())
    def test_unsupported_architecture_fails_before_downloading_or_creating_prefix(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(task.platform,'system',return_value='Linux'),\
             patch.object(task.platform,'machine',return_value='unknown'),patch.object(task,'archive_bytes') as download:
            target=Path(tmp)/'tools'
            with self.assertRaises(ValueError):task.install(target)
            self.assertFalse(target.exists());download.assert_not_called()


class SearchFailureTests(unittest.TestCase):
    def broken_search(self,script):
        with tempfile.TemporaryDirectory() as tmp:
            rg=Path(tmp)/'rg';rg.write_text('#!/bin/sh\nexit 2\n');rg.chmod(0o755)
            return subprocess.run(['bash'],input=script,text=True,cwd=task.REPO,capture_output=True,
                env=dict(os.environ,PATH=tmp+os.pathsep+os.environ['PATH']),timeout=30)
    def test_namespace_check_rejects_search_errors_as_well_as_matches(self):
        child=self.broken_search('bash scripts/check_lua_namespace.sh')
        self.assertNotEqual(child.returncode,0,'namespace search errors were reported as a pass')
    def test_sensitive_check_rejects_search_errors_as_well_as_matches(self):
        workflow=(task.REPO/'.github/workflows/ci.yml').read_text()
        section=workflow.split('      - name: Sensitive information scan\n',1)[1].split('        run: |\n',1)[1]
        child=self.broken_search(textwrap.dedent(section))
        self.assertNotEqual(child.returncode,0,'sensitive search errors were reported as a pass')


if __name__=='__main__':unittest.main()
