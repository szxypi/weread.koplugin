"""Candidate creation is content-addressed and never overwrites old files."""
import tempfile,unittest,zipfile
from pathlib import Path

from build_cb_dry_candidate import build
from check_cb_dry_candidate import check
import test_check_cb_dry_candidate as fixtures


class DryBuildTests(unittest.TestCase):
    def test_exact_reuse_and_changed_source_gets_a_new_name(self):
        with tempfile.TemporaryDirectory() as directory:
            parent=Path(directory);source=parent/'src';source.mkdir();output=parent/'output';output.mkdir()
            fixtures.DryCandidateTests().fixture(source)
            first,count=build(source,output);original=first.read_bytes();identity=first.stat().st_ino
            self.assertEqual(count,9);self.assertEqual(check(source,first),count)
            again,_count=build(source,output);self.assertEqual(again,first);self.assertEqual(again.stat().st_ino,identity)
            (source/'main.lua').write_text('modified source')
            second,_count=build(source,output);self.assertNotEqual(second,first);self.assertEqual(first.read_bytes(),original)
            self.assertEqual(check(source,second),9)
    def test_existing_damaged_candidate_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            parent=Path(directory);source=parent/'src';source.mkdir();output=parent/'output';output.mkdir()
            fixtures.DryCandidateTests().fixture(source);target,_count=build(source,output);target.write_bytes(b'existing data')
            with self.assertRaises((ValueError,zipfile.BadZipFile)):build(source,output)
            self.assertEqual(target.read_bytes(),b'existing data')
    def test_symlink_candidate_and_source_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            parent=Path(directory);source=parent/'src';source.mkdir();output=parent/'output';output.mkdir()
            fixtures.DryCandidateTests().fixture(source);target,_count=build(source,output);target.unlink();other=parent/'other';other.write_text('leave alone');target.symlink_to(other)
            with self.assertRaises(ValueError):build(source,output)
            self.assertEqual(other.read_text(),'leave alone')
            (source/'weread'/'link').symlink_to(source/'main.lua')
            with self.assertRaises(ValueError):build(source,output)


if __name__=='__main__':unittest.main()
