#!/usr/bin/env python3
"""Prototype native shelf writes before a Lua implementation.

Default: no network and no writes. --interactive previews one selected book
using a fresh owner QR. Applying additionally requires --apply and an exact
--confirm-book-id match. The assistant must obtain authorization for that
specific cloud change before invoking apply. A possibly sent POST is never
replayed, and no automatic rollback is attempted. Credentials stay in memory.
--roundtrip explicitly selects an add/readback/remove/readback test; it stops
if the target was already present, either receipt is unknown, or members change.

Reference: MiuRead c1893562aa25a870b8dd076d7be062a3348f823e,
miuread/eink_client.lua (AGPL-3.0-only, MiuRead contributors).
"""
import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import urlencode, urlsplit
import webbrowser

from verify_eink_login import BASE, NativeProbe, ProbeError
from verify_eink_renewal import book_id, validate_credentials

OPERATIONS = {
    "add": ("/shelf/add", True), "remove": ("/shelf/delete", False),
    "finish": ("/book/markstatus", True), "unfinish": ("/book/markstatus", False),
}


def writable_id(value):
    return (isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,256}", value) is not None
            and value != "0" and not value.startswith("MP_"))


def snapshot(data):
    if not isinstance(data, dict) or not isinstance(data.get("books"), list):
        raise ProbeError("shelf: incomplete snapshot")
    rows = {}
    for row in data["books"]:
        identity = book_id(row.get("bookId")) if isinstance(row, dict) else None
        if not identity or identity in rows:
            raise ProbeError("shelf: invalid or duplicate book")
        rows[identity] = row
    return rows


def state(rows, identity, operation):
    if operation in ("add", "remove"):
        return identity in rows
    row = rows.get(identity)
    if row is None:
        raise ProbeError("status: selected book is not on shelf")
    flags = [row[key] for key in ("finishReading", "finished") if key in row]
    if not flags or any(type(flag) not in (int, bool) or flag not in (0, 1) for flag in flags):
        raise ProbeError("status: unknown reading status")
    if len(set(flags)) != 1:
        raise ProbeError("status: conflicting reading flags")
    return bool(flags[0])


@dataclass(frozen=True)
class Plan:
    owner: str
    identity: str
    operation: str
    before: bool
    members: tuple

    @property
    def desired(self):
        return OPERATIONS[self.operation][1]

    def request(self):
        path = OPERATIONS[self.operation][0]
        if self.operation in ("add", "remove"):
            return path, dict(bookIds=[self.identity])
        return path, dict(bookId=self.identity, auto=0, finishInfo=0,
                          isCancel=0 if self.desired else 1, status=4)


