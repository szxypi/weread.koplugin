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


class SegmentedText(RawText):
    """Associate visible characters with their body and nearest text block.

    These are diagnostic labels, not verified WeRead coordinate semantics.
    """
    BLOCKS={'p','div','section','article','li','blockquote','h1','h2','h3','h4','h5','h6','td','th','pre'}
    def __init__(self,raw):
        self.body_ids=[];self.block_ids=[];self._next_block=0;self._blocks=[]
        super().__init__(raw)
    def handle_starttag(self,tag,attrs):
        super().handle_starttag(tag,attrs)
        if self.body and tag in self.BLOCKS:
            self._next_block+=1;self._blocks.append((tag,self._next_block))
    def handle_endtag(self,tag):
        if self.body and self._blocks and self._blocks[-1][0]==tag:self._blocks.pop()
        super().handle_endtag(tag)
        if tag=='body':self._blocks.clear()
    def _record(self,start):
        count=len(self.characters)-start
        self.body_ids.extend([self.bodies]*count)
        self.block_ids.extend([tuple(item[1] for item in self._blocks)]*count)
    def handle_data(self,data):
        start=len(self.characters);super().handle_data(data);self._record(start)
    def entity(self,encoded):
        start=len(self.characters);super().entity(encoded);self._record(start)


def segmented_units(model,co,summary):
    result={name:False for name in ('body_utf16','body_scalars','body_nonspace_utf16',
            'body_nonspace_scalars','block_utf16','block_scalars','block_nonspace_utf16',
            'block_nonspace_scalars','plain_utf8','body_utf8','block_utf8')}
    try:
        start,_=model.locate(summary)
        indices=[i for i,n in enumerate(model.starts) if n==start]
        if len(indices)!=1:return result
        index=indices[0]
        def matches(prefix,scope):
            flat=''.join(c for c in prefix if not c.isspace())
            result[scope+'_utf16']=len(prefix.encode('utf-16-le'))//2==co
            result[scope+'_scalars']=len(prefix)==co
            result[scope+'_nonspace_utf16']=len(flat.encode('utf-16-le'))//2==co
            result[scope+'_nonspace_scalars']=len(flat)==co
            result[scope+'_utf8']=len(prefix.encode('utf-8'))==co
        result['plain_utf8']=len(''.join(model.characters[:index]).encode('utf-8'))==co
        body=model.body_ids[index]
        matches(''.join(c for i,c in enumerate(model.characters[:index]) if model.body_ids[i]==body),'body')
        blocks=model.block_ids[index]
        if blocks:
            block=blocks[-1]
            matches(''.join(c for i,c in enumerate(model.characters[:index]) if block in model.block_ids[i]),'block')
    except CoordinateError:pass
    return result


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
    filtered,original=FilteredSource(raw,allow_multiple_bodies=True),SegmentedText(raw)
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
                segmented_units=segmented_units(original,co,summary),offset_zero=co==0,
                declared_coordinates={name:name in raw for name in names},summary_scalars=len(summary),
                summary_has_markup='<' in summary and '>' in summary,summary_has_entities=unescape(summary)!=summary)
