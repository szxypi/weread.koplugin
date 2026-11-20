"""Memory-only comparison with the current official, anonymously loaded parser.

The private source is supplied only after the fresh browser is offline and
all WebSockets/HTTP are blocked. No account cookies enter the browser, and no
private source, target value, DOM or screenshot is returned or saved.
"""
from contextlib import contextmanager
from html.parser import HTMLParser
import re
from urllib.parse import urlsplit

from verify_source_coordinates import (CAPTURE_REQUIRE, PARSE_SOURCES, MAX_SOURCE_BYTES, CoordinateError,
                                       FilteredSource, boundaries, check_lua, check_parser_rows)

PUBLIC_READER = "https://weread.qq.com/web/reader/b4332510813abc34eg014159"
MAX_PRIVATE_BYTES = 256 * 1024
MAX_BATCHES = 256
MAX_BATCH_NODES = 100000
BOUNDED_PARSE = ('sources => { const result = (' + PARSE_SOURCES + ')(sources); '
                 'if (result.length !== 1 || result[0].length > 100000) throw new Error("batch limit"); '
                 'return result; }')


class BodyStarts(HTMLParser):
    """Find actual body tags, never strings in comments or raw text."""
    def __init__(self,raw):
        super().__init__(convert_charrefs=False)
        self.lines=[0]+[match.end() for match in re.finditer('\n',raw)]
        self.starts=[];self.feed(raw);self.close()

    def handle_starttag(self,tag,_attrs):
        if tag=='body':
            line,column=self.getpos();self.starts.append(self.lines[line-1]+column)


def source_batches(raw):
    """Split only before body tags; reject any single oversized part."""
    _raw,offsets=boundaries(raw)
    if len(raw.encode('utf-8'))>MAX_SOURCE_BYTES:raise CoordinateError('parser: source limit')
    starts=BodyStarts(raw).starts
    if not 1<=len(starts)<=MAX_BATCHES:raise CoordinateError('parser: body boundaries')
    edges=starts[1:]+[len(raw)];begin=0;previous=0;parts=[]
    for end in edges:
        if len(raw[begin:end].encode('utf-8'))>MAX_PRIVATE_BYTES:
            if previous<=begin:raise CoordinateError('parser: body exceeds batch limit')
            parts.append((begin,previous,offsets[begin]));begin=previous
            if len(raw[begin:end].encode('utf-8'))>MAX_PRIVATE_BYTES:
                raise CoordinateError('parser: body exceeds batch limit')
        previous=end
    if previous>begin:parts.append((begin,previous,offsets[begin]))
    if not parts or len(parts)>MAX_BATCHES:raise CoordinateError('parser: batch limit')
    return parts


def verify_source_batched(raw,target_co):
    """Verify body-aligned batches and their global-model composition only.

    The official parser is not run on the whole source, so this cannot prove
    that its whole-source behavior equals the composed batch behavior.
    """
    if type(target_co) is not int or target_co<0:raise CoordinateError('parser: invalid target')
    try:
        parts=source_batches(raw)
        whole=FilteredSource(raw,allow_multiple_bodies=True)
        assembled=[];count=0;at_start=False
        with offline_parser() as (page,_version):
            for begin,end,base in parts:
                chunk=raw[begin:end]
                model=FilteredSource(chunk,allow_multiple_bodies=True)
                rows=page.evaluate(BOUNDED_PARSE,[chunk])
                if (not isinstance(rows,list) or len(rows)!=1 or not isinstance(rows[0],list)
                        or len(rows[0])>MAX_BATCH_NODES):raise CoordinateError('parser: batch contract')
                count+=check_parser_rows(chunk,rows[0],model=model)
                at_start=at_start or any(row.get('co')+base==target_co for row in rows[0])
                assembled.extend((offset+base,text) for offset,text in model.segments)
            if assembled!=whole.segments:raise CoordinateError('parser: batch composition mismatch')
        return dict(official_parser_batches_verified=True,official_parser_full_source_verified=False,
                    private_source_browser_network_disabled=True,official_browser_authenticated=False,
                    body_count=whole.body_count,batches=len(parts),official_parser_source_nodes=count,
                    official_parser_target_present=at_start,model_segments_reconstructed=True)
    except CoordinateError:
        raise
    except Exception:
        raise CoordinateError('parser: comparison unavailable') from None


@contextmanager
def offline_parser():
    """Load public code without credentials, then sever all network access."""
    from playwright.sync_api import sync_playwright
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chrome", headless=True)
        context = None
        try:
            context = browser.new_context(service_workers="block")
            def public_only(route):
                request = route.request
                url = urlsplit(request.url)
                if (request.method == "GET" and url.scheme == "https" and not url.username
                        and url.hostname in ("weread.qq.com", "cdn.weread.qq.com")):
                    route.continue_()
                else:
                    route.abort()
            context.route("**/*", public_only)
            context.route_web_socket("**/*", lambda websocket: websocket.close())
            context.add_init_script("(" + CAPTURE_REQUIRE + ")()")
            page = context.new_page()
            page.set_default_timeout(45000)
            page.goto(PUBLIC_READER, wait_until="networkidle", timeout=45000)
            context.route("**/*", lambda route: route.abort())
            context.set_offline(True)
            if any(cookie["name"] in ("wr_vid", "wr_skey", "wr_rt") for cookie in context.cookies()):
                raise CoordinateError("parser: unexpectedly authenticated")
            yield page,browser.version
        finally:
            try:
                if context is not None:context.close()
            finally:browser.close()


def verify_source(raw, target_co, lua_command=None, *, allow_multiple_bodies=False):
    try:
        valid = isinstance(raw, str) and len(raw.encode("utf-8")) <= MAX_PRIVATE_BYTES
    except UnicodeError:
        valid = False
    if (not valid or type(target_co) is not int or target_co < 0 or type(allow_multiple_bodies) is not bool
            or allow_multiple_bodies and lua_command is not None):
        raise CoordinateError("parser: invalid or oversized private comparison")
    try:
        with offline_parser() as (page,version):
            rows = page.evaluate(PARSE_SOURCES, [raw])
            if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], list):
                raise CoordinateError("parser: contract changed")
            model = FilteredSource(raw,allow_multiple_bodies=allow_multiple_bodies)
            statistics = {}
            count = check_parser_rows(raw, rows[0], statistics=statistics, model=model)
            lua = check_lua(lua_command, [raw], rows, targets=[target_co]) if lua_command else {}
            return dict(official_parser_verified=True, official_parser_source_nodes=count,
                        official_parser_generated_break_marker_nodes=statistics.get("generated_break_marker_nodes", 0),
                        official_parser_target_present=any(row.get("co") == target_co for row in rows[0]),
                        private_source_browser_network_disabled=True, official_browser_authenticated=False,
                        official_browser_version=version, **lua)
    except CoordinateError:
        raise
    except Exception:
        raise CoordinateError("parser: comparison unavailable") from None