class ShelfWriteProbe(NativeProbe):
    def __init__(self, opener=None, sleep=time.sleep):
        super().__init__(opener)
        self.sleep, self.plan, self.dispatch = sleep, None, None
        self.report.update(probe="native_shelf_write", data_writes_attempted=0, readback_attempts=0)

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        try:
            parsed = urlsplit(url)
            origin_ok = (parsed.scheme == "https" and not parsed.username and not parsed.password
                         and parsed.port in (None, 443) and not parsed.fragment)
        except ValueError:
            raise ProbeError("request: invalid endpoint") from None
        gets = {("i.weread.qq.com", "/wxticket"), ("i.weread.qq.com", "/shelf/sync"),
                ("open.weixin.qq.com", "/connect/sdk/qrconnect"), ("long.open.weixin.qq.com", "/connect/l/qrconnect")}
        allowed = (body is None and (parsed.hostname, parsed.path) in gets) or (
            body is not None and parsed.hostname == "i.weread.qq.com" and not parsed.query
            and (parsed.path == "/login" or self.dispatch == (parsed.path, body)))
        if not origin_ok or not allowed:
            raise ProbeError("request: unconfirmed or unrelated operation blocked")
        return super().request(stage, url, body, credentials, timeout)

    def prepare(self, credentials, operation, identity):
        validate_credentials(credentials)
        if operation not in OPERATIONS or not writable_id(identity):
            raise ProbeError("preview: invalid operation or book")
        self.plan = None
        rows = snapshot(self.request("shelf_preview", BASE + "/shelf/sync", credentials=credentials))
        before = state(rows, identity, operation)
        self.plan = Plan(credentials["vid"], identity, operation, before, tuple(sorted(rows)))
        self.report.update(operation=operation, target_supplied=True, before=before,
                           desired=self.plan.desired, shelf_before_count=len(rows), result="PREVIEW_ONLY")
        return self.plan

    def apply(self, credentials, plan, *, confirmed=False):
        validate_credentials(credentials)
        if confirmed is not True or plan is not self.plan or not isinstance(plan, Plan) or plan.owner != credentials["vid"]:
            raise ProbeError("apply: current owner and exact preview confirmation required")
        rows = snapshot(self.request("shelf_preflight", BASE + "/shelf/sync", credentials=credentials))
        current = state(rows, plan.identity, plan.operation)
        if current == plan.desired:
            self.plan = None
            self.report.update(result="NOOP", desired_state_observed=True)
            return
        if current != plan.before or tuple(sorted(rows)) != plan.members:
            raise ProbeError("apply: shelf changed after preview")
        path, body = plan.request()
        self.plan, self.dispatch = None, (path, body)
        self.report["data_writes_attempted"] += 1
        accepted = False
        try:
            response = self.request("shelf_write", BASE + path, body=body, credentials=credentials)
            accepted = response.get("succ") in (True, 1) or response.get("success") is True
            self.report["receipt_received"] = True
        except ProbeError:
            self.report["receipt_received"] = any(
                stage.get("stage") == "shelf_write" and "status" in stage for stage in self.report["stages"])
        finally:
            self.dispatch = None
        expected_members = set(plan.members)
        if plan.operation == "add":
            expected_members.add(plan.identity)
        elif plan.operation == "remove":
            expected_members.remove(plan.identity)
        observed, unrelated_changes = False, False
        for attempt in range(3):
            if attempt:
                self.sleep(0.5 * attempt)
            self.report["readback_attempts"] += 1
            try:
                after = snapshot(self.request("shelf_readback", BASE + "/shelf/sync", credentials=credentials))
                observed = state(after, plan.identity, plan.operation) == plan.desired
                unrelated_changes = set(after) != expected_members
                self.report["shelf_after_count"] = len(after)
                if observed:
                    break
            except ProbeError:
                continue
        verified = accepted and observed and not unrelated_changes
        self.report.update(result="PASS" if verified else "PARTIAL" if observed else "UNVERIFIED",
                           acknowledgement_recognized=accepted, desired_state_observed=observed,
                           unrelated_membership_changes=unrelated_changes, write_verified=verified)

    def apply_roundtrip(self, credentials, plan, *, confirmed=False):
        """Two explicitly authorized operations; never remove a pre-existing book."""
        validate_credentials(credentials)
        if (confirmed is not True or plan is not self.plan or not isinstance(plan, Plan)
                or plan.operation != "add" or plan.owner != credentials["vid"]):
            raise ProbeError("roundtrip: exact add preview and both-operation confirmation required")
        self.report.update(roundtrip=True, roundtrip_verified=False, operations=[])
        if plan.before:
            self.plan = None
            self.report.update(result="NOOP", target_already_present=True)
            return

        def remember(operation):
            self.report["operations"].append(dict(operation=operation, **{
                key: self.report.get(key) for key in ("result", "acknowledgement_recognized",
                                                     "desired_state_observed", "write_verified")}))

        self.apply(credentials, plan, confirmed=True)
        remember("add")
        # A concurrent add is NOOP; an uncertain receipt is PARTIAL. Neither
        # proves that our add succeeded, so neither authorizes the second step.
        if self.report["result"] != "PASS":
            return
        self.report["result"] = "PARTIAL"
        removal = self.prepare(credentials, "remove", plan.identity)
        if not removal.before or set(removal.members) != set(plan.members) | {plan.identity}:
            self.plan = None
            raise ProbeError("roundtrip: shelf changed after verified addition")
        self.apply(credentials, removal, confirmed=True)
        remember("remove")
        self.report["roundtrip_verified"] = self.report["result"] == "PASS"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interactive", action="store_true", help="fresh owner QR and read-only operation preview")
    parser.add_argument("--operation", choices=tuple(OPERATIONS))
    parser.add_argument("--book-id", help="one explicitly selected ordinary WeRead book")
    parser.add_argument("--apply", action="store_true", help="apply the specifically authorized operation once")
    parser.add_argument("--roundtrip", action="store_true", help="explicit add/readback/remove/readback test; requires operation add")
    parser.add_argument("--confirm-book-id", help="must exactly match --book-id when applying")
    parser.add_argument("--output", type=Path, help="new metadata-only report; no IDs, titles or credentials")
    args = parser.parse_args()
    if args.interactive and (not args.operation or not writable_id(args.book_id)):
        parser.error("interactive preview needs --operation and an ordinary --book-id")
    if args.apply and (not args.interactive or not args.book_id or args.confirm_book_id != args.book_id):
        parser.error("apply needs interactive mode and an exact --confirm-book-id match")
    if args.roundtrip and (not args.interactive or args.operation != "add"):
        parser.error("roundtrip needs an interactive add preview")
    if args.output and args.output.exists():
        parser.error("output already exists")
    probe = ShelfWriteProbe()
    credentials = shelf = None
    try:
        if not args.interactive:
            probe.report.update(result="PENDING_TARGET_AND_OWNER", network_requests=0,
                                pending=["selected_test_book", "owner_scan", "specific_write_authorization", "write_and_readback"])
        else:
            try:
                import qrcode
            except ImportError:
                parser.error("interactive mode needs the optional qrcode package")
            with tempfile.TemporaryDirectory(prefix="weread-shelf-qr-") as directory:
                uid = probe.create_qr()
                image = Path(directory) / "scan.png"
                qrcode.make("https://open.weixin.qq.com/connect/confirm?" + urlencode(dict(uuid=uid))).save(image)
                image.chmod(0o600)
                if not webbrowser.open(image.as_uri()):
                    raise ProbeError("qr: could not show local image")
                print("请扫码确认所选书籍的操作；未指定 --apply 时只生成预览。凭据不保存。", flush=True)
                credentials, shelf = probe.finish(probe.wait_for_code(uid))
                plan = probe.prepare(credentials, args.operation, args.book_id)
                if args.roundtrip:
                    probe.report.update(roundtrip=True, target_already_present=plan.before)
                if args.apply:
                    if args.roundtrip:
                        probe.apply_roundtrip(credentials, plan, confirmed=True)
                    else:
                        probe.apply(credentials, plan, confirmed=True)
    except ProbeError as exc:
        probe.report.update(result="UNVERIFIED", reason=str(exc))
    except KeyboardInterrupt:
        probe.report.update(result="UNCONFIRMED_AFTER_DISPATCH" if probe.report["data_writes_attempted"] else "CANCELLED")
    finally:
        credentials = shelf = None
        probe.plan = probe.dispatch = None
    text = json.dumps(probe.report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as file:
            file.write(text)
    print(text, end="")
    raise SystemExit(0 if probe.report["result"] in ("PASS", "NOOP", "PREVIEW_ONLY", "PENDING_TARGET_AND_OWNER") else 1)


if __name__ == "__main__":
    main()
