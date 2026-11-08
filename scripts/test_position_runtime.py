#!/usr/bin/env python3
"""Check local fractional or source/DOM positions in packaged, isolated KOReader."""
import argparse
import os
from pathlib import Path
import subprocess
import threading

from mock_weread import MockServer, prepare

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--probe", choices=("precision", "source-dom", "source-state"), default="precision",
                        help="fractional navigation (default), source/DOM mapping, or live reader-state capture")
    parser.add_argument("--width", type=int, default=600)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--dpi", type=int, default=167)
    args = parser.parse_args()
    if min(args.width, args.height, args.dpi) <= 0:
        parser.error("screen dimensions and DPI must be positive")
    root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    server = MockServer(0)
    try:
        prepare(root, runtime, server.server_port, args.width, args.height, args.dpi)
        (root / "xdg").mkdir(mode=0o700)
        server.log_path = root / "evidence/requests.jsonl"
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = os.environ | dict(KO_HOME=str(root / "profile"), WEREAD_EVIDENCE=str(root / "evidence"),
                                        XDG_RUNTIME_DIR=str(root / "xdg"),
                                        EMULATE_READER="1", EMULATE_READER_W=str(args.width),
                                        EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi),
                                        EMULATE_BW_SCREEN="1", EMULATE_BB_TYPE="BB8")
        log = root / "evidence/runtime.log"
        try:
            with log.open("w") as out:
                probe = {"precision": "position_precision_smoke.lua", "source-dom": "source_dom_smoke.lua",
                         "source-state": "source_position_smoke.lua"}[args.probe]
                result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / probe)],
                                        cwd=runtime, env=environment, stdout=out, stderr=subprocess.STDOUT, timeout=120)
        finally:
            server.shutdown()
            thread.join()
        print(("PASS" if result.returncode == 0 else "FAIL") + f": {log}")
        raise SystemExit(result.returncode)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
