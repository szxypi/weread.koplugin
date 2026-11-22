"""Read bounded E-Ink chapter packages in memory; no network or disk writes.

Protocol adapted from MiuRead's eink_crypto.lua and eink_archive.lua at
c1893562aa25a870b8dd076d7be062a3348f823e (AGPL-3.0-only).
This research helper does not establish Web coordinate compatibility.
"""
import base64
import ctypes
import ctypes.util
import io
import json
import math
import re
import ssl
import sys
import zipfile

MAX_ARCHIVE = 32 * 1024 * 1024
MAX_ENTRY = 8 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
MAX_MANIFEST = 1024 * 1024


class PackageError(ValueError):
    pass


def decode_manifest(raw):
    if len(raw) > MAX_MANIFEST:
        raise PackageError('package/manifest_size')
    stack, quoted, escaped = [], False, False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (123, 91):
            stack.append(byte)
            if len(stack) > 32:
                raise PackageError('package/manifest_depth')
        elif byte in (125, 93):
            if not stack or stack.pop() != (123 if byte == 125 else 91):
                raise PackageError('package/manifest_invalid')
    if quoted or stack:
        raise PackageError('package/manifest_invalid')

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise PackageError('package/manifest_duplicate_key')
            result[key] = value
        return result

    return json.loads(raw, object_pairs_hook=unique)


def password(envelope, vid):
    if not isinstance(vid, str) or not re.fullmatch(r'[1-9][0-9]{0,19}', vid):
        raise PackageError('package/invalid_owner')
    if not isinstance(envelope, str) or not 0 < len(envelope) <= 1024:
        raise PackageError('package/invalid_envelope')
    try:
        cipher = base64.b64decode(envelope, validate=True)
    except ValueError:
        raise PackageError('package/invalid_envelope') from None
    if not cipher or len(cipher) % 16:
        raise PackageError('package/invalid_envelope')
    material = (vid.encode() * ((32 + len(vid) - 1) // len(vid)))[:32]
    try:
        # Prefer the libcrypto already loaded by Python's TLS module. macOS's
        # /usr/lib/libcrypto.dylib is an aborting compatibility stub on some
        # systems, so never load that path as a fallback.
        lib = ctypes.CDLL(None)
        if not hasattr(lib, 'EVP_CIPHER_CTX_new'):
            name = ctypes.util.find_library('crypto')
            if not name or sys.platform == 'darwin' and name.startswith('/usr/lib/'):
                raise PackageError('package/crypto_unavailable')
            lib = ctypes.CDLL(name)
        lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
        lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]
        lib.EVP_aes_128_cbc.restype = ctypes.c_void_p
        lib.EVP_DecryptInit_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        lib.EVP_DecryptUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.c_void_p, ctypes.c_int]
        lib.EVP_DecryptFinal_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
        context = lib.EVP_CIPHER_CTX_new()
        if not context:
            raise PackageError('package/crypto_unavailable')
        try:
            key, iv = ctypes.create_string_buffer(material[:16]), ctypes.create_string_buffer(material[16:])
            data = ctypes.create_string_buffer(cipher)
            output = ctypes.create_string_buffer(len(cipher) + 16)
            size, final = ctypes.c_int(), ctypes.c_int()
            if (lib.EVP_DecryptInit_ex(context, lib.EVP_aes_128_cbc(), None, key, iv) != 1
                    or lib.EVP_DecryptUpdate(context, output, ctypes.byref(size), data, len(cipher)) != 1
                    or lib.EVP_DecryptFinal_ex(context, ctypes.byref(output, size.value), ctypes.byref(final)) != 1):
                raise PackageError('package/envelope_decryption_failed')
            result = output.raw[:size.value + final.value]
        finally:
            lib.EVP_CIPHER_CTX_free(context)
    except (AttributeError, OSError):
        raise PackageError('package/crypto_unavailable') from None
    if not result or len(result) > 1024:
        raise PackageError('package/invalid_password')
    return result


