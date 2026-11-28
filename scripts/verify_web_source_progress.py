#!/usr/bin/env python3
"""Compare cloud/Web positions with original chapter text, without account writes.

Default: offline checks, no network. --interactive --book-id ID opens a fresh
Web-login QR and reads that book only. --save-session explicitly opts into
project-scoped macOS Keychain storage; --saved-session rechecks that account
before reuse. --clear-saved-session deletes the item when the goal is complete.
Source text always stays in memory; no credentials file is created.
Only the existing catalog/content POST reads are permitted; progress, time,
shelf, renewal and annotation writes are absent. Reports omit account/book
identifiers, positions, cookies, source text, signing data and login URLs.
This is a preflight, not proof of wire coordinate or version semantics.
"""
import argparse
from datetime import datetime, timezone
import getpass
from http.cookiejar import Cookie, CookieJar
import json
import math
from pathlib import Path
import re
import secrets
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlencode, urlsplit
from urllib.request import HTTPCookieProcessor, Request, build_opener
import webbrowser

from fetch_weread_epub import (USER_AGENT, decode_content_shards, make_content_params,
                               normalize_chapter_infos, read_reader_state, reader_url_for, weread_e)
from verify_source_coordinates import CoordinateError, FilteredSource, NoRedirect
from secure_weread_session import SessionStore, StoreError

BASE = "https://weread.qq.com"
MAX_RESPONSE = 4 * 1024 * 1024
VERSION_FIELDS = ("bookVersion", "version", "contentVersion")


class PreflightError(RuntimeError):
    """Only fixed, non-sensitive reasons cross the diagnostic boundary."""


class PollTimeout(PreflightError):
    pass


def identifier(value):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise PreflightError("identity_invalid")
    value = str(value)
    if not re.fullmatch(r"[1-9][0-9]{0,19}", value):
        raise PreflightError("identity_invalid")
    return value


def position(data, book_id):
    for _i in range(4):
        if not isinstance(data, dict):
            break
        returned = data.get("bookId", data.get("book_id"))
        if returned is not None and str(returned) != book_id:
            raise PreflightError("position_book_mismatch")
        if "chapterUid" in data or "chapterOffset" in data:
            if (type(data.get("chapterUid")) in (int, str) and str(data["chapterUid"]) == "0"
                    and type(data.get("chapterOffset")) is int and data["chapterOffset"] == 0
                    and type(data.get("progress")) in (int, float) and data["progress"] == 0):
                raise PreflightError("position_has_no_chapter")
            uid, offset = identifier(data.get("chapterUid")), data.get("chapterOffset")
            if type(offset) is not int or not 0 <= offset <= 2**31 - 1:
                raise PreflightError("position_offset_invalid")
            percent = data.get("progress")
            if isinstance(percent, bool) or not isinstance(percent, (int, float)) or not math.isfinite(percent) or not 0 <= percent <= 100:
                raise PreflightError("position_percent_invalid")
            return dict(chapter=uid, offset=offset, percent=percent)
        data = data.get("book", data.get("data", data.get("result")))
    raise PreflightError("position_missing")


def versions(record):
    """Private bounded observations. Presence/equality alone do not prove meaning."""
    result = {}
    for prefix, node in (("record", record), ("book", record.get("book", {}))):
        if not isinstance(node, dict):
            continue
        for key in VERSION_FIELDS:
            value = node.get(key)
            if type(value) is int and 0 <= value < 2**63:
                result[prefix + "." + key] = value
            elif isinstance(value, str) and re.fullmatch(r"[0-9]{1,19}", value):
                result[prefix + "." + key] = int(value)
    return result


def source_check(raw, remote):
    model = FilteredSource(raw)
    resolved = False
    try:
        anchor = model.anchor_at(remote["offset"])
        resolved = model.locate(anchor)[0] == remote["offset"]
    except CoordinateError:
        pass  # Zero, whitespace, tags or ambiguity must never be snapped forward.
    return dict(source_utf16_units=model.offsets[-1], visible_characters=len(model.characters),
                offset_resolves_to_unique_visible_text=resolved,
                server_coordinate_semantics_verified=False)


