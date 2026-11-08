"""Opt-in, project-scoped macOS Keychain storage for owner-approved Web login.

No subprocess, command-line secret, credential file, browser import or logging.
The default probes never instantiate this store. Delete its single item when
the owner's development goal is complete (or earlier at the owner's request).
"""
from contextlib import contextmanager
import ctypes as C
from datetime import datetime, timezone
import json
import re
import sys

SERVICE = "org.codex.weread.goal-validation"
ACCOUNT = "P006_kindle_wxread"
MAX_BYTES = 64 * 1024
COOKIE_NAMES = frozenset(("wr_vid", "wr_skey", "wr_rt", "wr_ql", "wr_fp", "wr_pf"))


class StoreError(RuntimeError):
    pass


class Ref:
    def __init__(self, name):
        self.name = name


class MacKeychain:
    def __init__(self, service=SERVICE, account=ACCOUNT):
        if sys.platform != "darwin" or not service.startswith("org.codex.weread.") or len(service) > 128 or len(account) > 128:
            raise StoreError("keychain_unavailable")
        self.service, self.account = service, account
        try:
            self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            self.sec = C.CDLL("/System/Library/Frameworks/Security.framework/Security")
            for name, args, result in (
                ("CFStringCreateWithCString", [C.c_void_p, C.c_char_p, C.c_uint32], C.c_void_p),
                ("CFDataCreate", [C.c_void_p, C.c_void_p, C.c_long], C.c_void_p),
                ("CFDataGetLength", [C.c_void_p], C.c_long),
                ("CFDataGetBytePtr", [C.c_void_p], C.c_void_p),
                ("CFDictionaryCreateMutable", [C.c_void_p, C.c_long, C.c_void_p, C.c_void_p], C.c_void_p),
                ("CFDictionarySetValue", [C.c_void_p, C.c_void_p, C.c_void_p], None),
                ("CFRelease", [C.c_void_p], None),
            ):
                function = getattr(self.cf, name)
                function.argtypes, function.restype = args, result
            for name, args in (("SecItemAdd", [C.c_void_p, C.c_void_p]),
                               ("SecItemUpdate", [C.c_void_p, C.c_void_p]),
                               ("SecItemCopyMatching", [C.c_void_p, C.POINTER(C.c_void_p)]),
                               ("SecItemDelete", [C.c_void_p])):
                function = getattr(self.sec, name)
                function.argtypes, function.restype = args, C.c_int32
        except (OSError, AttributeError):
            raise StoreError("keychain_unavailable") from None

    @contextmanager
    def dictionary(self, fields):
        owned = []
        try:
            callbacks = [C.addressof((C.c_byte * 1).in_dll(self.cf, name))
                         for name in ("kCFTypeDictionaryKeyCallBacks", "kCFTypeDictionaryValueCallBacks")]
            result = self.cf.CFDictionaryCreateMutable(None, 0, *callbacks)
            if not result:
                raise StoreError("keychain_unavailable")
            owned.append(result)
            for key, value in fields.items():
                key_ref = C.c_void_p.in_dll(self.sec, key).value
                if isinstance(value, Ref):
                    value_ref = C.c_void_p.in_dll(self.sec, value.name).value
                elif isinstance(value, bool):
                    value_ref = C.c_void_p.in_dll(self.cf, "kCFBooleanTrue" if value else "kCFBooleanFalse").value
                elif isinstance(value, bytes):
                    buffer = C.create_string_buffer(value)
                    value_ref = self.cf.CFDataCreate(None, buffer, len(value))
                    C.memset(buffer, 0, len(value))
                    owned.append(value_ref)
                elif isinstance(value, str):
                    value_ref = self.cf.CFStringCreateWithCString(None, value.encode("utf-8"), 0x08000100)
                    owned.append(value_ref)
                else:
                    raise StoreError("keychain_unavailable")
                if not key_ref or not value_ref:
                    raise StoreError("keychain_unavailable")
                self.cf.CFDictionarySetValue(result, key_ref, value_ref)
            yield result
        finally:
            for value in reversed(owned):
                if value:
                    self.cf.CFRelease(value)

    def query(self):
        return dict(kSecClass=Ref("kSecClassGenericPassword"), kSecAttrService=self.service, kSecAttrAccount=self.account)

    def save(self, data):
        if not isinstance(data, bytes) or not 0 < len(data) <= MAX_BYTES:
            raise StoreError("session_invalid")
        fields = dict(self.query(), kSecValueData=data, kSecAttrSynchronizable=False,
                      kSecAttrAccessible=Ref("kSecAttrAccessibleWhenUnlockedThisDeviceOnly"),
                      kSecAttrLabel="KOReader 微信读书开发验证（目标完成后清理）")
        with self.dictionary(fields) as attributes:
            status = self.sec.SecItemAdd(attributes, None)
        if status == -25299:  # duplicate: replace only this project's item
            with self.dictionary(self.query()) as query, self.dictionary(dict(kSecValueData=data)) as attributes:
                status = self.sec.SecItemUpdate(query, attributes)
        if status != 0:
            raise StoreError("keychain_save_failed_" + str(status))

    def load(self):
        result = C.c_void_p()
        with self.dictionary(dict(self.query(), kSecReturnData=True, kSecMatchLimit=Ref("kSecMatchLimitOne"))) as query:
            status = self.sec.SecItemCopyMatching(query, C.byref(result))
        if status == -25300:
            return None
        if status != 0 or not result.value:
            raise StoreError("keychain_read_failed_" + str(status))
        try:
            size = self.cf.CFDataGetLength(result)
            if not 0 < size <= MAX_BYTES:
                raise StoreError("session_invalid")
            return C.string_at(self.cf.CFDataGetBytePtr(result), size)
        finally:
            self.cf.CFRelease(result)

    def delete(self):
        with self.dictionary(self.query()) as query:
            status = self.sec.SecItemDelete(query)
        if status not in (0, -25300):
            raise StoreError("keychain_delete_failed_" + str(status))
        return status == 0


