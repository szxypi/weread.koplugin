"""Build a private, original-only chapter fixture from one unique real paragraph.

The result is used only in an isolated in-memory test profile. It is not a
replacement for the source book and is never printed or persisted as evidence.
"""
from collections import Counter
from html import escape
from html.parser import HTMLParser


class Paragraphs(HTMLParser):
    VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.current = None
        self.values = []

    def handle_starttag(self, tag, attrs):
        translated = any(value for _name, value in self.stack) or 'wr-translation' in (dict(attrs).get('class') or '').split()
        if self.current is not None:
            self.current['simple'] = False
        elif tag == 'p' and not translated and any(name == 'body' for name, _value in self.stack):
            self.current = {'depth': len(self.stack), 'simple': True, 'text': []}
        if tag not in self.VOID:
            self.stack.append((tag, translated))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID:
            self.handle_endtag(tag)

    def handle_data(self, value):
        if self.current is not None:
            self.current['text'].append(value)

    def handle_endtag(self, tag):
        found = next((i for i in range(len(self.stack)-1, -1, -1) if self.stack[i][0] == tag), None)
        if found is None:
            return
        if self.current is not None and tag == 'p' and found == self.current['depth']:
            if self.current['simple']:
                self.values.append(''.join(self.current['text']))
            self.current = None
        del self.stack[found:]


def original_excerpt(source):
    if not isinstance(source, str) or not 1 <= len(source.encode()) <= 200 * 1024:
        raise ValueError('translation_excerpt/source')
    parser = Paragraphs()
    parser.feed(source)
    parser.close()
    counts = Counter(parser.values)
    for value in reversed(parser.values):
        if (counts[value] == 1 and 32 <= len(value) <= 4096 and value.strip()
                and not any(ord(c) < 32 and c not in '\t\n\r' or ord(c) == 127 for c in value)):
            return '<html><body><p>' + escape(value, quote=False) + '</p></body></html>'
    raise ValueError('translation_excerpt/no_unique_paragraph')
