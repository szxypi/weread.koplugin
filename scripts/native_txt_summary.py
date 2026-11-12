"""Slide an observed TXT summary once, retaining its known internal whitespace.

This is a bounded experiment planner, not a general summary normalizer.
Unknown whitespace at either new boundary is deliberately not inferred.
"""
import unicodedata
from txt_coordinates import PlainSource
from txt_cloud_position import anchor


def prepare(raw,plan):
    original=plan['baseline'];co=original['chapter_offset'];observed=original['summary']
    if (plan['basis']!='raw_txt_utf16' or not plan['summary_unique_start_matches'] or not isinstance(observed,str)
            or not 2<=len(observed)<=512 or observed[0].isspace() or observed[-1].isspace()):raise ValueError('txt_summary/source')
    model=PlainSource(raw);anchor(model,co)
    try:index=model.starts.index(co);visible_index=model.visible.index(index)
    except ValueError:raise ValueError('txt_summary/boundary') from None
    if (not plan.get('target') or plan['target']['chapter_offset']!=co+1 or index+1>=len(model.starts)
            or model.starts[index+1]!=co+1 or observed[0]!=raw[index]):raise ValueError('txt_summary/adjacent')
    anchor(model,co+1)
    clean=''.join(observed.split());last=visible_index+len(clean)-1
    if len(clean)<2 or last>=len(model.visible) or model.locate(observed)[0]!=co:raise ValueError('txt_summary/source')
    end=model.visible[last]+1
    if end>=len(raw) or raw[end].isspace() or unicodedata.category(raw[end])[0] in ('M','C'):raise ValueError('txt_summary/new_boundary')
    text=observed[1:]+raw[end]
    if model.locate(text)[0]!=co+1:raise ValueError('txt_summary/target')
    target=dict(original,chapter_offset=co+1,summary=text)
    return dict(baseline=dict(original),target=target,method='slide_observed_window_once',
        preserved_internal_whitespace=True,full_summary_scalars=len(text))
