#!/usr/bin/env python3
"""Create an immutable, content-addressed plugin candidate without overwrites."""
import argparse,hashlib,json,os,stat,zipfile
from pathlib import Path

from check_cb_dry_candidate import check,source_files


def build(source,directory):
    paths=source_files(source);directory=Path(directory)
    if directory.is_symlink() or not directory.is_dir():raise ValueError('cb_dry_build/directory')
    hasher=hashlib.sha256()
    for name,path in sorted(paths.items()):
        data=path.read_bytes()
        if len(data)>16*1024*1024:raise ValueError('cb_dry_build/source')
        hasher.update(name.encode('utf-8')+b'\0'+hashlib.sha256(data).digest())
    filename='cb-dry-candidate-'+hasher.hexdigest()+'.zip';target=directory/filename
    fd=None;created=False;identity=None
    try:
        try:
            fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_CLOEXEC',0),0o600)
            created=True;info=os.fstat(fd);identity=(info.st_dev,info.st_ino)
        except FileExistsError:
            info=target.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid():raise ValueError('cb_dry_build/existing')
        if created:
            with os.fdopen(fd,'wb') as output:
                fd=None
                with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED) as archive:
                    for name,path in sorted(paths.items()):archive.writestr('weread.koplugin/'+name,path.read_bytes())
                output.flush();os.fsync(output.fileno())
        count=check(source,target)
        return target,count
    except Exception:
        if created:
            try:
                info=target.lstat()
                if stat.S_ISREG(info.st_mode) and (info.st_dev,info.st_ino)==identity:target.unlink()
            except OSError:pass
        raise
    finally:
        if fd is not None:os.close(fd)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--source',required=True,type=Path);parser.add_argument('--directory',required=True,type=Path)
    args=parser.parse_args(argv)
    try:
        path,count=build(args.source,args.directory);report=dict(result='CANDIDATE_READY',files=count,path=str(path))
    except (OSError,ValueError,zipfile.BadZipFile):report=dict(result='UNVERIFIED')
    print(json.dumps(report));return int(report['result']!='CANDIDATE_READY')


if __name__=='__main__':raise SystemExit(main())
