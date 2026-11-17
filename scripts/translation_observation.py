"""Typed read-only observations; an explicit missing position is never zero progress.

No network or credentials. Actual reported counter fields and book envelope are
retained in memory for exact before/after equality.
"""
import json
from verify_reader_progress import project,find_node,identity
from native_initial_position import COUNTERS


def position(raw,book,kind):
    p=project(raw,book,kind);node=find_node(raw,book)
    keys=('chapterUid','chapter_uid','chapterIdx','chapterIndex','chapter_idx','chapterOffset','chapter_offset',
        'progress','readingProgress','percent','summary','chapterTitle','readingTime','recordReadingTime','ttsTime')
    return dict(point=p,fields={k:node[k] for k in keys if k in node})


def observation(raw,book,kind):
    """Read-only evidence only; missing progress/counters never become zeros."""
    try:node=find_node(raw,book)
    except ValueError as error:
        if str(error)!='progress_not_found':raise
        # Observed explicit unrecorded-book envelope. Do not admit arbitrary
        # empty/error responses or grant any upload/initialization capability.
        if (not isinstance(raw,dict) or set(raw)!={'bookId','book','canFreeRead','timestamp'}
                or identity(raw['bookId'])!=book or not isinstance(raw['book'],dict) or not raw['book']
                or 'bookId' in raw['book'] and identity(raw['book']['bookId'])!=book
                or type(raw['canFreeRead']) is not int or raw['canFreeRead'] not in (0,1)
                or type(raw['timestamp']) is not int or not 0<=raw['timestamp']<=2**53-1
                or len(json.dumps(raw).encode())>256*1024):raise ValueError('translation_owner/unknown_absence') from None
        counters={}
        def collect(value,path=()):
            if len(path)>8:raise ValueError('translation_owner/unknown_absence')
            if isinstance(value,dict):
                for key,item in value.items():
                    if key in COUNTERS:
                        if type(item) is not int or not 0<=item<=2**53-1:raise ValueError('translation_owner/counters')
                        counters[json.dumps(path+(key,),separators=(',',':'))]=item
                    collect(item,path+(key,))
            elif isinstance(value,list):
                for index,item in enumerate(value):collect(item,path+(index,))
        collect(raw['book'])
        return dict(position_present=False,book=raw['book'],can_free_read=raw['canFreeRead'],counters=counters)
    counters={k:node[k] for k in COUNTERS if k in node}
    if any(type(v) is not int or not 0<=v<=2**53-1 for v in counters.values()):raise ValueError('translation_owner/counters')
    return dict(position_present=True,position=position(raw,book,kind),counters=counters)
