"""Independent raw-Unicode heat-map range text reference; no network or files.

These source-HTML rune ranges are separate from Web Reader's filtered UTF-16
progress positions. HTMLParser supplies token boundaries instead of the Lua
scanner, and partial entity references are never interpreted as full text.
"""
import hashlib
from html import unescape
from html.parser import HTMLParser
import re


class SourceQuotes(HTMLParser):
    def __init__(self, raw, *, body_only=False):
        super().__init__(convert_charrefs=False)
        if not isinstance(raw, str) or not 0 < len(raw.encode()) <= 2*1024*1024:
            raise ValueError('annotation_source_size')
        self.raw = raw.removeprefix('\ufeff')
        self.body_only, self.in_body = body_only is True, False
        self.lines = [0]+[match.end() for match in re.finditer('\n', self.raw)]
        self.spans, self.suppressed = [], []
        self.feed(self.raw); self.close()

    def at(self):
        line, column = self.getpos()
        return self.lines[line-1]+column

    def handle_starttag(self, tag, attrs):
        if tag == 'body': self.in_body = True
        if tag in ('script', 'style'): self.suppressed.append(tag)

    def handle_endtag(self, tag):
        if tag == 'body': self.in_body = False
        if self.suppressed and self.suppressed[-1] == tag: self.suppressed.pop()

    def handle_data(self, data):
        if not self.suppressed and (not self.body_only or self.in_body):
            start = self.at()
            if self.raw[start:start+len(data)] != data: raise ValueError('annotation_source_token')
            self.spans.append((start, start+len(data), data, False))

    def entity(self, value):
        if self.suppressed or self.body_only and not self.in_body: return
        start = self.at()
        if self.raw[start:start+len(value)] != value: raise ValueError('annotation_source_entity')
        self.spans.append((start, start+len(value), value, True))

    def handle_entityref(self, name): self.entity('&'+name+';')
    def handle_charref(self, name): self.entity('&#'+name+';')

    def quote(self, marker):
        if not isinstance(marker, str) or not re.fullmatch(r'[0-9]+-[0-9]+', marker):
            return ''
        first, last = map(int, marker.split('-'))
        if not 0 <= first < last <= len(self.raw): return ''
        parts = []
        for start, stop, text, entity in self.spans:
            if start < last and stop > first:
                left, right = max(first, start), min(last, stop)
                if entity and (left != start or right != stop): return ''
                part = text[left-start:right-start]
                # Match the conservative no-cut-entity contract even for a
                # literal bare ampersand which HTMLParser leaves as data.
                if re.search(r'&[^;]*$', part) or re.search(r'&[^;]*$', text[:left-start]): return ''
                parts.append(unescape(part))
        return ''.join(parts)

    def digest(self, ranges):
        parts = []
        for marker in sorted(ranges):
            for text in (marker, self.quote(marker)):
                raw = text.encode(); parts.append(str(len(raw)).encode()+b':'+raw)
        return hashlib.sha256(b''.join(parts)).hexdigest()
