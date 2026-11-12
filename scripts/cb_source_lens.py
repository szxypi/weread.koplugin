"""Diagnostic coordinate lenses only; neither model grants a cloud write."""
from html.parser import HTMLParser
from html import unescape
from verify_source_coordinates import SourceText,boundaries,CoordinateError,FilteredSource


class RawText(HTMLParser):
    """Visible text with original XHTML spans, before any tag filtering."""
    position=SourceText.position
    handle_data=SourceText.handle_data
    entity=SourceText.entity
    handle_entityref=SourceText.handle_entityref
    handle_charref=SourceText.handle_charref
    locate=SourceText.locate
    def __init__(self,raw):
        import re
        super().__init__(convert_charrefs=False)
        self.raw,self.offsets=boundaries(raw);self.line_starts=[0]+[m.end() for m in re.finditer('\n',raw)]
        self.body=False;self.suppressed=[];self.characters=[];self.starts=[];self.ends=[];self.bodies=0
        self.feed(raw);self.close()
        if self.body or not 1<=self.bodies<=256:raise CoordinateError('source: complete body required')
    def handle_starttag(self,tag,attrs):
        if tag=='body':
            if self.body:raise CoordinateError('source: nested bodies')
            self.body=True;self.bodies+=1
        if self.body and tag in ('script','style'):self.suppressed.append(tag)
    def handle_startendtag(self,tag,attrs):
        if tag=='body':raise CoordinateError('source: complete body required')
    def handle_endtag(self,tag):
        if tag=='body':
            if not self.body:raise CoordinateError('source: unmatched body')
            self.body=False
        if self.suppressed and self.suppressed[-1]==tag:self.suppressed.pop()


def analyze(model,co,summary):
    out=dict(visible_boundary=False,context_unique=False,summary_unique=False,summary_at_offset=False,
             summary_contains_offset=False,offset_at_summary_end=False,summary_before_offset=False,summary_after_offset=False,decoded_summary_unique=False)
    visible=[i for i,c in enumerate(model.characters) if not c.isspace()]
    at=[n for n,i in enumerate(visible) if model.starts[i]==co]
    if len(at)==1:
        index=at[0];out['visible_boundary']=True
        for width in (24,48,96,192):
            first,last=max(0,index-width),min(len(visible),index+width)
            quote=''.join(model.characters[i] for i in visible[first:last])
            try:
                if model.locate(quote)[0]==model.starts[visible[first]]:out['context_unique']=True;break
            except CoordinateError:pass
        normal=''.join(c for c in summary if not c.isspace())
        out['summary_at_offset']=bool(normal) and ''.join(model.characters[i] for i in visible[index:index+len(normal)])==normal
    if not summary:return out
    try:
        first,last=model.locate(summary);out.update(summary_unique=True,summary_contains_offset=first<=co<last,
             offset_at_summary_end=co==last,summary_before_offset=last<=co,summary_after_offset=first>co)
    except CoordinateError:pass
    try:model.locate(unescape(summary));out['decoded_summary_unique']=True
    except CoordinateError:pass
    return out


def compare(raw,co,summary):
    filtered,original=FilteredSource(raw,allow_multiple_bodies=True),RawText(raw)
    units=dict(plain_utf16=False,plain_scalars=False,nonspace_utf16=False,nonspace_scalars=False,body_relative=False,first_text_relative=False)
    try:
        start,_end=original.locate(summary);indices=[i for i,n in enumerate(original.starts) if n==start]
        if len(indices)==1:
            prefix=''.join(original.characters[:indices[0]]);flat=''.join(c for c in prefix if not c.isspace())
            units.update(plain_utf16=len(prefix.encode('utf-16-le'))//2==co,plain_scalars=len(prefix)==co,
                         nonspace_utf16=len(flat.encode('utf-16-le'))//2==co,nonspace_scalars=len(flat)==co)
            body=raw.find('<body');body_end=raw.find('>',body)+1
            units['body_relative']=body>=0 and start==co+original.offsets[body_end]
            units['first_text_relative']=bool(original.starts) and start==co+original.starts[0]
    except CoordinateError:pass
    names=('data-wr-co','data-wr-id','data-wr-bd','data-wr-serial-number','data-wr-type')
    return dict(filtered=analyze(filtered,co,summary),raw=analyze(original,co,summary),candidate_units=units,
                declared_coordinates={name:name in raw for name in names},summary_scalars=len(summary),
                summary_has_markup='<' in summary and '>' in summary,summary_has_entities=unescape(summary)!=summary)
