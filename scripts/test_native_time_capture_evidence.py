"""Fail closed on missing, stale, changed or overlapping SQLite evidence."""
import base64
from copy import deepcopy
import hashlib
import sqlite3
import unittest

import native_time_capture_evidence as evidence
from test_native_time_capture import capture


def encoded(db):
    raw=db.serialize()
    return base64.b64encode(raw).decode(),hashlib.sha256(raw).hexdigest()


def make_fixture():
    plan=capture('web_xhtml');row=plan['rows'][0]
    ledger=sqlite3.connect(':memory:')
    ledger.executescript('''CREATE TABLE windows(id INTEGER PRIMARY KEY,book_id TEXT,stats_book INTEGER,start_time INTEGER,last_seen INTEGER,time_zone TEXT,book_version INTEGER,closed INTEGER,file_id TEXT,version_source TEXT);
        CREATE TABLE segments(id INTEGER PRIMARY KEY,window_id INTEGER,start_time INTEGER,duration INTEGER,state TEXT,attempt TEXT);
        CREATE TABLE marks(x);CREATE TABLE aliases(x);CREATE TABLE transfer_receipts(x);CREATE TABLE totals(name TEXT,seconds INTEGER);''')
    ledger.execute('INSERT INTO windows VALUES(?,?,?,?,?,?,?,?,?,?)',(1,plan['book_id'],1,plan['start_time'],plan['ended_at'],'+08:00',plan['book_version'],1,plan['file_id'],'epub_snapshot'))
    ledger.execute('INSERT INTO segments VALUES(?,?,?,?,?,?)',(row['id'],1,row['start_time'],row['duration'],'pending',''))
    ledger.execute("INSERT INTO totals VALUES('capture_floor',?)",(plan['ended_at'],));ledger.commit()
    coverage=sqlite3.connect(':memory:')
    coverage.executescript('''CREATE TABLE coverage(scope TEXT,start_time INTEGER,end_time INTEGER);
        CREATE TABLE coverage_meta(name TEXT,value INTEGER);CREATE TABLE offline_time_records(attempt TEXT);
        CREATE TABLE offline_time_seals(scope TEXT,attempt TEXT,start_time INTEGER,end_time INTEGER);''')
    coverage.execute("INSERT INTO coverage_meta VALUES('tracked_since',?)",(plan['start_time'],));coverage.commit()
    return plan,ledger,coverage


def bundle(ledger,coverage):
    lb,lh=encoded(ledger);cb,ch=encoded(coverage)
    return dict(protocol=evidence.PROTOCOL,ledger_base64=lb,ledger_sha256=lh,coverage_base64=cb,coverage_sha256=ch)


class CaptureEvidenceTests(unittest.TestCase):
    def test_consistent_exact_capture_and_no_network_capability(self):
        plan,ledger,coverage=make_fixture();value=bundle(ledger,coverage)
        self.assertEqual(evidence.validate_evidence(plan,value),value)
        self.assertEqual(len(evidence.account_key(plan['owner'])),20)
        for name in ('send','claim','dispatch','post'):
            self.assertFalse(hasattr(evidence,name))
        ledger.close();coverage.close()

    def test_missing_stale_or_changed_database_fails(self):
        for mutation in ('hash','truncated','metadata','format','missing','extra'):
            plan,ledger,coverage=make_fixture();value=bundle(ledger,coverage)
            if mutation=='hash':value['ledger_sha256']='0'*64
            elif mutation=='truncated':value['ledger_base64']=value['ledger_base64'][:-4]
            elif mutation=='metadata':value['protocol']='other'
            elif mutation=='format':value['coverage_base64']=None
            elif mutation=='missing':del value['coverage_sha256']
            else:value['extra']=True
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):evidence.validate_evidence(plan,value)
            ledger.close();coverage.close()

    def test_ledger_rows_must_be_exact_pending_and_unsettled(self):
        changes=("UPDATE segments SET duration=duration-1", "UPDATE segments SET state='unknown'",
                 "UPDATE segments SET attempt='claimed'", "UPDATE windows SET closed=0",
                 "UPDATE windows SET last_seen=last_seen+1", "UPDATE windows SET book_version=book_version+1",
                 "INSERT INTO segments VALUES(2,1,1,1,'pending','')", "INSERT INTO transfer_receipts VALUES(1)",
                 "INSERT INTO totals VALUES('confirmed',6)", "CREATE VIEW injected AS SELECT * FROM windows")
        for sql in changes:
            plan,ledger,coverage=make_fixture();ledger.execute(sql);ledger.commit()
            with self.subTest(sql=sql),self.assertRaises(ValueError):evidence.validate_evidence(plan,bundle(ledger,coverage))
            ledger.close();coverage.close()

    def test_tracking_and_any_account_or_global_overlap_are_rejected(self):
        for mode in ('late','missing','pending','account_overlap','global_overlap','sealed'):
            plan,ledger,coverage=make_fixture();scope=evidence.account_key(plan['owner'])
            if mode=='late':coverage.execute("UPDATE coverage_meta SET value=? WHERE name='tracked_since'",(plan['start_time']+1,))
            elif mode=='missing':coverage.execute('DELETE FROM coverage_meta')
            elif mode=='pending':coverage.execute("INSERT INTO offline_time_records VALUES('x')")
            elif mode=='sealed':coverage.execute('INSERT INTO offline_time_seals VALUES(?,?,?,?)',(scope,'x',plan['start_time'],plan['ended_at']))
            else:coverage.execute('INSERT INTO coverage VALUES(?,?,?)',(scope if mode=='account_overlap' else '',plan['start_time'],plan['ended_at']))
            coverage.commit()
            with self.subTest(mode=mode),self.assertRaises(ValueError):evidence.validate_evidence(plan,bundle(ledger,coverage))
            ledger.close();coverage.close()

    def test_unrelated_and_nonoverlapping_coverage_are_retained(self):
        plan,ledger,coverage=make_fixture();scope=evidence.account_key(plan['owner'])
        coverage.execute('INSERT INTO coverage VALUES(?,?,?)',(scope,plan['start_time']-20,plan['start_time']))
        coverage.execute('INSERT INTO coverage VALUES(?,?,?)',('f'*20,plan['start_time'],plan['ended_at']))
        coverage.commit();evidence.validate_evidence(plan,bundle(ledger,coverage))
        ledger.close();coverage.close()


if __name__=='__main__':unittest.main()
