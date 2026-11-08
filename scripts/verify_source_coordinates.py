#!/usr/bin/env python3
"""Validate Web Reader source coordinates before changing Lua progress writes.

Default: offline fixtures only. --public reads one anonymous preview chapter,
then compares it with the current official JavaScript parser in an isolated
browser. All browser non-GET requests are blocked. No account, cookie file,
storage state, progress upload, source text or credential report is created.
Optional browser dependency: playwright (use a separate virtual environment).

Coordinate convention references MiuRead's wr_co.lua / source_position.lua
(c1893562aa25a870b8dd076d7be062a3348f823e, AGPL-3.0-only).
"""
import argparse
from bisect import bisect_left
from datetime import datetime, timezone
import hashlib
from html import unescape
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from fetch_weread_epub import decode_content_shards, make_content_params, read_reader_state, weread_e

MAX_SOURCE_BYTES = 2 * 1024 * 1024
BASE = "https://weread.qq.com"
BODY_TAGS = set(('body p div span a abbr address area article aside audio b bdi bdo big blockquote br caption center cite code '
                 'col colgroup dd del details dl dt em figcaption figure font footer h1 h2 h3 h4 h5 h6 header hr i img ins '
                 'li mark nav ol pre q rp rt ruby s samp section small source strike strong sub summary sup table tbody '
                 'td tfoot th thead tr tt u ul video wbr').split())
# Live parser comparison found that these tags can change the coordinate
# stream. This prototype refuses them; reproducing that transformation is a
# remaining requirement, rather than silently treating raw offsets as exact.
SANITIZER_TAGS = {'a', 'figcaption', 'figure', 'q', 'rp', 'rt', 'ruby', 'samp',
                  'source', 'strike', 'summary', 'wbr'}
BODY_TAGS -= SANITIZER_TAGS
FIXTURES = (
    '<?xml version="1.0"?><html><head><title>标题</title></head><body><p>甲😀乙&amp;丙</p><p>第二段落</p></body></html>',
    '<html><body><p title="A > B">Alpha &lt; beta &#x1F600; &quot;quoted&quot;</p><br/><p>末段</p></body></html>',
    '<html><head><style>p{color:red}</style></head><body><!--注释--><p>前文\r\n后文</p><script>hidden</script></body></html>',
    '\ufeff<html><body><p>带字节序标记的原始正文</p></body></html>',
    '<html><body><p>前文\r\n后文\n尾声</p></body></html>',
    '<html><body>' + ''.join('<' + tag + '>Tag' + str(index) + '正文</' + tag + '>'
                            for index, tag in enumerate(sorted(BODY_TAGS - {'body'}))) + '</body></html>',
)
FILTER_CASES = tuple((tag, '<html><body><p>prefix</p><' + tag + '>Marker</' + tag + '><p>suffix</p></body></html>')
                     for tag in sorted(SANITIZER_TAGS | {'script', 'style', 'unknown'}))
FILTERED_FIXTURES = (
    '<html><body><p>before<a href="https://example.invalid/">linked</a>after<strong>retained</strong>end</p></body></html>',
    '<html><body><p>before<a>outer<q>inner</q>outer-end</a>after</p><p>reset</p></body></html>',
    '<html><body><p>before<!--kept comment-->after<a/>tail</p></body></html>',
    '<html><body><p>left > right &amp; middle <3 tail</p><p>reset</p></body></html>',
    '<html><body><p>' + '>' * 20 + '</p><p>abcdefghijklmnop</p></body></html>',
    '\ufeff<html><body><p>abcdefghijklm<a>甲😀乙&amp;丙0123456789</a>tail</p></body></html>',
    '<html><body><p>before<script/>after <3 &amp; more<style/>tail</p></body></html>',
)


class CoordinateError(Exception):
    """Controlled diagnostics only; never interpolate remote text or URLs."""


