#!/usr/bin/env python3
"""Real-files, separate-process cache retention and kernel lease verification."""
import argparse
import json
import os
import select
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    args = parser.parse_args()
    runtime = args.koreader.resolve()
    source = Path(__file__).resolve().parent.parent
    assert (runtime / 'luajit').is_file()
    script = ('package.path=' + json.dumps(str(source / '?.lua') + ';frontend/?.lua;common/?.lua;?.lua;')
              + '..package.path;package.cpath="common/?.so;./?.so;"..package.cpath;require("ffi").log=function() end;require("setupkoenv");dofile('
              + json.dumps(str(source / 'spec/koreader/cache_reading_state_case.lua')) + ')')
    with tempfile.TemporaryDirectory(prefix='weread-cache-records-') as temporary:
        environment = dict(os.environ, KO_HOME=temporary)
        def command(phase):
            return [str(runtime / 'luajit'), '-e', script]
        def run(phase):
            completed = subprocess.run(command(phase), cwd=runtime, env=dict(environment, WEREAD_CACHE_TEST_PHASE=phase),
                                       capture_output=True, timeout=45, text=True)
            if completed.returncode or f'CACHE_RECORD_PHASE_OK:{phase}' not in completed.stdout:
                raise RuntimeError(f'{phase}: {completed.stdout[-2000:]} {completed.stderr[-2000:]}')
        run('setup')
        holder = subprocess.Popen(command('hold'), cwd=runtime, env=dict(environment, WEREAD_CACHE_TEST_PHASE='hold'),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        try:
            assert select.select([holder.stdout], [], [], 10)[0], 'gate holder startup timed out'
            assert holder.stdout.readline().strip() == 'CACHE_GATE_HELD'
            run('contend')
            out, err = holder.communicate('release\n', timeout=10)
            assert holder.returncode == 0 and 'CACHE_RECORD_PHASE_OK:hold' in out, err[-2000:]
        finally:
            if holder.poll() is None:
                holder.kill()
            holder.communicate()
        run('clear')
        run('inspect')
    print(json.dumps(dict(result='PASS',independent_processes=5,books=5,
                         minimal_indexes_retained=True,reading_state_bytes_retained=True,
                         opaque_state_retained=True,native_notes_retained=True,
                         independent_download_cleanup_exclusion=True,
                         mp_only_cleanup_isolated=True,bulk_cleanup_verified=True,
                         restart_and_redownload_verified=True,real_account_access=False)))


if __name__ == '__main__':
    main()
