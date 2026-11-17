"""Validate exact SQLite evidence for a future isolated native capture.

These checks establish internal consistency only; authentic collection and
immutable storage must be enforced by the capture runner. No network or writes.
"""
import base64
import hashlib
import sqlite3

from native_time_capture import hashed, validate
from readtime_upload_model import integer

PROTOCOL='native-statistics-sqlite-evidence-v1'
MAX_DATABASE=2*1024*1024
FIELDS={'protocol','ledger_base64','ledger_sha256','coverage_base64','coverage_sha256'}


def account_key(owner):
    return hashlib.sha256(('weread-library:'+owner).encode()).hexdigest()[:20]


def database(value, expected):
    if (not isinstance(value,str) or len(value)>4*((MAX_DATABASE+2)//3) or not hashed(expected)):
        raise ValueError('capture_evidence/database')
    try:
        raw=base64.b64decode(value,validate=True)
        if not 512<=len(raw)<=MAX_DATABASE or not raw.startswith(b'SQLite format 3\0') or hashlib.sha256(raw).hexdigest()!=expected:
            raise ValueError()
        connection=sqlite3.connect(':memory:')
        try:
            connection.deserialize(raw)
            connection.execute('PRAGMA trusted_schema=OFF')
            connection.execute('PRAGMA query_only=ON')
            if connection.execute('PRAGMA quick_check(1)').fetchall()!=[('ok',)]:raise ValueError()
            forbidden=connection.execute("SELECT count(*) FROM sqlite_master WHERE type IN ('trigger','view') OR (type='table' AND lower(sql) LIKE '%virtual table%')").fetchone()[0]
            if forbidden:raise ValueError()
            return connection
        except Exception:
            connection.close()
            raise
    except Exception:
        raise ValueError('capture_evidence/database') from None


def validate_evidence(plan,evidence):
    validate(plan)
    if not isinstance(evidence,dict) or set(evidence)!=FIELDS or evidence['protocol']!=PROTOCOL:
        raise ValueError('capture_evidence/format')
    ledger=coverage=None
    try:
        ledger=database(evidence['ledger_base64'],evidence['ledger_sha256'])
        coverage=database(evidence['coverage_base64'],evidence['coverage_sha256'])
        # A disposable capture starts empty; extra rows must never be hidden.
        if ledger.execute('SELECT count(*) FROM windows').fetchone()[0]!=1:
            raise ValueError('capture_evidence/ledger')
        if ledger.execute('SELECT count(*) FROM segments').fetchone()[0]!=len(plan['rows']):
            raise ValueError('capture_evidence/ledger')
        rows=ledger.execute('''SELECT s.id,w.book_id,s.start_time,s.duration,w.time_zone,w.book_version,w.file_id,w.version_source,s.state,s.attempt,w.closed,w.start_time,w.last_seen
                               FROM segments s JOIN windows w ON s.window_id=w.id ORDER BY s.id''').fetchall()
        keys=('id','book_id','start_time','duration','time_zone','book_version','file_id','version_source')
        if (len(rows)!=len(plan['rows']) or any(dict(zip(keys,row[:8]))!=expected or row[8:]!=('pending','',1,plan['start_time'],plan['ended_at'])
                for row,expected in zip(rows,plan['rows']))):
            raise ValueError('capture_evidence/ledger')
        if (ledger.execute('SELECT count(*) FROM marks').fetchone()[0] or ledger.execute('SELECT count(*) FROM aliases').fetchone()[0]
                or ledger.execute('SELECT count(*) FROM transfer_receipts').fetchone()[0]):
            raise ValueError('capture_evidence/ledger')
        totals=ledger.execute('SELECT name,seconds FROM totals').fetchall()
        if totals!=[('capture_floor',plan['ended_at'])]:raise ValueError('capture_evidence/ledger')
        since=coverage.execute("SELECT value FROM coverage_meta WHERE name='tracked_since'").fetchall()
        if (len(since)!=1 or not integer(since[0][0],1,plan['start_time'])
                or coverage.execute('SELECT count(*) FROM offline_time_records').fetchone()[0]):
            raise ValueError('capture_evidence/coverage')
        scope=account_key(plan['owner']);start=plan['start_time'];end=plan['ended_at']
        overlapping=coverage.execute("SELECT count(*) FROM coverage WHERE (scope=? OR scope='') AND start_time<? AND end_time>?",(scope,end,start)).fetchone()[0]
        sealed=coverage.execute('SELECT count(*) FROM offline_time_seals WHERE scope=? AND start_time<? AND end_time>?',(scope,end,start)).fetchone()[0]
        if overlapping or sealed:raise ValueError('capture_evidence/coverage')
    except (sqlite3.Error,TypeError,KeyError,IndexError):
        raise ValueError('capture_evidence/database') from None
    finally:
        if ledger:ledger.close()
        if coverage:coverage.close()
    return evidence
