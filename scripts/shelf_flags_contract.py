"""Shelf reading flags follow Tencent/WeChatReading skills/shelf.md.

`finished` is independent metadata, never an alias for `finishReading`.
Missing or malformed fields stay unknown rather than becoming false.
"""
FIELDS={'pinned':'isTop','private':'secret','finished':'finishReading'}


def flag(row,key):
    if not isinstance(row,dict) or key not in row: return dict(reason='missing')
    value=row[key]
    if type(value) not in (bool,int,float) or value not in (0,1): return dict(reason='invalid')
    return dict(value=bool(value))
