"""Memory-only comparison with the current official, anonymously loaded parser.

The private source is supplied only after the fresh browser is offline and
all WebSockets/HTTP are blocked. No account cookies enter the browser, and no
private source, target value, DOM or screenshot is returned or saved.
"""
from urllib.parse import urlsplit

from verify_source_coordinates import (CAPTURE_REQUIRE, PARSE_SOURCES, CoordinateError,
                                       FilteredSource, check_lua, check_parser_rows)

PUBLIC_READER = "https://weread.qq.com/web/reader/b4332510813abc34eg014159"
MAX_PRIVATE_BYTES = 256 * 1024


def verify_source(raw, target_co, lua_command=None):
    try:
        valid = isinstance(raw, str) and len(raw.encode("utf-8")) <= MAX_PRIVATE_BYTES
    except UnicodeError:
        valid = False
    if not valid or type(target_co) is not int or target_co < 0:
        raise CoordinateError("parser: invalid or oversized private comparison")
    try:
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
                rows = page.evaluate(PARSE_SOURCES, [raw])
                if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], list):
                    raise CoordinateError("parser: contract changed")
                model = FilteredSource(raw)
                statistics = {}
                count = check_parser_rows(raw, rows[0], statistics=statistics, model=model)
                lua = check_lua(lua_command, [raw], rows, targets=[target_co]) if lua_command else {}
                return dict(official_parser_verified=True, official_parser_source_nodes=count,
                            official_parser_generated_break_marker_nodes=statistics.get("generated_break_marker_nodes", 0),
                            official_parser_target_present=any(row.get("co") == target_co for row in rows[0]),
                            private_source_browser_network_disabled=True, official_browser_authenticated=False,
                            official_browser_version=browser.version, **lua)
            finally:
                try:
                    if context is not None:
                        context.close()
                finally:
                    browser.close()
    except CoordinateError:
        raise
    except Exception:
        raise CoordinateError("parser: comparison unavailable") from None
