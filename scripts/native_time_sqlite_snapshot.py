"""Create consistent logical SQLite backups inside an already-private tmpfs."""
import base64
import hashlib
import sqlite3

from native_time_capture_evidence import MAX_DATABASE, PROTOCOL, account_key, validate_evidence


def snapshot(path,output):
    if not path.is_file() or path.is_symlink() or output.exists() or output.is_symlink():
        raise ValueError('capture_snapshot/path')
    source=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True)
    target=sqlite3.connect(str(output))
    try:
        source.execute('PRAGMA query_only=ON')
        source.backup(target)
        if target.execute('PRAGMA journal_mode=DELETE').fetchone()!=('delete',):raise ValueError('capture_snapshot/journal')
        if target.execute('PRAGMA quick_check(1)').fetchall()!=[('ok',)]:raise ValueError('capture_snapshot/integrity')
    finally:
        source.close();target.close()
    raw=output.read_bytes()
    if not 512<=len(raw)<=MAX_DATABASE:raise ValueError('capture_snapshot/size')
    return base64.b64encode(raw).decode(),hashlib.sha256(raw).hexdigest()


def take(profile,output,plan,*,mock=False):
    directory=profile/('weread-mock' if mock else 'weread')
    if directory.is_symlink() or not directory.is_dir() or output.is_symlink() or not output.is_dir():
        raise ValueError('capture_snapshot/path')
    lb,lh=snapshot(directory/('offline-time-'+account_key(plan['owner'])+'.db'),output/'capture-ledger.db')
    cb,ch=snapshot(directory/'reading-time-coverage.db',output/'capture-coverage.db')
    evidence={'protocol':PROTOCOL,'ledger_base64':lb,'ledger_sha256':lh,'coverage_base64':cb,'coverage_sha256':ch}
    validate_evidence(plan,evidence)
    return evidence
