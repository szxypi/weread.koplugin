#!/usr/bin/env python3
"""Owner-present native token-renewal probe, before a Lua implementation.

Without --interactive: no network, no QR, no credential files. Interactive:
fresh owner QR -> login/shelf -> one renewal -> renewed shelf. Only /login
POSTs and known authorization/shelf GETs are allowed. All tokens stay in
memory; reports contain counts, field names and booleans only.

Renewal reference: MiuRead c1893562aa25a870b8dd076d7be062a3348f823e,
miuread/shelf_client.lua (AGPL-3.0-only, MiuRead contributors).
"""
import argparse
import json
import math
from pathlib import Path
import re
import tempfile
from urllib.parse import urlencode, urlsplit
import webbrowser

from verify_eink_login import BASE, NativeProbe, ProbeError


def safe_text(value, maximum):
    try:
        return (isinstance(value, str) and len(value.encode("utf-8")) <= maximum
                and not re.search(r"[\x00-\x1f\x7f]", value))
    except UnicodeError:
        return False


def book_id(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if ((isinstance(value, float) and not math.isfinite(value))
                or not 1 <= value <= 9007199254740990 or int(value) != value):
            return None
        value = str(int(value))
    return value if safe_text(value, 256) and value else None


def shelf_contract(shelf):
    """Mirror the plugin's native display contract; never retain values."""
    if not isinstance(shelf, dict) or not isinstance(shelf.get("books"), list):
        raise ProbeError("shelf_contract: missing full shelf")
    seen, invalid, invalid_archives = set(), 0, 0
    present = {key: 0 for key in ("author", "cover", "readUpdateTime", "version", "finishReading", "finished", "secret", "format")}
    for book in shelf["books"]:
        if not isinstance(book, dict):
            invalid += 1
            continue
        identity = book_id(book.get("bookId"))
        if not identity or identity in seen or not safe_text(book.get("title"), 4096):
            invalid += 1
        seen.add(identity)
        for key in present:
            present[key] += int(key in book)
    archives = shelf.get("archive", [])
    if not isinstance(archives, list):
        invalid_archives += 1
    else:
        for archive in archives:
            if (not isinstance(archive, dict) or not isinstance(archive.get("bookIds"), list)
                    or any(book_id(value) is None for value in archive["bookIds"])):
                invalid_archives += 1
    return dict(books=len(shelf["books"]), invalid_books=invalid, invalid_archives=invalid_archives,
                display_contract_valid=invalid == 0 and invalid_archives == 0, fields_present=present,
                version_semantics="unverified")


def validate_credentials(credentials):
    if not isinstance(credentials, dict):
        raise ProbeError("renewal: incomplete private credentials")
    vid = credentials.get("vid")
    if (not isinstance(vid, str) or re.fullmatch(r"[1-9][0-9]{0,31}", vid) is None
            or any(not safe_text(credentials.get(key), 8192) or not credentials[key]
                   for key in ("accessToken", "refreshToken"))
            or not safe_text(credentials.get("deviceId"), 32) or len(credentials["deviceId"]) != 32):
        raise ProbeError("renewal: incomplete private credentials")


class RenewalProbe(NativeProbe):
    def __init__(self, opener=None):
        super().__init__(opener)
        self.report.update(probe="native_renewal", renewal_attempts=0, data_writes_attempted=0)

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        try:
            parsed = urlsplit(url)
            port = parsed.port
        except ValueError:
            raise ProbeError("request: invalid authorization URL") from None
        allowed_get = {
            ("i.weread.qq.com", "/wxticket"), ("i.weread.qq.com", "/shelf/sync"),
            ("open.weixin.qq.com", "/connect/sdk/qrconnect"), ("long.open.weixin.qq.com", "/connect/l/qrconnect"),
        }
        allowed = (parsed.scheme == "https" and not parsed.username and not parsed.password
                   and port in (None, 443) and not parsed.fragment
                   and ((body is None and (parsed.hostname, parsed.path) in allowed_get)
                        or (isinstance(body, dict) and parsed.hostname == "i.weread.qq.com"
                            and parsed.path == "/login" and not parsed.query)))
        if not allowed:
            raise ProbeError("request: outside authorization/read-only allowlist")
        return super().request(stage, url, body, credentials, timeout)

    def renew(self, previous):
        validate_credentials(previous)
        body = self.login_body(previous["deviceId"])
        body.update(refreshToken=previous["refreshToken"], inBackground=0, kickType=1, refCgi="")
        self.report["renewal_attempts"] += 1
        # No retries: a lost receipt may have consumed a rotating refresh token.
        data = self.request("renewal", BASE + "/login", body=body)
        vid = str(data.get("vid", ""))
        if vid != previous["vid"]:
            raise ProbeError("renewal: missing or mismatched owner")
        renewed = dict(accessToken=data.get("accessToken"), refreshToken=data.get("refreshToken", previous["refreshToken"]))
        renewed.update(vid=vid, deviceId=previous["deviceId"])
        validate_credentials(renewed)
        shelf = self.request("renewed_shelf", BASE + "/shelf/sync", credentials=renewed)
        contract = shelf_contract(shelf)
        if not contract["display_contract_valid"]:
            raise ProbeError("renewed_shelf: incompatible display snapshot")
        self.report.update(renewal_verified=True, owner_unchanged=True, device_reused=True,
                           access_token_changed=renewed["accessToken"] != previous["accessToken"],
                           refresh_token_returned="refreshToken" in data,
                           refresh_token_changed=renewed["refreshToken"] != previous["refreshToken"],
                           renewed_shelf_contract=contract)
        self.report.setdefault("verified_renewals", []).append(dict(
            owner_unchanged=True, device_reused=True, refresh_token_returned="refreshToken" in data,
            refresh_token_changed=renewed["refreshToken"] != previous["refreshToken"], books=contract["books"]))
        return renewed, shelf


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interactive", action="store_true", help="fresh owner QR, renewal and read-only shelf verification")
    parser.add_argument("--output", type=Path, help="create a metadata-only report; never a credential file")
    parser.add_argument("--rounds", type=int, choices=(1, 2), default=1, help="verify one renewal or a two-renewal credential chain")
    args = parser.parse_args()
    if args.output and args.output.exists():
        parser.error("output already exists")
    probe = RenewalProbe()
    credentials = shelf = None
    try:
        if not args.interactive:
            probe.report.update(result="PENDING_OWNER_SCAN", pending=["owner_scan", "renewal", "renewed_shelf"],
                                network_requests=0)
        else:
            try:
                import qrcode
            except ImportError:
                parser.error("interactive mode needs the optional qrcode package in a local Python environment")
            with tempfile.TemporaryDirectory(prefix="weread-renewal-qr-") as directory:
                uid = probe.create_qr()
                image = Path(directory) / "scan.png"
                qrcode.make("https://open.weixin.qq.com/connect/confirm?" + urlencode(dict(uuid=uid))).save(image)
                image.chmod(0o600)
                if not webbrowser.open(image.as_uri()):
                    raise ProbeError("qr: could not show local image")
                print("请用本人微信扫码并确认；仅验证授权续期和读取书架，凭据不保存。", flush=True)
                credentials, shelf = probe.finish(probe.wait_for_code(uid))
                probe.report["initial_shelf_contract"] = shelf_contract(shelf)
                if not probe.report["initial_shelf_contract"]["display_contract_valid"]:
                    raise ProbeError("initial_shelf: incompatible display snapshot")
                for _index in range(args.rounds):
                    credentials, shelf = probe.renew(credentials)
                probe.report["renewal_chain_verified"] = args.rounds == 2
            probe.report["result"] = "PASS"
    except ProbeError as exc:
        probe.report.update(result="UNVERIFIED", reason=str(exc))
    except KeyboardInterrupt:
        probe.report.update(result="CANCELLED")
    finally:
        credentials = shelf = None
    text = json.dumps(probe.report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as file:
            file.write(text)
    print(text, end="")
    raise SystemExit(0 if probe.report["result"] in ("PASS", "PENDING_OWNER_SCAN") else 1)


if __name__ == "__main__":
    main()
