"""Restore one validated capture into an existing private Linux tmpfs folder."""
import base64
import os
from pathlib import Path
import stat
import sys

from native_time_capture_evidence import account_key,validate_evidence


def restore(bundle,root,*,imported=False):
    if not isinstance(bundle,dict) or set(bundle)!={'plan','evidence'}:raise ValueError('bundle_workspace/input')
    plan=bundle['plan'];evidence=validate_evidence(plan,bundle['evidence'],imported=imported)
    root=Path(root)
    try:
        if sys.platform!='linux' or root.is_symlink() or not root.resolve(strict=True).is_relative_to(Path('/dev/shm').resolve(strict=True)):
            raise ValueError()
        if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):raise ValueError()
        root_stat=root.stat()
        if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid!=os.geteuid() or root_stat.st_mode&0o077:raise ValueError()
    except (OSError,ValueError):raise ValueError('bundle_workspace/root') from None
    directory=None;ledger=None
    try:
        directory=os.open(root,os.O_RDONLY|os.O_DIRECTORY|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_CLOEXEC',0))
        os.mkdir('ledger',0o700,dir_fd=directory)
        ledger=os.open('ledger',os.O_RDONLY|os.O_DIRECTORY|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_CLOEXEC',0),dir_fd=directory)
        def write(parent,name,encoded):
            raw=base64.b64decode(encoded,validate=True)
            fd=os.open(name,os.O_RDWR|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_CLOEXEC',0),0o600,dir_fd=parent)
            with os.fdopen(fd,'w+b') as output:
                output.write(raw);output.flush();output.seek(0)
                if output.read()!=raw or os.fstat(output.fileno()).st_mode&0o077:raise ValueError('bundle_workspace/readback')
        write(directory,'source.epub',plan['archive_base64'])
        write(ledger,'offline-time-'+account_key(plan['owner'])+'.db',evidence['ledger_base64'])
        write(ledger,'reading-time-coverage.db',evidence['coverage_base64'])
        return root/'source.epub',root/'ledger'
    except (OSError,ValueError):raise ValueError('bundle_workspace/restore') from None
    finally:
        if ledger is not None:os.close(ledger)
        if directory is not None:os.close(directory)
