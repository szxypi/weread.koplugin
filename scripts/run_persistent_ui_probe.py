#!/usr/bin/env python3
"""Linux-only two-process native UI acceptance, with a private tmpfs profile."""
import argparse
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import zipfile

from verify_persistent_ui import FRAME, RUNNER_ERRORS, decode_stage


def extract_candidate(candidate, destination):
    with zipfile.ZipFile(candidate) as archive:
        names = set()
        for item in archive.infolist():
            parts = Path(item.filename).parts
            mode = item.external_attr >> 16
            if (not item.filename.startswith('weread.koplugin/') or '..' in parts
                    or item.filename in names or mode & 0o170000 not in (0, 0o100000, 0o040000)):
                raise ValueError('candidate_layout')
            names.add(item.filename)
        archive.extractall(destination)


def run_child(command, environment, raw, cwd=None, *, timeout=150):
    child = subprocess.Popen(command, env=environment, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, cwd=cwd)
    try:
        out, err = child.communicate(raw, timeout=timeout)
        for domain in set(re.findall(rb'(?m)^WEREAD_PUBLIC_COVER_DOMAIN=([a-z-]{1,63}\.[a-z]{2,12})$', err)):
            sys.stderr.buffer.write(b'WEREAD_PUBLIC_COVER_DOMAIN=' + domain + b'\n')
        return child.returncode, out, b'[WeRead] forceRePaint failed:' in out + err
    finally:
        # A timed-out parent may leave bitmap/progress children. Kill its private
        # process group and wait for the parent before removing profile paths.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        for stream in (child.stdin, child.stdout, child.stderr):
            if stream is not None:
                stream.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    parser.add_argument('--all-shelf-pages',action='store_true')
    args = parser.parse_args(argv)
    runtime = args.koreader.resolve()
    if sys.platform != 'linux' or not (runtime / 'luajit').is_file() or min(args.width, args.height, args.dpi) < 1:
        parser.error('requires Linux, a built runtime and positive display dimensions')
    if not any(line.split()[1:3] == ['/dev/shm', 'tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        parser.error('/dev/shm must be tmpfs')
    report = dict(result='UNVERIFIED', tmpfs_profile=True, profile_removed=False, stages=[], runner_error='none')
    root = None
    try:
        raw = sys.stdin.buffer.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise ValueError('input_limit')
        payload=json.loads(raw)
        if not isinstance(payload,dict) or payload.get('all_shelf_pages',False) is not args.all_shelf_pages:
            raise ValueError('input_limit')
        with tempfile.TemporaryDirectory(prefix='weread-persistent-', dir='/dev/shm') as temporary:
            root = Path(temporary)
            profile, xdg = root / 'profile', root / 'xdg'
            (profile / 'plugins').mkdir(parents=True)
            xdg.mkdir(mode=0o700)
            extract_candidate(args.candidate, profile / 'plugins')
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg),
                       EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                       EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
                       EMULATE_READER_DPI=str(args.dpi))
            probe = Path(__file__).resolve().parent.parent / 'spec/koreader/persistent_ui_probe.lua'
            for mode in ('live', 'reopen'):
                code, out, repaint = run_child([str(runtime / 'luajit'), str(probe), mode], env, raw, runtime,
                                              timeout=600 if args.all_shelf_pages else 150)
                stage = decode_stage(out, mode,all_shelf_pages=args.all_shelf_pages)
                report['stages'].append(stage)
                if code or repaint or stage['result'] != 'PASS':
                    raise ValueError('stage_unverified')
            report['result'] = 'PASS'
    except subprocess.TimeoutExpired:
        report['result'], report['runner_error'] = 'UNVERIFIED', 'child_timeout'
    except Exception as exc:
        report['result'] = 'UNVERIFIED'
        report['runner_error'] = str(exc) if str(exc) in RUNNER_ERRORS else 'runner_exception'
    finally:
        report['profile_removed'] = root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME + json.dumps(report).encode() + b'\n')
    return 0 if report['result'] == 'PASS' and report['profile_removed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
