#!/usr/bin/env python3
"""Exercise opt-in record protection through real reader.lua cold starts.

All profiles, articles and notes are synthetic; HTTP must remain unused.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import zipfile

from mock_weread import MockServer, prepare
from test_mp_metadata_runtime import filemanager_seed

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    parser.add_argument('--content', choices=('html', 'epub'), default='html')
    parser.add_argument('--scenario', choices=('restore', 'cancel', 'source-changed'), default='restore')
    args = parser.parse_args()
    if min(args.width, args.height, args.dpi) < 1:
        parser.error('positive screen dimensions required')
    root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    if not (runtime / 'reader.lua').is_file() or not (runtime / 'luajit').is_file():
        parser.error('requires a built KOReader runtime')
    server = MockServer(0, root / 'evidence/requests.jsonl')
    thread = None
    try:
        prepare(root, runtime, server.server_port, args.width, args.height, args.dpi)
        filemanager_seed(root)
        (root / 'xdg').mkdir(mode=0o700)
        environment = dict(os.environ, KO_HOME=str(root/'profile'), WEREAD_SOURCE=str(root/'profile/plugins/weread.koplugin'),
                           WEREAD_EVIDENCE=str(root/'evidence'), XDG_RUNTIME_DIR=str(root/'xdg'),
                           EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                           EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
                           EMULATE_READER_DPI=str(args.dpi), WEREAD_STARTUP_CONTENT=args.content)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        def run(name, command, phase=None):
            with (root/'evidence'/('startup-'+name+'.log')).open('w') as log:
                result = subprocess.run(command, cwd=runtime,
                                        env=environment if phase is None else dict(environment, WEREAD_STARTUP_PHASE=phase),
                                        stdout=log, stderr=subprocess.STDOUT, timeout=120)
            if result.returncode:
                raise RuntimeError('startup validation failed: '+name)
            assert not server.events, 'cold-start validation contacted HTTP'
            assert b'[WeRead] forceRePaint failed:' not in (root/'evidence'/('startup-'+name+'.log')).read_bytes()
        run('seed', ['./luajit', str(REPO/'spec/koreader/mp_legacy_metadata.lua'), 'startup-seed'])
        input_data = json.loads((root/'evidence/startup-input.json').read_text())
        patches = root/'profile/patches'
        assert Path(input_data['patch_path']).parent == patches and Path(input_data['patch_path']).is_file()
        shutil.copyfile(REPO/'spec/koreader/mp_startup_driver.lua', patches/'299-weread-validation-driver.lua')
        phases = ['restore', 'reopen'] if args.scenario == 'restore' else [args.scenario, 'restore', 'reopen']
        reports = []
        for phase in phases:
            command = ['./luajit', 'reader.lua']
            if args.content == 'epub' and phase != 'reopen':
                command.append(input_data['target'])  # actual explicit CLI file entry
            run(phase, command, phase)
            report = json.loads((root/'evidence'/('startup-'+phase+'.json')).read_text())
            assert report['result'] == 'PASS' and report['real_reader_lua_entry']
            reports.append(report)
        restored = json.loads((root/'evidence/startup-recovered.json').read_text())
        if args.content == 'epub':
            with zipfile.ZipFile(input_data['target']) as original, zipfile.ZipFile(restored['path']) as copy:
                assert original.namelist() == copy.namelist() and copy.testzip() is None
                assert all(original.read(name) == copy.read(name) for name in original.namelist())
        result = dict(result='PASS', synthetic_only=True, content=args.content, scenario=args.scenario,
                      real_reader_lua_processes=len(phases), seed_processes=1, reports=reports,
                      real_account_requests=0, keychain_accesses=0, mock_http_requests=0,
                      source_sha256_matches=hashlib.sha256(Path(input_data['target']).read_bytes()).hexdigest()==input_data['source_sha256'],
                      epub_member_bytes_verified=args.content=='epub')
        assert result['source_sha256_matches']
        (root/'evidence/startup-runtime.json').write_text(json.dumps(result, indent=2)+'\n')
        print('PASS: actual reader.lua startup, record selection and fresh direct reopen:', args.content, args.scenario)
    finally:
        if thread:
            server.shutdown(); thread.join()
        server.server_close()


if __name__ == '__main__':
    main()
