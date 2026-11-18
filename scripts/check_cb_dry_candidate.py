#!/usr/bin/env python3
"""Check that an isolated dry-run candidate exactly matches this source tree."""
import argparse,json,stat,zipfile
from pathlib import Path


def check(source,candidate):
    source=Path(source).resolve(strict=True);candidate=Path(candidate)
    names=('main.lua','_meta.lua','LICENSE','NOTICE','README.md')
    paths={name:source/name for name in names}
    for folder in ('fonts','icons','integrations','weread'):
        root=source/folder
        if root.is_symlink() or not root.is_dir():raise ValueError('cb_dry_candidate/source')
        for path in root.rglob('*'):
            if path.is_symlink():raise ValueError('cb_dry_candidate/source')
            if path.is_file() and path.name!='.DS_Store':paths[path.relative_to(source).as_posix()]=path
    if any(path.is_symlink() or not path.is_file() for path in paths.values()):raise ValueError('cb_dry_candidate/source')
    seen=set()
    with zipfile.ZipFile(candidate) as archive:
        for item in archive.infolist():
            name=item.filename
            if name in seen or not name.startswith('weread.koplugin/') or '..' in Path(name).parts:
                raise ValueError('cb_dry_candidate/archive')
            seen.add(name);mode=item.external_attr>>16
            if item.is_dir():
                if stat.S_IFMT(mode) not in (0,stat.S_IFDIR):raise ValueError('cb_dry_candidate/archive')
                continue
            relative=name.removeprefix('weread.koplugin/')
            if (stat.S_IFMT(mode) not in (0,stat.S_IFREG) or relative not in paths
                    or item.file_size!=paths[relative].stat().st_size or item.file_size>16*1024*1024
                    or archive.read(item)!=paths[relative].read_bytes()):raise ValueError('cb_dry_candidate/mismatch')
        if {name.removeprefix('weread.koplugin/') for name in seen if not name.endswith('/')}!=set(paths):
            raise ValueError('cb_dry_candidate/mismatch')
    return len(paths)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--source',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    args=parser.parse_args(argv)
    try:
        count=check(args.source,args.candidate);report=dict(result='CANDIDATE_MATCH',files=count)
    except (OSError,ValueError,zipfile.BadZipFile):report=dict(result='UNVERIFIED')
    print(json.dumps(report));return int(report['result']!='CANDIDATE_MATCH')


if __name__=='__main__':raise SystemExit(main())
