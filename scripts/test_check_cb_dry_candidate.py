"""A dry-run candidate must contain exactly the current release files."""
import tempfile,unittest,zipfile
from pathlib import Path

from check_cb_dry_candidate import check


class DryCandidateTests(unittest.TestCase):
    def fixture(self,root):
        for name in ('main.lua','_meta.lua','LICENSE','NOTICE','README.md'):(root/name).write_text(name)
        for name in ('fonts','icons','integrations','weread'):
            (root/name).mkdir();(root/name/'part').write_text(name)
    def archive(self,root,path,mode):
        with zipfile.ZipFile(path,'w') as z:
            for item in root.rglob('*'):
                if not item.is_file() or item==path:continue
                name=item.relative_to(root).as_posix()
                if mode=='missing' and name=='main.lua':continue
                z.writestr('weread.koplugin/'+name,'changed' if mode=='changed' and name=='main.lua' else item.read_bytes())
            if mode=='extra':z.writestr('weread.koplugin/extra.lua','x')
            if mode=='traversal':z.writestr('weread.koplugin/../outside','x')
            if mode=='link':
                info=zipfile.ZipInfo('weread.koplugin/link');info.external_attr=(0o120777<<16);z.writestr(info,'target')
    def test_exact_archive_and_rejections(self):
        for mode in ('valid','missing','changed','extra','traversal','link','source_link'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                root=Path(directory)/'src';root.mkdir();self.fixture(root);archive=Path(directory)/'candidate.zip'
                self.archive(root,archive,mode)
                if mode=='source_link':(root/'weread'/'link').symlink_to(root/'main.lua')
                if mode=='valid':self.assertEqual(check(root,archive),9)
                else:
                    with self.assertRaises(ValueError):check(root,archive)


if __name__=='__main__':unittest.main()