class WebSourceProbe:
    def __init__(self, opener=None, official_parser=False):
        self.cookies = CookieJar()
        self.opener = opener or build_opener(NoRedirect(), HTTPCookieProcessor(self.cookies))
        self.vid, self.book_id, self.chapter = None, None, None
        self.authenticated = False
        self.official_parser = official_parser
        self.lua_command = None
        self.report = dict(result="OFFLINE_ONLY", checked_at=datetime.now(timezone.utc).isoformat(),
                           stages=[], account_writes_attempted=0, precision_wire_sync_enabled=False,
                           version_semantics_verified=False)

    def set_cookie(self, name, value):
        if name not in {"wr_fp", "wr_vid", "wr_skey", "wr_rt", "wr_ql", "wr_pf"} or not isinstance(value, str) or not value or len(value) > 4096:
            raise PreflightError("credential_invalid")
        if any(ord(char) < 33 or ord(char) > 126 or char in ';"\\' for char in value):
            raise PreflightError("credential_invalid")
        for old in list(self.cookies):
            if old.name == name:
                self.cookies.clear(old.domain, old.path, old.name)
        self.cookies.set_cookie(Cookie(0, name, value, None, False, ".weread.qq.com", True, True,
                                       "/", True, True, None, True, None, None, {}, False))

    def guard(self, stage, url, body):
        u = urlsplit(url)
        if u.scheme != "https" or u.netloc != "weread.qq.com" or u.fragment or u.username:
            raise PreflightError("request_outside_scope")
        query = parse_qs(u.query, keep_blank_values=True)
        if body is None:
            simple = {"auth_page": "/r/weread-skills", "auth_uid": "/api/auth/getLoginUid"}
            if stage in simple and u.path == simple[stage] and not u.query:
                return
            if stage == "auth_poll" and u.path == "/api/auth/getLoginInfo" and set(query) == {"uid", "otp"}:
                if len(query["uid"]) == len(query["otp"]) == 1 and re.fullmatch(r"[A-Za-z0-9_-]{1,256}", query["uid"][0]) and re.fullmatch(r"(?:[0-9]{4})?", query["otp"][0]):
                    return
            if stage == "account" and u.path == "/api/userInfo" and query == {"userVid": [self.vid]} and self.vid:
                return
            if self.authenticated and stage == "shelf" and url == BASE + "/web/shelf/sync":
                return
            if self.authenticated and self.book_id:
                if stage in {"progress_before", "progress_after", "selection_progress"} and u.path == "/web/book/getProgress" and query == {"bookId": [self.book_id]}:
                    return
                if stage == "reader" and url == reader_url_for(self.book_id, self.chapter):
                    return
        elif self.authenticated and self.book_id and not u.query:
            if stage in {"catalog_before", "catalog_after"} and u.path == "/web/book/chapterInfos" and body == {"bookIds": [self.book_id]}:
                return
            if stage in {"e_0", "e_1", "e_3"} and u.path == "/web/book/chapter/" + stage and self.chapter and isinstance(body, dict):
                required = {"b", "c", "r", "ct", "ps", "pc", "sc", "prevChapter", "st", "s"}
                if (set(body) == required and body["b"] == weread_e(self.book_id) and body["c"] == weread_e(self.chapter)
                        and type(body["sc"]) is int and body["sc"] == 1 and body["prevChapter"] is False
                        and type(body["st"]) is int and body["st"] == 0 and len(json.dumps(body)) <= 16384):
                    return
        raise PreflightError("request_outside_scope")

    def request(self, stage, url, body=None, *, timeout=20, as_json=True):
        self.guard(stage, url, body)
        record = dict(stage=stage)
        self.report["stages"].append(record)
        headers = {"User-Agent": USER_AGENT, "Origin": BASE, "Referer": BASE + "/r/weread-skills",
                   "Accept": "application/json, text/plain, */*", "Content-Type": "application/json;charset=UTF-8"}
        if self.authenticated and self.book_id:
            headers["Referer"] = reader_url_for(self.book_id, self.chapter)
        if stage == "shelf":
            headers["Referer"] = BASE + "/web/shelf"
        if stage == "account":
            headers["X-Vid"] = self.vid
            headers["X-Skey"] = next((cookie.value for cookie in self.cookies if cookie.name == "wr_skey"), "")
        encoded = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        request = Request(url, data=encoded, headers=headers)
        try:
            with self.opener.open(request, timeout=timeout) as response:
                record["status"] = response.status
                if response.status != 200:
                    raise PreflightError("http_rejected")
                raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise PreflightError("response_too_large")
            text = raw.decode("utf-8")
            if not as_json:
                return text
            data = json.loads(text)
            if not isinstance(data, (dict, list)):
                raise PreflightError("response_invalid")
            if isinstance(data, dict) and data.get("errcode", data.get("errCode", 0)) not in (None, 0):
                api_code=data.get('errcode',data.get('errCode'))
                if type(api_code) is int and -2147483648 <= api_code <= 2147483647:
                    record['api_code']=api_code
                raise PreflightError("api_rejected")
            return data
        except HTTPError as exc:
            record["status"] = exc.code
            exc.close()
            raise PreflightError("http_rejected") from None
        except (TimeoutError, URLError) as exc:
            if isinstance(exc, TimeoutError) or isinstance(getattr(exc, "reason", None), TimeoutError):
                raise PollTimeout("request_timed_out") from None
            raise PreflightError("connection_failed") from None
        except (OSError, ValueError, UnicodeError):
            raise PreflightError("response_or_connection_invalid") from None

    def login(self, show_qr, otp_reader=None, *, seconds=240):
        self.set_cookie("wr_fp", str(secrets.randbits(32)))
        self.request("auth_page", BASE + "/r/weread-skills", as_json=False)
        data = self.request("auth_uid", BASE + "/api/auth/getLoginUid")
        uid = data.get("uid") if isinstance(data, dict) else None
        if not isinstance(uid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", uid):
            raise PreflightError("login_uid_invalid")
        show_qr(BASE + "/web/confirm?" + urlencode(dict(uid=uid)))
        deadline, otp, otp_attempts = time.monotonic() + seconds, "", 0
        while time.monotonic() < deadline:
            try:
                result = self.request("auth_poll", BASE + "/api/auth/getLoginInfo?" + urlencode(dict(uid=uid, otp=otp)), timeout=10)
            except PollTimeout:
                continue
            if not isinstance(result, dict):
                raise PreflightError("login_response_invalid")
            if result.get("succeed") is True:
                break
            code = result.get("logicCode")
            if code in {"NEED_OTP", "OTP_NOT_MATCH"} and otp_reader and otp_attempts < 3:
                otp = otp_reader()
                otp_attempts += 1
                if not isinstance(otp, str) or not re.fullmatch(r"[0-9]{4}", otp):
                    raise PreflightError("otp_invalid")
                continue
            raise PreflightError("login_not_confirmed")
        else:
            raise PreflightError("login_expired")
        self.vid = identifier(result.get("webLoginVid"))
        self.set_cookie("wr_vid", self.vid)
        self.set_cookie("wr_skey", result.get("accessToken"))
        self.set_cookie("wr_ql", "0")
        if result.get("refreshToken"):
            self.set_cookie("wr_rt", quote(result["refreshToken"], safe=""))
        result.clear()
        self.verify_account()

    def verify_account(self):
        self.authenticated = False
        self.report["owner_web_login_verified"] = False
        account = self.request("account", BASE + "/api/userInfo?" + urlencode(dict(userVid=self.vid)))
        returned = account.get("vid", account.get("userVid")) if isinstance(account, dict) else None
        if identifier(returned) != self.vid:
            raise PreflightError("account_mismatch")
        self.authenticated = True
        self.report["owner_web_login_verified"] = True

    def select_shelf_book(self):
        if not self.authenticated:
            raise PreflightError("login_required")
        shelf = self.request("shelf", BASE + "/web/shelf/sync")
        books = shelf.get("books") if isinstance(shelf, dict) else None
        if not isinstance(books, list) or len(books) > 5000:
            raise PreflightError("shelf_invalid")
        self.report["shelf_book_count"] = len(books)
        seen, attempts = set(), 0
        for row in books:
            if not isinstance(row, dict):
                continue
            for _i in range(4):
                nested = row.get("bookInfo", row.get("book"))
                if not isinstance(nested, dict):
                    break
                row = nested
            try:
                book_id = identifier(row.get("bookId"))
            except PreflightError:
                continue
            if book_id in seen:
                continue
            seen.add(book_id)
            if attempts >= 8:
                break
            attempts += 1
            self.book_id = book_id
            data = self.request("selection_progress", BASE + "/web/book/getProgress?" + urlencode(dict(bookId=book_id)))
            try:
                position(data, book_id)
            except PreflightError as exc:
                if str(exc) in {"position_missing", "position_has_no_chapter"}:
                    continue
                raise
            self.report.update(selection_attempts=attempts, existing_read_position_selected=True)
            return book_id
        self.report.update(selection_attempts=attempts, existing_read_position_selected=False)
        raise PreflightError("no_position_in_bounded_shelf_sample")

    def inspect(self, book_id):
        if not self.authenticated:
            raise PreflightError("login_required")
        self.book_id = identifier(book_id)
        progress_url = BASE + "/web/book/getProgress?" + urlencode(dict(bookId=self.book_id))
        before = position(self.request("progress_before", progress_url), self.book_id)
        self.chapter = before["chapter"]
        try:
            state = read_reader_state(self.request("reader", reader_url_for(self.book_id, self.chapter), as_json=False))
            if state.book_id != self.book_id or str(state.current_chapter.get("chapterUid")) != self.chapter or not state.psvts:
                raise PreflightError("reader_source_scope_mismatch")
            embedded = position(state.progress, self.book_id)
            catalog = self.request("catalog_before", BASE + "/web/book/chapterInfos", {"bookIds": [self.book_id]})
            record, chapters = normalize_chapter_infos(catalog, self.book_id)
            matching = [row for row in chapters if str(row.get("chapterUid")) == self.chapter]
            if len(matching) != 1:
                raise PreflightError("catalog_chapter_missing_or_ambiguous")
            params = make_content_params(self.book_id, self.chapter, state.psvts, sc=1)
            source = decode_content_shards(*(self.request(key, BASE + "/web/book/chapter/" + key, params, as_json=False)
                                             for key in ("e_0", "e_1", "e_3")))
            mapping = source_check(source, before)
            word_count = matching[0].get("wordCount")
            mapping["offset_exceeds_catalog_word_count"] = before["offset"] > word_count if type(word_count) is int and word_count >= 0 else None
            if self.official_parser:
                from source_parser_preflight import verify_source
                try:
                    mapping.update(verify_source(source, before["offset"], lua_command=self.lua_command))
                except CoordinateError as exc:
                    self.report["official_parser_coordinate_mismatch"] = str(exc) == "parser: source coordinate mismatch"
                    self.report["official_parser_unavailable"] = str(exc) == "parser: comparison unavailable"
                    self.report["lua_model_unverified"] = str(exc).startswith("lua:")
                    raise PreflightError("official_parser_comparison_unverified") from None
            later, later_chapters = normalize_chapter_infos(self.request("catalog_after", BASE + "/web/book/chapterInfos", {"bookIds": [self.book_id]}), self.book_id)
        except PreflightError:
            raise
        except Exception:
            raise PreflightError("source_context_or_decoding_invalid") from None
        after = position(self.request("progress_after", progress_url), self.book_id)
        old_versions, new_versions = versions(record), versions(later)
        reader_versions = versions(state.initial_state["reader"].get("bookInfo", {}))
        reader_book_versions = {v for k, v in reader_versions.items() if k.endswith(".bookVersion")}
        catalog_book_versions = {v for k, v in old_versions.items() if k.endswith(".bookVersion")}
        comparable = bool(reader_book_versions and catalog_book_versions)
        version_equal = len(reader_book_versions) == len(catalog_book_versions) == 1 and reader_book_versions == catalog_book_versions
        stable_catalog = chapters == later_chapters and old_versions == new_versions
        self.report.update(mapping, cloud_position_stable=before == after, embedded_position_matches=before == embedded,
                           catalog_stable=stable_catalog, version_fields_observed=bool(old_versions),
                           version_field_paths=sorted(old_versions),
                           reader_version_fields_observed=bool(reader_versions), book_version_field_comparable=comparable,
                           book_version_field_equal=version_equal if comparable else None)
        # Even a stable matching offset does not prove server coordinate/version
        # meaning, nor authorize replacing the production wire fields.
        self.report["result"] = "PARTIAL"
        self.report["read_snapshot_consistent"] = bool(before == after == embedded and stable_catalog and (not comparable or version_equal)
                                                       and mapping.get("official_parser_target_present", True))
        self.report["pending"] = ["server_coordinate_and_version_semantics", "authorized_precise_write_readback", "multi_device_and_hardware"]
        return self.report

    def close(self):
        self.cookies.clear()
        self.vid, self.book_id, self.chapter, self.authenticated = None, None, None, False


def offline_check():
    raw = "<html><body><p>这是一段足够长且只出现一次的离线位置核对正文。</p></body></html>"
    model = FilteredSource(raw)
    return source_check(raw, {"offset": model.starts[0]})["offset_resolves_to_unique_visible_text"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--interactive", action="store_true", help="fresh Web QR login followed by read-only comparison")
    mode.add_argument("--saved-session", action="store_true", help="reuse owner-approved Keychain session after account verification")
    mode.add_argument("--clear-saved-session", action="store_true", help="delete only this project's Keychain item; no network")
    parser.add_argument("--save-session", action="store_true", help="explicitly save the new verified login in macOS Keychain until goal completion")
    parser.add_argument("--official-parser", action="store_true", help="compare in a fresh anonymous browser, offline before private text is supplied")
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--book-id", help="explicit ordinary book to inspect; never added to the shelf")
    target.add_argument("--select-shelf-book", action="store_true", help="read Web shelf and try at most eight existing books for a stored position")
    parser.add_argument("--output", type=Path, help="new metadata-only report")
    parser.add_argument("--lua-command", nargs=argparse.REMAINDER, help="optional local Lua probe; private source passes only through its memory pipes; put last")
    args = parser.parse_args(argv)
    if bool(args.interactive or args.saved_session) != bool(args.book_id or args.select_shelf_book):
        parser.error("a login mode and one book-selection mode must be used together")
    if args.save_session and not args.interactive:
        parser.error("--save-session requires --interactive")
    if args.official_parser and not (args.interactive or args.saved_session):
        parser.error("--official-parser requires a login mode")
    if args.lua_command is not None and (not args.official_parser or not args.lua_command):
        parser.error("--lua-command requires --official-parser and a local probe command")
    if args.output and args.output.exists():
        parser.error("report already exists")
    if args.book_id:
        try:
            identifier(args.book_id)
        except PreflightError:
            parser.error("invalid ordinary book ID")
    probe = WebSourceProbe()
    probe.official_parser = args.official_parser
    probe.lua_command = args.lua_command
    try:
        probe.report["offline_model_check"] = offline_check()
        if args.interactive:
            try:
                import qrcode
            except ImportError:
                raise PreflightError("local_qrcode_dependency_missing") from None
            with tempfile.TemporaryDirectory(prefix="weread-source-qr-") as root:
                qr_path = Path(root) / "scan.png"
                def show_qr(url):
                    qrcode.make(url).save(qr_path)
                    qr_path.chmod(0o600)
                    if not webbrowser.open(qr_path.as_uri()):
                        raise PreflightError("local_qr_open_failed")
                    storage = "verified credentials will be saved to macOS Keychain" if args.save_session else "credentials remain in memory"
                    print("QR_READY: scan the local image; " + storage + "; source remains in memory.", flush=True)
                probe.login(show_qr, lambda: getpass.getpass("OTP_REQUIRED: four-digit code (hidden): ").strip())
                if args.save_session:
                    SessionStore().save(probe)
                    probe.report.update(credentials_saved=True, credential_store="macos_keychain")
                probe.inspect(args.book_id or probe.select_shelf_book())
        elif args.saved_session:
            saved = SessionStore().load()
            probe.vid = identifier(saved["vid"])
            for name, value in saved["cookies"].items():
                probe.set_cookie(name, value)
            saved.clear()
            probe.verify_account()
            probe.report.update(credentials_reused=True, credential_store="macos_keychain")
            probe.inspect(args.book_id or probe.select_shelf_book())
        elif args.clear_saved_session:
            removed = SessionStore().delete()
            probe.report.update(result="SESSION_CLEARED", saved_session_removed=removed, network_requests=0)
        else:
            probe.report.update(network_requests=0, pending=["owner_web_login", "read_only_source_comparison"])
    except (PreflightError, StoreError) as exc:
        probe.report.update(result="UNVERIFIED", reason=str(exc))
    except (KeyboardInterrupt, EOFError):
        probe.report.update(result="UNVERIFIED", reason="cancelled")
    except Exception:
        probe.report.update(result="UNVERIFIED", reason="preflight_failed")
    finally:
        probe.close()
    text = json.dumps(probe.report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as out:
            args.output.chmod(0o600)
            out.write(text)
    print(text, end="")
    return 1 if probe.report["result"] == "UNVERIFIED" else 0


if __name__ == "__main__":
    raise SystemExit(main())
