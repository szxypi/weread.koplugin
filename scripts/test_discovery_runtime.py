#!/usr/bin/env python3
"""Render the packaged plugin in an isolated real KOReader SDL runtime.

Linux: run under xvfb-run when no desktop display is available.
No production account or WeRead requests are used.
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import threading

from mock_weread import BOOK_ID, MockServer
import zipfile

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--width", type=int, default=600)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--dpi", type=int, default=167)
    parser.add_argument("--reading-flow", action="store_true", help="Exercise uncached Read and a fresh offline reopen")
    args = parser.parse_args()
    runtime, root = args.koreader.resolve(), args.run_dir.resolve()
    if not (runtime / "luajit").is_file() or not (runtime / "reader.lua").is_file():
        parser.error("--koreader must contain a built runtime")
    if min(args.width, args.height, args.dpi) < 1:
        parser.error("screen dimensions and DPI must be positive")
    root.mkdir(parents=True, exist_ok=False)
    for directory in ("profile/plugins", "evidence", "xdg"):
        (root / directory).mkdir(parents=True)
    (root / "xdg").chmod(0o700)
    archive = root / "candidate.zip"
    subprocess.run(["bash", str(REPO / "scripts/package_release.sh"), str(archive)], check=True)
    with zipfile.ZipFile(archive) as package:
        package.extractall(root / "profile/plugins")
    (root / "evidence/package.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "\n")
    environment = dict(os.environ, KO_HOME=str(root / "profile"),
                       WEREAD_SOURCE=str(root / "profile/plugins/weread.koplugin"),
                       WEREAD_EVIDENCE=str(root / "evidence"), XDG_RUNTIME_DIR=str(root / "xdg"),
                       EMULATE_READER="1", EMULATE_BW_SCREEN="1", EMULATE_BB_TYPE="BB8",
                       EMULATE_READER_W=str(args.width),
                       EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi))
    server = MockServer(0, root / "evidence/requests.jsonl")
    server.progress[BOOK_ID] = dict(chapterUid=2, chapterIdx=2, chapterOffset=120, progress=37, summary="合成进度")
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment["WEREAD_MOCK_PORT"] = str(server.server_port)
    try:
        with (root / "evidence/runtime.log").open("w") as log:
            fixture = "book_reading_smoke.lua" if args.reading_flow else "discovery_smoke.lua"
            result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / fixture)],
                                    cwd=runtime, env=environment, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=120)
            if args.reading_flow and result.returncode == 0:
                before = server.request_totals.copy()
                result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / fixture)],
                                        cwd=runtime, env=dict(environment, WEREAD_READING_REOPEN="1"),
                                        stdout=log, stderr=subprocess.STDOUT, timeout=120)
                assert server.request_totals == before, "offline reopen contacted the mock service"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    if result.returncode:
        print((root / "evidence/runtime.log").read_text())
    else:
        assert b"[WeRead] forceRePaint failed:" not in (root / "evidence/runtime.log").read_bytes(), "native repaint failed; inspect the isolated runtime log"
        print(f"PASS: packaged plugin; {args.width}x{args.height}; screenshots: {root / 'evidence'}")
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
