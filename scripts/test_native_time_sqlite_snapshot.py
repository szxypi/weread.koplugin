"""Private SQLite backup uses committed WAL data and rejects unsafe paths."""
import base64
import hashlib
from pathlib import Path
import sqlite3
import tempfile
import unittest

from native_time_sqlite_snapshot import snapshot


class SnapshotTests(unittest.TestCase):
    def test_committed_wal_is_included_in_standalone_backup(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);source=root/'source.db';output=root/'backup.db'
            writer=sqlite3.connect(str(source));writer.execute('PRAGMA journal_mode=WAL')
            writer.execute('PRAGMA wal_autocheckpoint=0');writer.execute('CREATE TABLE records(value INTEGER)')
            writer.execute('INSERT INTO records VALUES(7)');writer.commit()
            data,checksum=snapshot(source,output);raw=base64.b64decode(data)
            self.assertEqual(hashlib.sha256(raw).hexdigest(),checksum)
            reader=sqlite3.connect(':memory:');reader.deserialize(raw)
            self.assertEqual(reader.execute('SELECT value FROM records').fetchall(),[(7,)])
            reader.close();writer.close()

    def test_missing_existing_or_symlinked_paths_fail(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);source=root/'source.db';output=root/'backup.db'
            con=sqlite3.connect(source);con.execute('CREATE TABLE records(value INTEGER)');con.close()
            with self.assertRaises(ValueError):snapshot(root/'missing',output)
            output.write_bytes(b'existing')
            with self.assertRaises(ValueError):snapshot(source,output)
            output.unlink();link=root/'link.db';link.symlink_to(source)
            with self.assertRaises(ValueError):snapshot(link,output)


if __name__=='__main__':unittest.main()
