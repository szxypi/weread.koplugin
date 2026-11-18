"""Plan one first position in the separately uploaded synthetic TXT fixture.

This has no network or storage access and grants no authority to send. The raw
UTF-16 coordinate is local evidence until an independent server readback.
"""
import time
import unicodedata

from fetch_weread_epub import weread_e
from txt_coordinates import PlainSource
from verify_cb_progress import cb_id
from verify_cb_txt_fixture import MARKER
from verify_position_roundtrip import DEFAULT_TOKEN
from verify_reader_progress import project as project_progress
from verify_source_coordinates import CoordinateError


def plan(book, sample, *, now=time.time):
    if (not cb_id(book) or not isinstance(sample, dict) or sample.get('book_id') != book
            or sample.get('source_format') != 'web_txt'
            or sample.get('baseline') != dict(chapter='0', offset=0, percent=0)):
        raise ValueError('cb_txt_initial/scope')
    raw, chapter = sample.get('source'), sample.get('chapter_uid')
    rows, context = sample.get('chapters'), sample.get('context')
    if (not isinstance(raw, str) or not isinstance(chapter, str) or not chapter.isdigit()
            or not isinstance(rows, list) or not isinstance(context, dict)
            or context.get('book_id') != book or not context.get('psvts')):
        raise ValueError('cb_txt_initial/source')
    selected = [row for row in rows if isinstance(row, dict) and str(row.get('chapterUid')) == chapter]
    if len(selected) != 1: raise ValueError('cb_txt_initial/chapter')
    index = selected[0].get('chapterIdx')
    if type(index) is not int or not 0 <= index <= 1000000: raise ValueError('cb_txt_initial/index')
    embedded = project_progress(context.get('progress'), book)
    if (str(embedded.get('chapter_uid')) != '0' or not embedded['has_chapter_offset']
            or embedded['chapter_offset'] != 0 or embedded['raw_percent'] != 0):
        raise ValueError('cb_txt_initial/context_changed')
    try:
        model = PlainSource(raw)
        model.locate(MARKER)  # Refuse ambiguous or missing fixture identity.
        anchor = model.locate(MARKER[4:])[0]
    except CoordinateError:
        raise ValueError('cb_txt_initial/source') from None
    start = raw.index(MARKER)
    if raw.find(MARKER, start + 1) != -1: raise ValueError('cb_txt_initial/ambiguous')
    # A nonzero, adjacent scalar boundary tests raw offsets without crossing a
    # space, surrogate pair, combining mark or control character.
    scalar = start + 4
    if (scalar + 1 >= len(raw) or any(char.isspace() or unicodedata.category(char)[0] in ('M', 'C')
                                      for char in raw[scalar:scalar + 2])):
        raise ValueError('cb_txt_initial/boundary')
    first, following = model.starts[scalar:scalar + 2]
    if first <= 0 or following != first + 1 or model.ends[scalar] != following:
        raise ValueError('cb_txt_initial/boundary')
    if anchor != first: raise ValueError('cb_txt_initial/anchor')
    pc = context.get('pclts')
    if pc is None or str(pc) in ('', '0'): pc = weread_e(int(now()))
    return dict(book=book, chapter=chapter, index=index, first=first, following=following, percent=1,
                psvts=context['psvts'], pclts=pc, token=context.get('token') or DEFAULT_TOKEN)
