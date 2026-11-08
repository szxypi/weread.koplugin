#!/usr/bin/env python3
"""Validate native E-Ink QR authorization before implementing it in Lua.

Default: verify ticket/QR creation only. --interactive opens a local QR image,
waits for the owner to scan, then checks login and reads the shelf. Credentials
stay in memory; the optional JSON report contains only stage/status/shape data.
No shelf writes, token persistence, Cookie or API key import.

Protocol reference: MiuRead's miuread/shelf_client.lua (AGPL-3.0-only), and
https://github.com/teng-lin/weread-omni/blob/main/src/auth/qrlogin.ts (MIT).
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import secrets
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener
import webbrowser

BASE = "https://i.weread.qq.com"
HEADERS = {"baseapi": "30", "appver": "2.1.2.10245900", "basever": "2.1.2.10245900",
           "osver": "11", "channelId": "900", "Accept": "application/json",
           "User-Agent": "WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)"}


class ProbeError(RuntimeError):
    pass


class ProbeTimeout(ProbeError):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class NativeProbe:
    def __init__(self, opener=None):
        # No CookieJar: neither existing browser credentials nor Set-Cookie are used.
        self.opener = opener or build_opener(NoRedirect())
        self.report = dict(checked_at=datetime.now(timezone.utc).isoformat(), stages=[])

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        record = dict(stage=stage)
        self.report["stages"].append(record)
        headers = HEADERS.copy()
        if credentials:
            headers.update(vid=credentials["vid"], accessToken=credentials["accessToken"])
        if body is not None:
            headers["Content-Type"] = "application/json"
        req = Request(url, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            with self.opener.open(req, timeout=timeout) as response:
                record["status"] = response.status
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise ProbeError(stage + ": response too large")
                data = json.loads(raw)
        except HTTPError as exc:
            record["status"] = exc.code
            raise ProbeError(stage + f": HTTP {exc.code}") from None
        except TimeoutError:
            raise ProbeTimeout(stage + ": request timed out") from None
        except URLError as exc:
            if isinstance(exc.reason, TimeoutError):
                raise ProbeTimeout(stage + ": request timed out") from None
            raise ProbeError(stage + ": connection failed") from None
        except OSError:
            raise ProbeError(stage + ": connection failed or timed out") from None
        except ValueError:
            raise ProbeError(stage + ": invalid JSON") from None
        if not isinstance(data, dict):
            raise ProbeError(stage + ": invalid object")
        record["keys"] = sorted(data)
        error_code = data.get("errcode", data.get("errCode", 0))
        if error_code not in (0, None):
            if isinstance(error_code, int) and not isinstance(error_code, bool):
                record["error_code"] = error_code
            raise ProbeError(stage + ": API rejected request")
        return data

    def create_qr(self):
        ticket = self.request("qr_ticket", BASE + "/wxticket?nonceStr=weread")
        if not isinstance(ticket.get("signature"), str) or not ticket["signature"] or not ticket.get("timeStamp"):
            raise ProbeError("qr_ticket: missing ticket fields")
        query = urlencode(dict(appid="wxab9b71ad2b90ff34", noncestr="weread", timestamp=ticket["timeStamp"],
                               scope="snsapi_userinfo,snsapi_timeline,snsapi_friend", signature=ticket["signature"]))
        qr = self.request("qr_connect", "https://open.weixin.qq.com/connect/sdk/qrconnect?" + query)
        if qr.get("errcode") != 0 or not isinstance(qr.get("uuid"), str) or not qr["uuid"]:
            raise ProbeError("qr_connect: missing QR session")
        return qr["uuid"]

    def wait_for_code(self, uid, seconds=240):
        deadline, last = time.monotonic() + seconds, None
        while time.monotonic() < deadline:
            query = dict(f="json", uuid=uid)
            if last is not None:
                query["last"] = last
            try:
                data = self.request("qr_poll", "https://long.open.weixin.qq.com/connect/l/qrconnect?" + urlencode(query),
                                    timeout=min(10, max(1, deadline - time.monotonic())))
            except ProbeTimeout:
                time.sleep(1)
                continue
            code = data.get("wx_errcode")
            if code == 405 and isinstance(data.get("wx_code"), str) and data["wx_code"]:
                return data["wx_code"]
            if code not in (404, 408):
                raise ProbeError("qr_poll: expired, declined or invalid response")
            last = code
            time.sleep(1)
        raise ProbeError("qr_poll: session expired")

    @staticmethod
    def login_body(device_id):
        timestamp, random = int(time.time() * 1000), secrets.randbelow(999) + 1
        signature = hashlib.sha256(f"{timestamp}{device_id}{random}".encode()).hexdigest()
        return dict(deviceId=device_id, deviceName="BOOX", deviceType=3, timestamp=timestamp,
                    random=random, trackId="", signature=signature)

    def finish(self, code):
        body = self.login_body("eink334691225" + "".join(str(secrets.randbelow(10)) for _i in range(19)))
        body.update(code=code, appFirstInstall=1, installId="eink31" + "".join(str(secrets.randbelow(10)) for _i in range(26)),
                    isAutoLogout=0, isFromQrcode=1)
        data = self.request("login", BASE + "/login", body=body)
        vid = str(data.get("vid", ""))
        if not vid.isascii() or not vid.isdigit() or any(
                not isinstance(data.get(key), str) or not data[key] for key in ("accessToken", "refreshToken")):
            raise ProbeError("login: incomplete credentials")
        credentials = dict(vid=vid, accessToken=data["accessToken"])
        shelf = self.request("shelf_verify", BASE + "/shelf/sync", credentials=credentials)
        if not isinstance(shelf.get("books"), list):
            raise ProbeError("shelf_verify: missing shelf books")
        self.report["shelf_book_count"] = len(shelf["books"])
        # Reusable by other read-only probes in the same process. The CLI
        # deliberately ignores this private return value and never persists it.
        return dict(credentials, deviceId=body["deviceId"]), shelf


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interactive", action="store_true", help="open QR locally and wait for its owner to scan")
    parser.add_argument("--output", type=Path, help="create a metadata-only report; never a credentials file")
    args = parser.parse_args()
    if args.interactive:
        try:
            import qrcode
        except ImportError:
            parser.error("interactive mode needs the optional qrcode package in a local Python environment")
    probe = NativeProbe()
    try:
        uid = probe.create_qr()
        if args.interactive:
            with tempfile.TemporaryDirectory(prefix="weread-eink-qr-") as root:
                path = Path(root) / "scan.png"
                qrcode.make("https://open.weixin.qq.com/connect/confirm?" + urlencode(dict(uuid=uid))).save(path)
                path.chmod(0o600)
                if not webbrowser.open(path.as_uri()):
                    raise ProbeError("could not open local QR image")
                print("Scan the local QR image with the account owner's WeChat; no credentials will be saved.", flush=True)
                probe.finish(probe.wait_for_code(uid))
            probe.report["result"] = "PASS"
        else:
            probe.report.update(result="PARTIAL", pending=["owner_scan", "login", "shelf_verify"])
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
