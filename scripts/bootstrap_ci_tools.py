#!/usr/bin/env python3
"""Install pinned CI tools in a fresh private prefix, without system packages.

Sources and release binaries come from upstream GitHub with fixed SHA-256.
Requires Linux, Python, make, gcc, git and the existing SQLite runtime. The
optional archive directory is strictly offline and still verifies every hash.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path,PurePosixPath
import platform
import re
import shlex
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlsplit
from urllib.request import build_opener,HTTPRedirectHandler

REPO=Path(__file__).resolve().parent.parent
MAX_ARCHIVE=32*1024*1024
MAX_CONTENT=64*1024*1024
HOSTS={'github.com','codeload.github.com','objects.githubusercontent.com','release-assets.githubusercontent.com'}


def safe_url(value):
    p=urlsplit(value)
    if p.scheme!='https' or p.hostname not in HOSTS or p.username or p.password or p.port not in (None,443):
        raise ValueError('CI tool download requires an upstream HTTPS endpoint')
    return value


class UpstreamRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        safe_url(newurl)
        return super().redirect_request(req,fp,code,msg,headers,newurl)


def load_lock(path=REPO/'scripts/ci_toolchain.lock.json'):
    value=json.loads(path.read_text())
    if (not isinstance(value,dict) or set(value)!={'schema','sources','ripgrep'} or type(value['schema']) is not int or value['schema']!=1
            or set(value['sources'])!={'luajit','luacheck','luafilesystem','argparse'} or set(value['ripgrep'])!={'x86_64','aarch64'}):
        raise ValueError('Invalid CI tool lock')
    for group in ('sources','ripgrep'):
        for row in value[group].values():
            fields={'version','url','sha256'}|({'commit'} if group=='sources' else set())
            if (not isinstance(row,dict) or set(row)!=fields or not isinstance(row['version'],str)
                    or not re.fullmatch('[0-9A-Za-z._-]{1,64}',row['version']) or not re.fullmatch('[0-9a-f]{64}',row['sha256'])
                    or group=='sources' and not re.fullmatch('[0-9a-f]{40}',row['commit'])):raise ValueError('Invalid CI tool pin')
            safe_url(row['url'])
            if group=='sources' and not row['url'].endswith('/'+row['commit']):raise ValueError('CI source is not pinned to its commit')
    return value


def archive_bytes(name,row,archives=None,opener=None):
    if not re.fullmatch('[a-z0-9_-]+',name):raise ValueError('Invalid CI artifact name')
    if archives is not None:
        path=archives/(name+'-'+row['sha256']+'.tar.gz')
        if path.is_symlink() or not path.is_file():raise ValueError('Missing offline CI archive: '+name)
        with path.open('rb') as stream:raw=stream.read(MAX_ARCHIVE+1)
    else:
        opener=opener or build_opener(UpstreamRedirect())
        with opener.open(safe_url(row['url']),timeout=45) as response:raw=response.read(MAX_ARCHIVE+1)
    if len(raw)>MAX_ARCHIVE or hashlib.sha256(raw).hexdigest()!=row['sha256']:raise ValueError('CI archive hash mismatch: '+name)
    return raw


def unpack(raw,destination):
    # Check the whole archive before creating a directory or writing a member.
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as archive:
        members=archive.getmembers();names=set();roots=set();total=0
        if not members or len(members)>4096:raise ValueError('Invalid CI archive layout')
        for member in members:
            path=PurePosixPath(member.name)
            if (path.is_absolute() or '..' in path.parts or not path.parts or not (member.isdir() or member.isfile())
                    or str(path) in names):raise ValueError('Unsafe CI archive member')
            names.add(str(path));roots.add(path.parts[0]);total+=member.size
            if member.size<0 or total>MAX_CONTENT:raise ValueError('CI archive exceeds extracted limit')
        if len(roots)!=1:raise ValueError('CI archive must have one root')
        destination.mkdir()
        archive.extractall(destination,members=members,filter='data')
        root=destination/roots.pop()
        if not root.is_dir():raise ValueError('CI archive root is not a directory')
        return root


def fresh_prefix(value):
    prefix=Path(value).resolve()
    if (not re.fullmatch(r'[A-Za-z0-9_./-]+',str(prefix)) or prefix.is_relative_to(REPO)
            or prefix.exists() or not prefix.parent.is_dir()):raise ValueError('CI prefix must be fresh, outside the repository, with an existing parent')
    return prefix


def run(command,cwd=None,*,capture=False):
    return subprocess.run([str(item) for item in command],cwd=cwd,check=True,
                          stdout=subprocess.PIPE if capture else None,text=True).stdout


def install(prefix,archives=None):
    if platform.system()!='Linux' or platform.machine() not in ('x86_64','aarch64'):raise ValueError('Linux x86_64 or aarch64 is required')
    prefix=fresh_prefix(prefix);lock=load_lock();arch=platform.machine()
    for command in ('make','gcc','git'):
        if shutil.which(command) is None:raise ValueError('Missing CI image prerequisite: '+command)
    # Download and verify all inputs before compiling or publishing any tool.
    artifacts={key:archive_bytes(key,row,archives) for key,row in lock['sources'].items()}
    artifacts['ripgrep']=archive_bytes('ripgrep-'+arch,lock['ripgrep'][arch],archives)
    prefix.mkdir()
    with tempfile.TemporaryDirectory(prefix='.weread-ci-build-',dir=prefix.parent) as temporary:
        work=Path(temporary);sources={key:unpack(raw,work/key) for key,raw in artifacts.items()}
        run(['make','-j2','PREFIX='+str(prefix)],sources['luajit'])
        run(['make','install','PREFIX='+str(prefix)],sources['luajit'])
        lfs_options=['PREFIX='+str(prefix),'LUA_VERSION=5.1','LUA_INC=-I'+str(prefix/'include/luajit-2.1')]
        run(['make','-j2',*lfs_options],sources['luafilesystem'])
        run(['make','install',*lfs_options],sources['luafilesystem'])
        lua=prefix/'share/lua/5.1';lua.mkdir(parents=True,exist_ok=True)
        shutil.copytree(sources['luacheck']/'src/luacheck',lua/'luacheck')
        shutil.copyfile(sources['argparse']/'src/argparse.lua',lua/'argparse.lua')
        entry=prefix/'share/luacheck/luacheck.lua';entry.parent.mkdir();shutil.copyfile(sources['luacheck']/'bin/luacheck.lua',entry)
        wrapper=prefix/'bin/luacheck'
        wrapper.write_text('#!/bin/sh\nexport LUA_PATH='+shlex.quote(str(lua/'?.lua')+';'+str(lua/'?/init.lua')+';;')
            +'\nexport LUA_CPATH='+shlex.quote(str(prefix/'lib/lua/5.1/?.so')+';;')
            +'\nexec '+shlex.quote(str(prefix/'bin/luajit'))+' '+shlex.quote(str(entry))+' "$@"\n')
        wrapper.chmod(0o755)
        rg=prefix/'bin/rg';shutil.copyfile(sources['ripgrep']/'rg',rg);rg.chmod(0o755)
        for name,source in sources.items():
            for path in source.iterdir():
                if path.is_file() and path.name.upper().startswith(('LICENSE','COPYRIGHT','COPYING','UNLICENSE')):
                    target=prefix/'share/licenses'/name;target.mkdir(parents=True,exist_ok=True)
                    shutil.copyfile(path,target/path.name)
    run([prefix/'bin/luajit','-e',
        'assert(jit and jit.version_num>=20100);assert(require("lfs").attributes(".","mode")=="directory");'
        'local ffi=require("ffi");local ok=pcall(ffi.load,"sqlite3");if not ok then assert(ffi.load("libsqlite3.so.0")) end'])
    lint=run([wrapper,'--version'],capture=True)
    if not all(text in lint for text in ('Luacheck: 1.2.0','Argparse: 0.7.2','LuaFileSystem: 1.9.0')):raise ValueError('CI Lua tool versions do not match the lock')
    run([rg,'--pcre2-version']);run([rg,'--version']);run([prefix/'bin/luajit','-v']);print(lint,end='')
    result=dict(result='PASS',architecture=arch,lock_sha256=hashlib.sha256((REPO/'scripts/ci_toolchain.lock.json').read_bytes()).hexdigest(),
        source_hashes={key:row['sha256'] for key,row in lock['sources'].items()},ripgrep_sha256=lock['ripgrep'][arch]['sha256'])
    (prefix/'verified-install.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--prefix',required=True,type=Path)
    parser.add_argument('--archives',type=Path,help='Use only these verified local archives; no network fallback')
    args=parser.parse_args();print(json.dumps(install(args.prefix,args.archives)));return 0


if __name__=='__main__':raise SystemExit(main())
