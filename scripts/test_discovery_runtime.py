#!/usr/bin/env python3
"""Render the packaged plugin in an isolated real KOReader SDL runtime.

Linux: run under xvfb-run when no desktop display is available.
No production account or WeRead requests are used.
"""
import argparse
import hashlib
import json
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
    parser.add_argument("--offline-progress", action="store_true", help="Also exercise offline movement and fresh-process reconnection")
    parser.add_argument("--progress-response", action="store_true", help="Reject foreign/malformed sync responses in the reading flow")
    parser.add_argument('--progress-confirmation', action='store_true', help='Exercise delayed and unconfirmed position write receipts')
    parser.add_argument('--source-upload',action='store_true',help='Verify native source wire coordinates and periodic preparation')
    parser.add_argument('--source-recovery',action='store_true',help='Verify source HTTP 401 recovery against mock credential maintenance')
    parser.add_argument('--progress-recovery',action='store_true',help='Verify progress preflight HTTP 401 recovery against mock credential maintenance')
    parser.add_argument('--recovery-save-retry',action='store_true',help='Verify native save-only retry during progress and source recovery')
    parser.add_argument('--shelf-membership-write',action='store_true',help='Verify native single-book membership changes against the mock service')
    parser.add_argument('--owner-roundtrip',action='store_true',help='Exercise the bounded native executor only against this mock service')
    parser.add_argument("--footnotes", action="store_true", help="Exercise native footnote rendering, taps and reader settings")
    parser.add_argument('--cached-resume',action='store_true',help='Exercise multiple cached chapters and full-book reading')
    parser.add_argument('--content-format',choices=('epub','txt'),default='epub')
    parser.add_argument('--resume-handoff',action='store_true',help='Check exact reading transfer from a chapter to the full EPUB')
    args = parser.parse_args()
    if args.offline_progress and not args.reading_flow:
        parser.error("--offline-progress requires --reading-flow")
    if args.progress_response and not args.reading_flow:
        parser.error("--progress-response requires --reading-flow")
    if args.progress_confirmation and not args.reading_flow:
        parser.error('--progress-confirmation requires --reading-flow')
    if args.owner_roundtrip and not args.reading_flow:parser.error('--owner-roundtrip requires --reading-flow')
    if args.source_upload and not args.reading_flow:parser.error('--source-upload requires --reading-flow')
    if args.source_recovery and not args.reading_flow:parser.error('--source-recovery requires --reading-flow')
    if args.progress_recovery and not args.reading_flow:parser.error('--progress-recovery requires --reading-flow')
    if args.shelf_membership_write and not args.reading_flow:parser.error('--shelf-membership-write requires --reading-flow')
    if args.recovery_save_retry and not (args.reading_flow and args.source_upload and args.source_recovery and args.progress_recovery):
        parser.error('--recovery-save-retry requires --reading-flow --source-upload --source-recovery --progress-recovery')
    if args.footnotes and args.reading_flow:
        parser.error("--footnotes and --reading-flow use separate fixtures")
    if args.cached_resume and (args.footnotes or args.reading_flow):
        parser.error('--cached-resume uses a separate fixture')
    if args.content_format!='epub' and not args.cached_resume:
        parser.error('--content-format txt requires --cached-resume')
    if args.resume_handoff and not args.cached_resume:
        parser.error('--resume-handoff requires --cached-resume')
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
    server.content_format=args.content_format
    environment['WEREAD_TEST_CONTENT_FORMAT']=args.content_format
    if args.resume_handoff:
        environment['WEREAD_TEST_RESUME_HANDOFF']='1'
    server.progress[BOOK_ID] = dict(chapterUid=2, chapterIdx=2, chapterOffset=120, progress=37, summary="合成进度")
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment["WEREAD_MOCK_PORT"] = str(server.server_port)
    if args.offline_progress:
        environment["WEREAD_TEST_OFFLINE_PROGRESS"] = "1"
    if args.progress_response:
        environment["WEREAD_TEST_PROGRESS_RESPONSE"] = "1"
    if args.progress_confirmation: environment['WEREAD_TEST_PROGRESS_CONFIRMATION'] = '1'
    if args.source_upload:environment['WEREAD_TEST_SOURCE_UPLOAD']='1'
    if args.source_recovery:environment['WEREAD_TEST_SOURCE_RECOVERY']='1'
    if args.progress_recovery:environment['WEREAD_TEST_PROGRESS_RECOVERY']='1'
    if args.recovery_save_retry:environment['WEREAD_TEST_RECOVERY_SAVE_RETRY']='1'
    if args.shelf_membership_write:environment['WEREAD_TEST_SHELF_MEMBERSHIP_WRITE']='1'
    if args.owner_roundtrip:
        from mock_weread import chapter_html
        from verify_source_coordinates import FilteredSource
        from verify_position_roundtrip import prepare_plan
        raw=chapter_html(2);co=FilteredSource(raw).starts[30]
        point=dict(chapterUid=2,chapterIdx=2,chapterOffset=co,progress=37,summary='synthetic')
        plan=prepare_plan(BOOK_ID,dict(book=point),dict(book_id=BOOK_ID,psvts='synthetic',pclts='synthetic-pc',progress=dict(book=point)),raw)
        assert plan['target'] is not None
        server.roundtrip_seed=point.copy();server.progress[BOOK_ID]=point.copy()
        private=dict(vid='900000',book_id=BOOK_ID,chapter_uid='2',source_format='web_xhtml',source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),
                     progress_roundtrip={k:plan[k] for k in ('baseline','target')})
        private['progress_roundtrip'].update(permit_writes=True,intent_digest='a'*64)
        fixture=root/'evidence/synthetic-roundtrip-input.json';fixture.write_text(json.dumps(private))
        environment['WEREAD_TEST_OWNER_ROUNDTRIP']=str(fixture)
    try:
        with (root / "evidence/runtime.log").open("w") as log:
            fixture = "book_reading_smoke.lua" if args.reading_flow else "discovery_smoke.lua"
            if args.cached_resume:
                fixture='cached_resume_smoke.lua'
            fixture_args = []
            if args.footnotes:
                fixture = "book_footnotes_render.lua"
                fixture_args = [str(root / "profile/plugins/weread.koplugin"), str(root / "evidence")]
            result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / fixture), *fixture_args],
                                    cwd=runtime, env=environment, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=120)
            if (args.reading_flow or args.cached_resume) and result.returncode == 0:
                if args.cached_resume:
                    assert server.request_totals[('/web/book/read','')]==0,'cached reading wrote progress/time'
                before = server.request_totals.copy()
                result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / fixture)],
                                        cwd=runtime, env=dict(environment, WEREAD_READING_REOPEN="1"),
                                        stdout=log, stderr=subprocess.STDOUT, timeout=120)
                assert server.request_totals == before, "offline reopen contacted the mock service"
                if args.cached_resume and result.returncode==0:
                    (root/'evidence/cached-resume-offline.json').write_text(json.dumps(dict(
                        result='PASS',fresh_process=True,offline_http_requests=0,progress_or_time_posts=0),indent=2)+'\n')
                if args.offline_progress and result.returncode == 0:
                    writes_before = server.request_totals[("/web/book/read", "")]
                    result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / fixture)],
                                            cwd=runtime, env=dict(environment, WEREAD_READING_RECONNECT="1"),
                                            stdout=log, stderr=subprocess.STDOUT, timeout=120)
                    # One reading-session entry and one progress update, both zero-time.
                    assert server.request_totals[("/web/book/read", "")] == writes_before + 2, "reconnect repeated or omitted the chosen upload sequence"
            if args.footnotes and result.returncode == 0:
                from verify_book_footnotes import inspect_epub
                packages = list((root / "evidence").glob("*.epub"))
                assert len(packages) == 1, "expected one native footnote fixture EPUB"
                inspected = inspect_epub(packages[0])
                assert inspected["noterefs"] == 5 and inspected["generated_footnotes"] == 4
                for key in ("duplicate_ids", "broken_targets", "broken_backlinks", "broken_local_links",
                            "unreferenced_generated_notes", "missing_generated_backlinks"):
                    assert inspected[key] == 0, key
                (root / "evidence/footnotes-package.json").write_text(json.dumps(inspected, indent=2) + "\n")
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
