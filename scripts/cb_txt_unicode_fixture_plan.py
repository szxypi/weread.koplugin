"""Bind an owned TXT fixture to both boundaries of one non-BMP scalar."""
from cb_txt_initial_fixture_plan import plan as ordinary_plan
from txt_coordinates import PlainSource
from verify_source_coordinates import CoordinateError

CONTEXT='Unique emoji boundary Alpha😀Beta and following text.'
EMOJI='😀'


def plan(book,sample,**kwargs):
    result=ordinary_plan(book,sample,**kwargs)
    raw=sample['source']
    if raw.count(CONTEXT)!=1 or raw.count(EMOJI)!=1:raise ValueError('cb_txt_unicode/source')
    model=PlainSource(raw);model.locate(CONTEXT)
    index=raw.index(CONTEXT)+CONTEXT.index(EMOJI)
    first,following=model.starts[index],model.ends[index]
    if following!=first+2 or model.excerpt(first,1)['text']!=EMOJI:
        raise ValueError('cb_txt_unicode/boundary')
    try:
        model.excerpt(first+1,1)
    except CoordinateError:
        pass
    else:
        raise ValueError('cb_txt_unicode/surrogate')
    if model.excerpt(following,1)['text']!='B':raise ValueError('cb_txt_unicode/boundary')
    result.update(first=first,following=following)
    return result