def validate(payload):
    if not isinstance(payload, dict) or set(payload) != {"schema", "scope", "created_at", "vid", "cookies"}:
        raise StoreError("session_invalid")
    if type(payload["schema"]) is not int or payload["schema"] != 1 or payload["scope"] != ACCOUNT:
        raise StoreError("session_invalid")
    vid, cookies = payload["vid"], payload["cookies"]
    if not isinstance(vid, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", vid) or not isinstance(cookies, dict):
        raise StoreError("session_invalid")
    if not {"wr_vid", "wr_skey"} <= set(cookies) <= COOKIE_NAMES or cookies.get("wr_vid") != vid:
        raise StoreError("session_invalid")
    if not isinstance(payload["created_at"], str) or len(payload["created_at"]) > 64:
        raise StoreError("session_invalid")
    for value in cookies.values():
        if not isinstance(value, str) or not 0 < len(value) <= 4096 or any(ord(c) < 33 or ord(c) > 126 or c in ';"\\' for c in value):
            raise StoreError("session_invalid")
    return payload


class SessionStore:
    def __init__(self, backend=None):
        self.backend = backend if backend is not None else MacKeychain()

    def save(self, probe):
        if not probe.authenticated:
            raise StoreError("verified_login_required")
        cookies = {}
        for cookie in probe.cookies:
            if cookie.name in COOKIE_NAMES and cookie.domain in (".weread.qq.com", "weread.qq.com") and cookie.path == "/":
                if cookie.name in cookies:
                    raise StoreError("session_invalid")
                cookies[cookie.name] = cookie.value
        payload = validate(dict(schema=1, scope=ACCOUNT, created_at=datetime.now(timezone.utc).isoformat(), vid=probe.vid, cookies=cookies))
        data = json.dumps(payload, separators=(",", ":")).encode()
        self.backend.save(data)
        if self.backend.load() != data:
            raise StoreError("keychain_readback_mismatch")

    def load(self):
        data = self.backend.load()
        if data is None:
            raise StoreError("saved_session_missing")
        try:
            if not isinstance(data, bytes) or len(data) > MAX_BYTES:
                raise StoreError("session_invalid")
            return validate(json.loads(data))
        except (ValueError, TypeError, UnicodeError):
            raise StoreError("session_invalid") from None

    def delete(self):
        return self.backend.delete()