def read(data, secret, chapter_uid):
    if not isinstance(data, bytes) or not 22 <= len(data) <= MAX_ARCHIVE:
        raise PackageError('package/archive_size')
    if not isinstance(secret, bytes) or not 0 < len(secret) <= 1024:
        raise PackageError('package/invalid_password')
    if not isinstance(chapter_uid, str) or not re.fullmatch(r'[1-9][0-9]{0,19}', chapter_uid):
        raise PackageError('package/invalid_chapter')
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            rows = archive.infolist()
            if not 1 <= len(rows) <= 2048:
                raise PackageError('package/entry_count')
            names, total, parent_resources = set(), 0, 0
            eligible_rows = []
            for entry in rows:
                name = entry.filename
                if not name or '\x00' in name:
                    raise PackageError('package/empty_entry_name')
                if '\\' in name:
                    raise PackageError('package/backslash_in_name')
                if name.startswith('/'):
                    raise PackageError('package/absolute_entry_name')
                if re.match(r'^[A-Za-z]:', name):
                    raise PackageError('package/drive_entry_name')
                if name in names:
                    raise PackageError('package/duplicate_entry_name')
                if entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) or entry.flag_bits & 0x40:
                    raise PackageError('package/unsupported_entry')
                if entry.file_size > MAX_ENTRY or entry.compress_size > MAX_ARCHIVE:
                    raise PackageError('package/entry_size')
                names.add(name)
                total += entry.file_size
                if total > MAX_TOTAL:
                    raise PackageError('package/uncompressed_size')
                if '..' in name.split('/'):
                    # Names are kept only as opaque lookup keys. No entry is
                    # extracted to the filesystem; parent-path text is rejected.
                    if not re.search(r'\.(?:png|jpe?g|gif|webp)$', name, re.I):
                        raise PackageError('package/parent_entry_name')
                    parent_resources += 1
                    continue
                eligible_rows.append(entry)
            manifest = [row for row in eligible_rows if row.filename.rsplit('/', 1)[-1].lower() == 'info.txt']
            if len(manifest) > 1:
                raise PackageError('package/duplicate_manifest')
            body = [row for row in eligible_rows if not row.is_dir() and row not in manifest
                    and (re.search(r'\.x?html?$', row.filename, re.I)
                         or re.search(r'\.txt$', row.filename, re.I)
                         or '.' not in row.filename.rsplit('/', 1)[-1])]
            selected = None
            if manifest:
                raw = archive.read(manifest[0], pwd=secret)
                info = decode_manifest(raw)
                if not isinstance(info, dict):
                    raise PackageError('package/manifest_invalid')
                if 'chapters' in info and not isinstance(info['chapters'], list):
                    raise PackageError('package/manifest_invalid')
                if isinstance(info.get('chapters'), list):
                    chapters = []
                    for row in info['chapters']:
                        if not isinstance(row, dict):
                            raise PackageError('package/invalid_chapter')
                        uid = row.get('chapterUid')
                        if uid is not None and not ((type(uid) in (int, float) and math.isfinite(uid)
                                                     and 0 <= uid <= 9007199254740991 and int(uid) == uid)
                                or (isinstance(uid, str) and re.fullmatch(r'[0-9]{1,20}', uid))):
                            raise PackageError('package/invalid_chapter')
                        if type(uid) in (int, float):
                            uid = str(int(uid))
                        if uid is not None and uid == chapter_uid:
                            chapters.append(row)
                    if len(chapters) != 1 or not isinstance(chapters[0].get('files'), list) or not chapters[0]['files']:
                        raise PackageError('package/chapter_missing')
                    filenames = chapters[0]['files']
                    if any(not isinstance(item, str) for item in filenames) or len(set(filenames)) != len(filenames):
                        raise PackageError('package/manifest_invalid')
                    by_name = {row.filename: row for row in body}
                    if any(item not in by_name for item in filenames):
                        raise PackageError('package/chapter_missing')
                    selected = [by_name[item] for item in filenames]
            if selected is None:
                if len(body) == 1:
                    selected = body
                else:
                    selected = [row for row in body if row.filename.rsplit('/', 1)[-1].rsplit('.', 1)[0] == chapter_uid]
                    if len(selected) != 1:
                        raise PackageError('package/chapter_ambiguous')
            formats = [bool(re.search(r'\.x?html?$', row.filename, re.I)) for row in selected]
            if len(set(formats)) != 1:
                raise PackageError('package/mixed_formats')
            chunks = [archive.read(row, pwd=secret) for row in selected]
            if any(not chunk for chunk in chunks) or sum(map(len, chunks)) > MAX_ENTRY:
                raise PackageError('package/chapter_size')
            source = b'\n'.join(chunks)
            source.decode('utf-8')
            styles = [archive.read(row, pwd=secret) for row in rows if re.search(r'\.css$', row.filename, re.I)]
            assets = []
            unusable_resources = sum(bool(re.search(r'\.(?:svg|avif|bmp)$', row.filename, re.I)) for row in rows)
            for row in rows:
                if not re.search(r'\.(?:png|jpe?g|gif|webp)$', row.filename, re.I):
                    continue
                image = archive.read(row, pwd=secret)
                if image.startswith(b'\x89PNG\r\n\x1a\n'):
                    ext, mime = '.png', 'image/png'
                elif image.startswith(b'\xff\xd8\xff'):
                    ext, mime = '.jpg', 'image/jpeg'
                elif image.startswith((b'GIF87a', b'GIF89a')):
                    ext, mime = '.gif', 'image/gif'
                elif image.startswith(b'RIFF') and image[8:12] == b'WEBP':
                    ext, mime = '.webp', 'image/webp'
                else:
                    unusable_resources += 1
                    continue
                assets.append({'data': image, 'media_type': mime, 'source': row.filename,
                               'href': f'images/native-{len(assets) + 1}{ext}'})
            return {'source': source, 'html': formats[0], 'entry_count': len(rows),
                    'body_parts': len(selected), 'encrypted_entries': sum(bool(row.flag_bits & 1) for row in rows),
                    'has_manifest': bool(manifest), 'parent_resources': parent_resources,
                    'css': b'\n'.join(styles), 'assets': assets,
                    'image_signatures_recognized': unusable_resources == 0, 'unusable_resources': unusable_resources}
    except (zipfile.BadZipFile, RuntimeError, EOFError, UnicodeError, json.JSONDecodeError, OSError, NotImplementedError):
        raise PackageError('package/cannot_decode') from None