def boundaries(raw):
    """Raw-XHTML codepoint boundaries -> zero-based JS UTF-16 offsets."""
    try:
        valid = isinstance(raw, str) and len(raw.encode("utf-8")) <= MAX_SOURCE_BYTES
    except UnicodeError:
        valid = False
    if not valid:
        raise CoordinateError("source: invalid or too large")
    offsets = [0]
    for char in raw:
        offsets.append(offsets[-1] + (2 if ord(char) > 0xFFFF else 1))
    return raw, offsets


def from_co(offsets, co):
    if type(co) is not int or co < 0:
        raise CoordinateError("offset: invalid")
    index = bisect_left(offsets, co)
    if index == len(offsets) or offsets[index] != co:
        raise CoordinateError("offset: not an exact source boundary")
    return index


class SourceText(HTMLParser):
    """Keep visible source characters tied to their complete raw HTML spans."""
    def __init__(self, raw):
        super().__init__(convert_charrefs=False)
        self.raw, self.offsets = boundaries(raw)
        if '<body' not in self.raw or any(ord(char) < 32 and char not in '\t\r\n' for char in self.raw):
            raise CoordinateError("source: unsupported XHTML structure")
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", self.raw)]
        self.body, self.suppressed = False, []
        self.saw_body = False
        self.characters, self.starts, self.ends = [], [], []
        self.feed(self.raw)
        self.close()
        if not self.saw_body or self.body:
            raise CoordinateError("source: complete body required")

    def position(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def handle_starttag(self, tag, _attrs):
        if tag == "body":
            if self.saw_body:
                raise CoordinateError("source: multiple bodies")
            self.saw_body = True
            self.body = True
        if self.body and tag not in BODY_TAGS:
            # The official XSS filter can remove/replace these tags before
            # assigning text offsets. A raw-coordinate map cannot assume that
            # their lengths still count. Do not silently extrapolate past one.
            raise CoordinateError("source: unsupported body tag")
        if tag in ("script", "style"):
            self.suppressed.append(tag)

    def handle_endtag(self, tag):
        if self.body and tag not in BODY_TAGS:
            raise CoordinateError("source: unsupported body tag")
        if tag == "body":
            self.body = False
        if self.suppressed and self.suppressed[-1] == tag:
            self.suppressed.pop()

    def handle_data(self, data):
        if self.body and not self.suppressed:
            start = self.position()
            for i, char in enumerate(data):
                self.characters.append(char)
                self.starts.append(self.offsets[start + i])
                self.ends.append(self.offsets[start + i + 1])

    def handle_entityref(self, name):
        self.entity("&" + name + ";")

    def handle_charref(self, name):
        self.entity("&#" + name + ";")

    def entity(self, encoded):
        if not self.body or self.suppressed:
            return
        start = self.position()
        if self.raw[start:start + len(encoded)] != encoded:
            raise CoordinateError("source: unterminated entity")
        for char in unescape(encoded):
            self.characters.append(char)
            self.starts.append(self.offsets[start])
            self.ends.append(self.offsets[start + len(encoded)])

    def locate(self, text, before="", after=""):
        def normalize(value):
            return "".join(char for char in value if not char.isspace())
        needle, prefix, suffix = normalize(text), normalize(before), normalize(after)
        if len(needle) < 12:
            raise CoordinateError("anchor: too short")
        flat, indices = [], []
        for i, char in enumerate(self.characters):
            if not char.isspace():
                flat.append(char)
                indices.append(i)
        haystack = "".join(flat)
        matches, start = [], 0
        while (at := haystack.find(needle, start)) >= 0:
            end = at + len(needle)
            if (not prefix or haystack[max(0, at - len(prefix)):at] == prefix) and (not suffix or haystack.startswith(suffix, end)):
                matches.append((self.starts[indices[at]], self.ends[indices[end - 1]]))
                if len(matches) > 1:
                    raise CoordinateError("anchor: missing or ambiguous")
            start = at + 1  # overlapping matches also make an anchor ambiguous
        if len(matches) != 1:
            raise CoordinateError("anchor: missing or ambiguous")
        return matches[0]


class FilteredSource(HTMLParser):
    """Coordinate runs between retained tags, before DOM glyph normalization.

    The official filter removes ignored tags but retains their text. The text
    parser counts through that filtered run from the original *retained* tag's
    end; the next retained tag resets the source base. This is neither a raw
    index nor the index in an entirely stripped/rebuilt document.
    """
    def __init__(self, raw):
        super().__init__(convert_charrefs=False)
        self.raw, self.offsets = boundaries(raw)
        if (self.raw.count('<body') != 1 or self.raw.count('</body') != 1
                or any(ord(char) < 32 and char not in '\t\r\n' for char in self.raw)):
            raise CoordinateError("source: unsupported XHTML structure")
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", self.raw)]
        self.body, self.saw_body, self.raw_text_tag = False, False, None
        self.base, self.pieces, self.segments = 0, [], []
        self.characters, self.starts, self.ends = [], [], []
        self.feed(self.raw)
        self.close()
        if not self.saw_body or self.body:
            raise CoordinateError("source: complete body required")
        self.flush_run()
        # Reuse the conservative local text matcher, retaining coordinates in
        # the filtered run. This does not enable any progress upload.
        for base, text in self.segments:
            visible = SourceText('<html><body>' + text + '</body></html>')
            self.characters.extend(visible.characters)
            self.starts.extend(base + co - 12 for co in visible.starts)
            self.ends.extend(base + co - 12 for co in visible.ends)

    def position(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def flush_run(self):
        if self.pieces:
            self.segments.append((self.base, ''.join(self.pieces)))
            self.pieces = []

    def retained(self, end):
        self.flush_run()
        self.base = self.offsets[end]

    def handle_starttag(self, tag, _attrs):
        if tag == 'body':
            if self.saw_body:
                raise CoordinateError("source: multiple bodies")
            self.saw_body, self.body = True, True
        if self.body and tag in BODY_TAGS:
            self.retained(self.position() + len(self.get_starttag_text()))
        if self.body and tag in ('script', 'style') and not self.get_starttag_text().rstrip().endswith('/>'):
            self.raw_text_tag = tag

    def handle_startendtag(self, tag, attrs):
        if tag == 'body':
            raise CoordinateError("source: complete body required")
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if self.body and tag in BODY_TAGS:
            end = self.raw.find('>', self.position())
            if end < 0:
                raise CoordinateError("source: incomplete closing tag")
            self.retained(end + 1)
        if tag == 'body':
            self.body = False
        if tag == self.raw_text_tag:
            self.raw_text_tag = None

    def handle_data(self, text):
        if self.body:
            if self.raw_text_tag and '<' in text:
                raise CoordinateError("source: unsupported raw-text markup")
            # XSS's escapeHtml only replaces angle brackets. Existing entities
            # stay encoded and still consume their complete source width.
            self.pieces.append(text.replace('<', '&lt;').replace('>', '&gt;'))

    def entity(self, encoded):
        if self.body:
            start = self.position()
            if self.raw[start:start + len(encoded)] != encoded:
                raise CoordinateError("source: unterminated entity")
            self.pieces.append(encoded)

    def handle_entityref(self, name):
        self.entity('&' + name + ';')

    def handle_charref(self, name):
        self.entity('&#' + name + ';')

    def handle_comment(self, _text):
        # The text run reaching the official span parser excludes comments;
        # their width does not count until the next retained-tag reset.
        pass

    def unknown_decl(self, _data):
        if self.body:
            raise CoordinateError("source: unsupported body declaration")

    def handle_decl(self, _data):
        if self.body:
            raise CoordinateError("source: unsupported body declaration")

    def handle_pi(self, _data):
        if self.body:
            raise CoordinateError("source: unsupported body declaration")

    locate = SourceText.locate

    def anchor_at(self, co, size=36):
        if type(co) is not int or co < 0:
            raise CoordinateError("offset: invalid")
        candidates = [i for i, start in enumerate(self.starts) if start == co]
        if len(candidates) != 1:
            raise CoordinateError("offset: missing or ambiguous visible boundary")
        index = candidates[0]
        text = ''.join(self.characters[index:index + size])
        # Confirm the return anchor itself is unique. Repeated text cannot be
        # silently assigned to the first occurrence during the reverse jump.
        if self.locate(text)[0] != co:
            raise CoordinateError("offset: reverse anchor mismatch")
        return text


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, _request, _file, _code, _message, _headers, _new_url):
        return None


class PublicProbe:
    def __init__(self, opener=None):
        self.opener = opener or build_opener(NoRedirect())  # no cookie processor
        self.stages = []

    def request(self, url, body=None):
        u = urlsplit(url)
        valid = (u.scheme == "https" and u.netloc == "weread.qq.com" and not u.query and not u.fragment
                 and ((body is None and re.fullmatch(r"/web/reader/[a-zA-Z0-9]+", u.path))
                      or (body is not None and u.path in {"/web/book/chapter/e_0", "/web/book/chapter/e_1", "/web/book/chapter/e_3"})))
        if not valid:
            raise CoordinateError("request: outside public source read scope")
        stage = dict(kind="reader" if body is None else u.path.rsplit("/", 1)[1])
        self.stages.append(stage)
        data = json.dumps(body, separators=(",", ":")).encode() if body is not None else None
        request = Request(url, data=data, headers={"User-Agent": "Mozilla/5.0", "Origin": BASE,
                          "Referer": BASE + "/", "Content-Type": "application/json;charset=UTF-8"})
        try:
            with self.opener.open(request, timeout=20) as response:
                stage["status"] = response.status
                raw = response.read(4 * 1024 * 1024 + 1)
            if len(raw) > 4 * 1024 * 1024:
                raise CoordinateError("response: too large")
            return raw.decode("utf-8")
        except HTTPError as exc:
            stage["status"] = exc.code
            raise CoordinateError("response: HTTP rejection") from None
        except (URLError, OSError, UnicodeError):
            raise CoordinateError("response: unavailable") from None

    def fetch(self, book_id):
        if not isinstance(book_id, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", book_id):
            raise CoordinateError("book: invalid public book")
        url = BASE + "/web/reader/" + weread_e(book_id)
        try:
            state = read_reader_state(self.request(url))
            if state.book_id != book_id or not state.psvts or not state.current_chapter.get("chapterUid"):
                raise CoordinateError("reader: missing source context")
            params = make_content_params(book_id, state.current_chapter["chapterUid"], state.psvts, sc=1)
            source = decode_content_shards(*(self.request(BASE + "/web/book/chapter/" + key, params)
                                              for key in ("e_0", "e_1", "e_3")))
            if "<body" not in source:
                raise CoordinateError("source: XHTML preview unavailable")
            return url, boundaries(source)[0]
        except CoordinateError:
            raise
        except Exception:
            raise CoordinateError("source: context or decoding failed") from None


CAPTURE_REQUIRE = """() => {
    const original = Function.prototype.call;
    Function.prototype.call = function(receiver, ...args) {
        const r = args[2];
        if (typeof r === 'function' && r.m && r.c && Object.keys(r.m).length > 100) {
            window.__coordinateProbeRequire = r;
            Function.prototype.call = original;
        }
        return Reflect.apply(original, this, [receiver, ...args]);
    };
}"""

PARSE_SOURCES = """sources => {
    const r = window.__coordinateProbeRequire;
    if (!r) throw new Error('parser runtime unavailable');
    const parsers = Object.values(r.c).map(m => m.exports).filter(e =>
        e && typeof e.parse === 'function' && typeof e.parseTxt === 'function'
        && typeof e.parseHorizontalReaderTxtText === 'function');
    if (parsers.length !== 1) throw new Error('parser identity changed');
    return sources.map(raw => {
        const parsed = parsers[0].parse(raw);
        if (!Array.isArray(parsed) || !parsed.every(x => typeof x === 'string'))
            throw new Error('parser contract changed');
        const doc = new DOMParser().parseFromString(parsed.join(''), 'text/html');
        return Array.from(doc.querySelectorAll('span[data-wr-role="text"][data-wr-co]'))
            .map(n => ({co: Number(n.getAttribute('data-wr-co')), text: n.textContent}));
    });
}"""


def check_parser_rows(raw, rows, statistics=None, model=None):
    raw, _offsets = boundaries(raw)
    streams = [(0, raw.encode("utf-16-le"))] if model is None else [
        (base, text.encode("utf-16-le")) for base, text in model.segments]
    if not isinstance(rows, list) or not rows:
        raise CoordinateError("parser: no source-coordinate text nodes")
    for row in rows:
        co, text = row.get("co"), row.get("text")
        if type(co) is not int or co < 0 or not isinstance(text, str) or not text:
            raise CoordinateError("parser: invalid text node")
        actual = text.encode("utf-16-le", "surrogatepass")
        matched = False
        for base, encoded in streams:
            position = (co - base) * 2
            if position < 0 or position >= len(encoded):
                continue
            end = position + max(128, len(actual) * 40)
            tail = encoded[position:end].decode("utf-16-le", "surrogatepass")
            expected = unescape(tail).encode("utf-16-le", "surrogatepass")
            kind = None
            if expected.startswith(actual):
                matched = True
            elif text == "\n" and tail.startswith("\r"):
                kind, matched = "normalized_newline_nodes", True
            elif tail.encode("utf-16-le", "surrogatepass").startswith(actual):
                kind, matched = "literal_entity_nodes", True
            elif text == "\ufffd" and 0xD800 <= int.from_bytes(encoded[position:position + 2], "little") <= 0xDFFF:
                # The official parser splits astral scalars. DOMParser repairs
                # each half; this validates its coordinate, not a safe local
                # boundary. Local reverse lookup still refuses interior halves.
                kind, matched = "surrogate_replacement_nodes", True
            if matched:
                if statistics is not None and kind:
                    statistics[kind] = statistics.get(kind, 0) + 1
                break
        if not matched:
            raise CoordinateError("parser: source coordinate mismatch")
    return len(rows)


def check_lua(command, sources, rows):
    payload, expected = [], []
    for raw in sources:
        model = FilteredSource(raw)
        flat = ''.join(char for char in model.characters if not char.isspace())
        queries, positions, scalar_points = [], [], []
        visible = [index for index, char in enumerate(model.characters) if not char.isspace()]
        for start in sorted({0, max(0, len(flat) // 2 - 12), max(0, len(flat) - 24)}):
            quote = flat[start:start + 24]
            first = flat.find(quote)
            if len(quote) < 12 or flat.find(quote, first + 1) >= 0:
                continue
            queries.append(quote)
            co, end_co = model.locate(quote)
            positions.append(dict(co=co, end_co=end_co))
            scalar_points.append([dict(point_offset=offset,
                co=model.ends[visible[first + len(quote) - 1]] if offset == len(quote)
                else model.starts[visible[first + offset]])
                for offset in sorted({0, len(quote) // 2, len(quote)})])
        payload.append(dict(html=raw, queries=queries))
        expected.append((model, flat, positions, scalar_points))
    try:
        result = subprocess.run(command, input=json.dumps(dict(sources=payload)), text=True,
                                capture_output=True, timeout=60, check=False)
        if result.returncode != 0 or len(result.stdout) > 16 * 1024 * 1024:
            raise CoordinateError("lua: probe failed")
        maps = json.loads(result.stdout)["maps"]
    except CoordinateError:
        raise
    except Exception:
        raise CoordinateError("lua: probe unavailable or malformed") from None
    if not isinstance(maps, list) or len(maps) != len(expected):
        raise CoordinateError("lua: map count mismatch")
    points = scalar_count = nodes = 0
    for raw, actual, reference, parsed_rows in zip(sources, maps, expected, rows, strict=True):
        model, flat, positions, scalar_points = reference
        if (not isinstance(actual, dict) or actual.get('segments') != [list(segment) for segment in model.segments]
                or actual.get('flat') != flat or actual.get('positions') != positions
                or actual.get('scalar_positions') != scalar_points):
            raise CoordinateError("lua: model or local-position mismatch")
        # Equal streams are also checked against the independently executed
        # official parser; this is not only a Lua/Python implementation match.
        nodes += check_parser_rows(raw, parsed_rows, model=model)
        points += len(positions)
        scalar_count += sum(map(len, scalar_points))
    return dict(lua_verified=True, lua_cases=len(maps), lua_positions=points, lua_scalar_positions=scalar_count, lua_official_text_nodes=nodes)


def verify_public(book_id, channel="chrome", lua_command=None):
    from playwright.sync_api import sync_playwright
    probe = PublicProbe()
    url, source = probe.fetch(book_id)
    blocked = 0
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel=channel, headless=True)
        context = browser.new_context(service_workers="block")
        def route(request_route):
            nonlocal blocked
            request = request_route.request
            u = urlsplit(request.url)
            if (request.method == "GET" and u.scheme == "https" and not u.username
                    and u.hostname in ("weread.qq.com", "cdn.weread.qq.com")):
                request_route.continue_()
            else:
                blocked += 1
                request_route.abort()
        try:
            context.route("**/*", route)
            context.add_init_script("(" + CAPTURE_REQUIRE + ")()")
            page = context.new_page()
            page.goto(url, wait_until="networkidle", timeout=45000)
            assets = page.evaluate("""() => Array.from(document.querySelectorAll('script[src]'))
                .map(n => new URL(n.src)).filter(u => u.origin === 'https://cdn.weread.qq.com'
                    && /^\\/web\\/wrwebnjlogic\\/js\\/[a-zA-Z0-9.]+\\.js$/.test(u.pathname))
                .map(u => u.origin + u.pathname)""")
            sources = [source, *FIXTURES, *FILTERED_FIXTURES]
            rows = page.evaluate(PARSE_SOURCES, sources + [raw for _tag, raw in FILTER_CASES])
            if len(rows) != len(sources) + len(FILTER_CASES):
                raise CoordinateError("parser: sample count changed")
            counts, statistics, rejected = [], {}, 0
            baseline_count = 1 + len(FIXTURES)
            for index, (raw, result) in enumerate(zip(sources[:baseline_count], rows[:baseline_count], strict=True)):
                try:
                    SourceText(raw)
                except CoordinateError as exc:
                    if index != 3 or str(exc) != "source: unsupported body tag":
                        raise
                    # This adversarial fixture intentionally demonstrates the
                    # sanitizer boundary. Its raw map must refuse to produce a
                    # position; never count it among supported passing sources.
                    rejected += 1
                    counts.append(None)
                    continue
                try:
                    counts.append(check_parser_rows(raw, result, statistics))
                except CoordinateError as exc:
                    raise CoordinateError("sample " + str(index) + ": " + str(exc)) from None
            filtered_counts, filtered_statistics = [], {}
            for index, (raw, result) in enumerate(zip(sources + [raw for _tag, raw in FILTER_CASES], rows, strict=True)):
                try:
                    filtered_counts.append(check_parser_rows(raw, result, filtered_statistics, FilteredSource(raw)))
                except CoordinateError as exc:
                    raise CoordinateError("filtered sample " + str(index) + ": " + str(exc)) from None
            counterexamples = []
            for (tag, raw), result in zip(FILTER_CASES, rows[len(sources):], strict=True):
                models = (raw, re.sub(r'</?' + re.escape(tag) + r'\b[^>]*>', '', raw))
                matches = []
                for model in models:
                    try:
                        check_parser_rows(model, result)
                        matches.append(True)
                    except CoordinateError:
                        matches.append(False)
                if any(matches):
                    raise CoordinateError("parser: sanitizer counterexample behavior changed")
                counterexamples.append(dict(tag=tag, raw_coordinates_match=False, stripped_tag_coordinates_match=False,
                                            filtered_run_coordinates_match=True))
            if any(cookie["name"] in ("wr_skey", "wr_rt", "wr_vid") for cookie in context.cookies()):
                raise CoordinateError("browser: unexpectedly authenticated")
            lua = check_lua(lua_command, sources + [raw for _tag, raw in FILTER_CASES], rows) if lua_command else dict(lua_verified=False)
            return dict(result="PARTIAL", **lua, public_stages=probe.stages, source_bytes=len(source.encode()),
                        source_utf16_units=boundaries(source)[1][-1], public_text_nodes=counts[0],
                        source_sha256=hashlib.sha256(source.encode()).hexdigest(), reference_assets=assets,
                        browser_version=browser.version, supported_body_tags=sorted(BODY_TAGS),
                        verified_filtered_tags=sorted(SANITIZER_TAGS), filtered_model_verified=True,
                        filtered_case_count=len(filtered_counts), filtered_text_nodes=sum(filtered_counts),
                        filtered_statistics=filtered_statistics,
                        sanitizer_counterexamples=counterexamples,
                        fixture_text_nodes=counts[1:], browser_authenticated=False,
                        surrogate_replacement_nodes=statistics.get("surrogate_replacement_nodes", 0),
                        literal_entity_nodes=statistics.get("literal_entity_nodes", 0), public_parser_verified=True,
                        normalized_newline_nodes=statistics.get("normalized_newline_nodes", 0),
                        unsupported_source_fixture_rejections=rejected, progress_mapping_enabled=False,
                        blocked_browser_requests=blocked, account_writes_attempted=0,
                        wire_progress_write_verified=False)
        finally:
            context.close()
            browser.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public", action="store_true", help="anonymous preview and current official JS parser; no account writes")
    parser.add_argument("--book-id", help="one public ordinary book; needed with --public")
    parser.add_argument("--browser-channel", default="chrome", help="isolated browser channel, default system Chrome")
    parser.add_argument("--output", type=Path, help="new metadata-only report")
    parser.add_argument("--lua-command", nargs=argparse.REMAINDER, help="optional memory-only Lua probe command; put it last")
    args = parser.parse_args()
    if args.output and args.output.exists():
        parser.error("output already exists")
    if args.public and not args.book_id:
        parser.error("public verification needs --book-id")
    if args.lua_command is not None and (not args.public or not args.lua_command):
        parser.error("Lua comparison needs --public and a non-empty probe command")
    report = dict(checked_at=datetime.now(timezone.utc).isoformat(), probe="web_source_coordinates")
    try:
        for raw in FIXTURES:
            _source, offsets = boundaries(raw)
            assert all(from_co(offsets, co) == i for i, co in enumerate(offsets))
        local_models = [FilteredSource(raw) for raw in (*FIXTURES, *FILTERED_FIXTURES, *(raw for _tag, raw in FILTER_CASES))]
        report.update(offline_fixtures=len(FIXTURES), filtered_fixtures=len(FILTERED_FIXTURES),
                      offline_filtered_models=len(local_models), account_writes_attempted=0)
        if args.public:
            try:
                report.update(verify_public(args.book_id, args.browser_channel, args.lua_command))
            except CoordinateError:
                raise
            except Exception:
                raise CoordinateError("browser: dependency, runtime or parser unavailable") from None
        else:
            report.update(result="OFFLINE_ONLY", network_requests=0, public_parser_verified=False)
    except CoordinateError as exc:
        report.update(result="UNVERIFIED", reason=str(exc))
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as out:
            out.write(text)
    print(text, end="")
    raise SystemExit(0 if report["result"] in ("PARTIAL", "OFFLINE_ONLY") else 1)


if __name__ == "__main__":
    main()
