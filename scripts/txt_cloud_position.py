"""Read-only TXT cloud-point planning; does not confer an upload grant."""
import unicodedata
from source_upload_candidate import identifier,chapter_index
from txt_coordinates import PlainSource
from verify_reader_progress import project as project_progress,find_node
from verify_position_roundtrip import same_position
from verify_source_coordinates import CoordinateError


def anchor(model,offset):
    if type(offset) is not int:raise ValueError('txt_cloud/offset')
    visible=[i for i in model.visible if model.starts[i]==offset]
    if len(visible)!=1:raise ValueError('txt_cloud/boundary')
    at=model.visible.index(visible[0])
    for width in (24,48,96,192):
        first,last=max(0,at-width),min(len(model.flat),at+width)
        text=model.flat[first:last]
        try:
            if model.locate(text)[0]!=model.starts[model.visible[first]]:continue
            if model.locate_point(text,at-first)==offset:return text,at-first
        except CoordinateError:pass
    raise ValueError('txt_cloud/ambiguous')


def prepare(raw,progress,context,chapters,book_id):
    book_id=identifier(book_id);baseline=project_progress(progress,book_id)
    if not baseline['has_chapter_offset'] or context.get('book_id')!=book_id or not context.get('psvts'):raise ValueError('txt_cloud/context')
    uid=identifier(baseline.get('chapter_uid'));baseline['chapter_uid']=uid
    if chapter_index(chapters,uid)!=baseline['chapter_idx']:raise ValueError('txt_cloud/index')
    embedded=project_progress(context.get('progress'),book_id)
    if not same_position(baseline,embedded):raise ValueError('txt_cloud/changed')
    model=PlainSource(raw);co=baseline['chapter_offset'];text,point=anchor(model,co)
    index=model.starts.index(co);tail=''.join(model.characters[index:index+20])
    node=find_node(progress,book_id);summary=node.get('summary')
    summary_matches=isinstance(summary,str) and bool(summary) and raw[index:].startswith(summary)
    target=None
    if index+1<len(model.characters) and model.starts[index+1]==co+1 and all(not c.isspace() and unicodedata.category(c)[0] not in ('M','C') for c in model.characters[index:index+2]):
        try:
            anchor(model,co+1)
            target=dict(baseline,chapter_offset=co+1,summary=''.join(model.characters[index+1:index+21]))
        except ValueError:pass
    original_preserved=isinstance(summary,str) and len(summary)<=20
    baseline['summary']=summary if original_preserved else tail
    summary_start=summary_end=False
    if isinstance(summary,str) and summary:
        try:
            first,last=model.locate(summary);summary_start=first==co;summary_end=last==co
        except CoordinateError:pass
    return dict(book_id=book_id,baseline=baseline,target=target,context=context,anchor=dict(text=text,point_offset=point),
        basis='raw_txt_utf16',source_summary_matches=summary_matches,original_summary_preserved=original_preserved,source_summary_present=isinstance(summary,str),
        source_summary_nonempty=isinstance(summary,str) and bool(summary),source_summary_scalars=len(summary) if isinstance(summary,str) else 0,
        source_summary_nonspace_scalars=len(''.join(summary.split())) if isinstance(summary,str) else 0,summary_unique_start_matches=summary_start,summary_unique_end_matches=summary_end,
        existing_wire_preflight_compatible=original_preserved and target is not None and float(baseline['raw_percent']).is_integer(),
        source_has_bom=raw.startswith('\ufeff'),source_crlf_pairs=raw.count('\r\n'),source_nonbmp_scalars=sum(ord(c)>65535 for c in raw),
        cloud_coordinate_semantics_verified=False,upload_verified=False)
