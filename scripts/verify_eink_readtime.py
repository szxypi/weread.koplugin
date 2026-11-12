#!/usr/bin/env python3
"""Read-only preflight for native offline-time upload; never uploads anything.

Default: inspect /config and /feature anonymously. --interactive uses a local
QR, logs in, reads the shelf/config/feature/current position, and optionally
inspects a matching KOReader offline ledger in SQLite read-only mode. Tokens,
account IDs, book IDs, positions, payloads and QR data never enter the report.

Endpoint reference: MiuRead c1893562aa25a870b8dd076d7be062a3348f823e,
miuread/eink_readtime.lua and readtime_protocol.lua (AGPL-3.0-only).
Actual write/receipt validation and Web/E-Ink overlap coordination remain gates.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import time
from urllib.parse import urlencode
import webbrowser

from verify_eink_login import BASE, NativeProbe, ProbeError


def select_book(shelf, requested=None):
    for row in shelf.get("books", []):
        if not isinstance(row, dict):
            continue
        for _i in range(4):
            nested = row.get("bookInfo", row.get("book"))
            if not isinstance(nested, dict):
                break
            row = nested
        raw_id = row.get("bookId", row.get("book_id"))
        if not isinstance(raw_id, (int, str)) or isinstance(raw_id, bool):
            continue
        book_id = str(raw_id)
        if (re.fullmatch(r"[A-Za-z0-9_-]{1,256}", book_id) and book_id != "0"
                and not book_id.startswith("MP_WXS_") and (requested is None or book_id == requested)):
            return book_id
    raise ProbeError("book_selection: no matching ordinary shelf book")


def validate_position(data, book_id):
    for _i in range(4):
        if not isinstance(data, dict):
            break
        returned_id = data.get("bookId", data.get("book_id"))
        if returned_id is not None and str(returned_id) != book_id:
            raise ProbeError("time_position: response belongs to another book")
        uid, offset = data.get("chapterUid", data.get("chapter_uid")), data.get("chapterOffset", data.get("chapter_offset"))
        if uid is not None or offset is not None:
            if (not isinstance(uid, (int, str)) or isinstance(uid, bool) or str(uid) == ""
                    or not isinstance(offset, int) or isinstance(offset, bool) or offset < 0):
                break
            seconds = data.get("readingTime", data.get("recordReadingTime"))
            return dict(chapter_uid=str(uid), chapter_offset=offset,
                        reading_seconds=seconds if isinstance(seconds, int) and not isinstance(seconds, bool) and seconds >= 0 else None)
        data = data.get("book", data.get("data", data.get("result")))
    raise ProbeError("time_position: missing or invalid position fields")


def coverage_preview(path, key, rows):
    """Read a sibling coverage journal; this is a snapshot, never a dispatch lock."""
    total = sum(row[3] for row in rows)
    report = dict(coverage_checked=False, eligible_seconds=0, online_covered_seconds=0,
                  coverage_unverified_seconds=total)
    if not path.exists():
        return report
    connection = None
    try:
        connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.2)
        connection.execute("PRAGMA query_only=ON")
        record = connection.execute("SELECT value FROM coverage_meta WHERE name='tracked_since'").fetchone()
        if not record or not isinstance(record[0], int) or not 1 <= record[0] <= 4102444800:
            raise ValueError("invalid tracking boundary")
        since = record[0]
        first = min((row[2] for row in rows), default=since)
        last = max((row[2] + row[3] for row in rows), default=since)
        ranges = connection.execute("""SELECT start_time,end_time FROM coverage
            WHERE (scope=? OR scope='') AND start_time<? AND end_time>? ORDER BY start_time LIMIT 50001""",
                                    (key, last, first)).fetchall()
        if len(ranges) > 50000 or any(not isinstance(start, int) or not isinstance(end, int)
                                     or not 1 <= start < end <= 4102444800 for start, end in ranges):
            raise ValueError("invalid coverage intervals")
    except (OSError, sqlite3.Error, ValueError):
        raise ProbeError("coverage_preview: unavailable or incompatible journal") from None
    finally:
        if connection is not None:
            connection.close()
    report.update(coverage_checked=True, coverage_unverified_seconds=0)
    for row in rows:
        start, end = row[2], row[2] + row[3]
        at = start
        for first, last in ranges:
            if first >= end or last <= at:
                continue
            gap = max(0, min(first, end) - at)
            unknown = max(0, min(at + gap, since) - at)
            report["coverage_unverified_seconds"] += unknown
            report["eligible_seconds"] += gap - unknown
            at += gap
            covered = min(last, end) - at
            report["online_covered_seconds"] += covered
            at += covered
        unknown = max(0, min(end, since) - at)
        report["coverage_unverified_seconds"] += unknown
        report["eligible_seconds"] += end - at - unknown
    return report


def ledger_preview(path, vid, book_id, now, limit_seconds=600):
    """Inspect rows without claiming, deleting, acknowledging or replaying them."""
    key = hashlib.sha256(("weread-library:" + str(vid)).encode()).hexdigest()[:20]
    try:
        path = Path(path).resolve()
    except (OSError, RuntimeError):
        raise ProbeError("ledger_preview: unavailable or incompatible ledger") from None
    if path.name != f"offline-time-{key}.db":
        raise ProbeError("ledger_preview: account binding does not match")
    connection = None
    try:
        connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.2)
        connection.execute("PRAGMA query_only=ON")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(windows)")}
        provenance = "w.file_id,w.version_source" if {"file_id", "version_source"} <= columns else "'','legacy_unverified'"
        rows = connection.execute("""SELECT s.id,w.book_id,s.start_time,s.duration,w.time_zone,w.book_version,""" + provenance + """
            FROM segments s JOIN windows w ON w.id=s.window_id
            WHERE s.state='pending' AND w.book_id=? ORDER BY s.id LIMIT 101""", (book_id,)).fetchall()
        unknown = connection.execute("SELECT COALESCE(SUM(duration),0) FROM segments WHERE state IN ('unknown','in_flight')").fetchone()[0]
    except (OSError, sqlite3.Error):
        raise ProbeError("ledger_preview: unavailable or incompatible ledger") from None
    finally:
        if connection is not None:
            connection.close()
    selected, total, group = [], 0, None
    for row in rows:
        _, _, start, duration, zone, row_version, file_id, origin = row
        if (not isinstance(start, int) or not 1 <= start <= 4102444800
                or not isinstance(duration, int) or not 1 <= duration <= 60
                or not isinstance(zone, str) or not re.fullmatch(r"[+-](?:0\d|1[0-4]):[0-5]\d", zone)
                or not isinstance(row_version, int) or not 0 <= row_version <= 2147483647
                or origin not in {"legacy_unverified", "unavailable", "epub_unknown", "epub_snapshot"}
                or not isinstance(file_id, str) or (file_id and not re.fullmatch(r"[0-9a-f]{64}", file_id))
                or (origin == "epub_snapshot" and (row_version == 0 or not file_id))
                or (origin == "epub_unknown" and (row_version != 0 or not file_id))
                or (origin == "unavailable" and (row_version != 0 or file_id))):
            raise ProbeError("ledger_preview: invalid captured metadata")
        if start + duration > now:
            raise ProbeError("ledger_preview: captured time is still ahead of device clock")
        row_group = (row_version, file_id, origin)
        if group is not None and row_group != group:
            break
        if len(selected) >= 100 or total + duration > limit_seconds:
            break
        group = row_group
        selected.append(row)
        total += duration
    end = 0
    for row in sorted(selected, key=lambda item: (item[2], item[0])):
        if row[2] < end:
            raise ProbeError("ledger_preview: overlapping captured intervals")
        end = row[2] + row[3]
    bound = sum(row[3] for row in selected if row[7] == "epub_snapshot" and row[6] and row[5] > 0)
    return dict(rows=len(selected), seconds=total, nonzero_book_version=bool(group and group[0]),
                file_bound_seconds=bound, unverified_source_seconds=total-bound,
                has_more=len(rows) > len(selected), uncertain_seconds=unknown,
                **coverage_preview(path.with_name("reading-time-coverage.db"), key, selected))


class ReadtimeProbe(NativeProbe):
    def __init__(self, opener=None):
        super().__init__(opener)
        self.report.update(probe="native_offline_time_read_only", authenticated=False, time_uploads_attempted=0)

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        if body is not None and url != BASE + "/login":
            raise ProbeError("read-only preflight: data writes are not supported")
        return super().request(stage, url, body, credentials, timeout)

    def preflight(self, credentials=None, shelf=None, requested_book=None, ledger=None):
        self.report["authenticated"] = credentials is not None
        values, authentication_required = {}, False
        unexpected_failure = False
        for stage, path in (("time_config", "/config?token=1"), ("time_feature", "/feature?synckey=0")):
            try:
                values[stage] = self.request(stage, BASE + path, credentials=credentials)
            except ProbeError as exc:
                last = self.report["stages"][-1]
                last["reason"] = str(exc)
                if last.get("status") in (401, 403) and credentials is None:
                    authentication_required = True
                else:
                    unexpected_failure = True
        config, feature = values.get("time_config"), values.get("time_feature")
        config_ready = isinstance(config, dict) and isinstance(config.get("token"), str) and bool(config["token"])
        feature_ready = isinstance(feature, dict) and isinstance(feature.get("feature"), dict)
        self.report["config_token_present"] = config_ready
        self.report["feature_contract_present"] = feature_ready
        if feature_ready:
            token = feature["feature"].get("guest_token")
            if token is None or token == "":
                self.report["signature_token_source"] = "client_default"
            elif isinstance(token, str):
                self.report["signature_token_source"] = "remote"
            else:
                raise ProbeError("time_feature: invalid signature token type")
        self.report["pending"] = ["time_only_payload_and_write_readback", "web_offline_overlap_coordination",
                                  "file_bound_book_version_validation"]
        if not feature_ready:
            self.report["pending"].append("feature_contract_validation")
        if config is not None and not config_ready:
            self.report["pending"].append("config_contract_validation")
        if authentication_required or credentials is None:
            self.report["pending"][:0] = ["owner_scan_and_native_authorization", "authenticated_config_and_position"]
        elif config_ready and feature_ready:
            book_id = select_book(shelf or {}, requested_book)
            position = validate_position(self.request("time_position", BASE + "/book/getProgress?" + urlencode(dict(bookId=book_id)),
                                                      credentials=credentials), book_id)
            self.report["position_contract_present"] = True
            self.report["reading_seconds_present"] = position["reading_seconds"] is not None
            if ledger:
                self.report["ledger_preview"] = ledger_preview(ledger, credentials["vid"], book_id, int(time.time()))
                if self.report["ledger_preview"]["uncertain_seconds"]:
                    self.report["pending"].append("uncertain_attempt_review")
            else:
                self.report["pending"].append("device_ledger_preview")
        else:
            unexpected_failure = True
        self.report["read_only_preflight_complete"] = bool(credentials and config_ready and feature_ready
                                                          and self.report.get("position_contract_present"))
        self.report["result"] = "UNVERIFIED" if unexpected_failure else "PARTIAL"
        return self.report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interactive", action="store_true", help="log in by local QR, then make read-only checks")
    parser.add_argument("--book-id", help="select this ordinary book from the authorized shelf")
    parser.add_argument("--ledger", type=Path, help="inspect the matching account ledger in read-only mode")
    parser.add_argument("--output", type=Path, help="create a metadata-only report")
    args = parser.parse_args()
    if (args.book_id or args.ledger) and not args.interactive:
        parser.error("book/ledger inspection requires --interactive account binding")
    if args.interactive:
        try:
            import qrcode
        except ImportError:
            parser.error("interactive mode requires the local qrcode package")
    probe = ReadtimeProbe()
    try:
        credentials, shelf = None, None
        if args.interactive:
            uid = probe.create_qr()
            with tempfile.TemporaryDirectory(prefix="weread-time-qr-") as root:
                path = Path(root) / "scan.png"
                qrcode.make("https://open.weixin.qq.com/connect/confirm?" + urlencode(dict(uuid=uid))).save(path)
                path.chmod(0o600)
                if not webbrowser.open(path.as_uri()):
                    raise ProbeError("could not open local QR image")
                print("Scan the local QR. Only login and read-only checks run; nothing will be uploaded.", flush=True)
                credentials, shelf = probe.finish(probe.wait_for_code(uid))
        probe.preflight(credentials, shelf, args.book_id, args.ledger)
    except ProbeError as exc:
        probe.report.update(result="UNVERIFIED", reason=str(exc))
    text = json.dumps(probe.report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as out:
            out.write(text)
    print(text, end="")
    raise SystemExit(1 if probe.report["result"] == "UNVERIFIED" else 0)


if __name__ == "__main__":
    main()
