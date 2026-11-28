#!/usr/bin/env python3
"""Probe public bookstore contracts before integrating their undocumented APIs.

No account, cookies or API key are read. The optional report contains only
endpoint/shape/count metadata, never book content or response bodies.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def categories(data):
    if not isinstance(data, dict) or not isinstance(data.get("data"), list):
        raise ValueError("missing category data array")
    found = []

    def visit(rows, depth=0):
        if depth > 8:
            return
        for row in rows:
            if not isinstance(row, dict):
                continue
            if isinstance(row.get("categories"), list):
                visit(row["categories"], depth + 1)
                continue
            cid = str(row.get("CategoryId", row.get("categoryId", "")))
            if (not re.fullmatch(r"[A-Za-z0-9_-]+", cid) or not row.get("title")
                    or row.get("type") is not None and str(row["type"]) != "0"):
                continue
            found.append((cid, not cid.isdigit()))
            if isinstance(row.get("sublist"), list):
                visit(row["sublist"], depth + 1)

    visit(data["data"])
    if not found:
        raise ValueError("no valid text-book categories")
    return found


def page(data):
    if not isinstance(data, dict) or not isinstance(data.get("books"), list):
        raise ValueError("missing category books array")
    ids, cursors = [], []
    for row in data["books"]:
        if not isinstance(row, dict):
            raise ValueError("invalid book row")
        book = row
        for _i in range(4):
            if isinstance(book.get("bookInfo"), dict):
                book = book["bookInfo"]
            elif isinstance(book.get("book"), dict):
                book = book["book"]
            else:
                break
        if not book.get("bookId"):
            raise ValueError("missing book ID")
        ids.append(str(book["bookId"]))
        cursor = row.get("searchIdx", row.get("idx", book.get("searchIdx", book.get("idx"))))
        if isinstance(cursor, (int, float)) and not isinstance(cursor, bool):
            cursors.append(cursor)
    return ids, max(cursors, default=0)


def verify():
    report = dict(checked_at=datetime.now(timezone.utc).isoformat(), authenticated=False, requests=[])

    def fetch(path):
        record = dict(path=path)
        report["requests"].append(record)
        request = Request("https://weread.qq.com" + path, headers={
            "User-Agent": "Mozilla/5.0", "Accept": "application/json",
            "Referer": "https://weread.qq.com/web/category/all",
        })
        try:
            with urlopen(request, timeout=15) as response:
                record["status"] = response.status
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise ValueError("response exceeds probe size limit")
                data = json.loads(raw)
                record["keys"] = sorted(data) if isinstance(data, dict) else []
                return data, record
        except HTTPError as exc:
            record["status"] = exc.code
            raise ValueError(f"HTTP {exc.code}") from None
        except URLError:
            raise ValueError("connection or TLS failed") from None
        except TimeoutError:
            raise ValueError("request timed out") from None

    try:
        data, record = fetch("/web/categories?rank=1&synckey=0")
        entries = categories(data)
        record["rank_count"] = sum(rank for _, rank in entries)
        record["category_count"] = sum(not rank for _, rank in entries)
        for rank in (True, False):
            cid = next(cid for cid, is_rank in entries if is_rank == rank)
            path = f"/web/bookListInCategory/{cid}?rank={int(rank)}&maxIndex="
            data, record = fetch(path + "0")
            first_ids, cursor = page(data)
            record.update(book_count=len(first_ids), next_cursor=cursor, has_more=data.get("hasMore"))
            if not first_ids or cursor <= 0:
                raise ValueError("no usable initial category page cursor")
            data, record = fetch(path + str(cursor))
            next_ids, next_cursor = page(data)
            record.update(book_count=len(next_ids), next_cursor=next_cursor, has_more=data.get("hasMore"))
            if next_ids and (next_cursor <= cursor or set(first_ids) == set(next_ids)):
                raise ValueError("category continuation did not advance")
        report["result"] = "PASS"
    except (ValueError, StopIteration) as exc:
        report.update(result="UNVERIFIED", reason=str(exc) or "missing ranking or category")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="write a new metadata-only JSON report")
    args = parser.parse_args()
    result = verify()
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as out:
            out.write(text)
    print(text, end="")
    raise SystemExit(0 if result["result"] == "PASS" else 1)


if __name__ == "__main__":
    main()
