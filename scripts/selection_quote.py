"""Independent native source-coordinate selection -> raw-rune quote model.

Source offsets use filtered XHTML UTF-16; review ranges use raw HTML Unicode
scalars without the initial BOM. No request, persistence or write permission.
"""
import hashlib
from html import unescape
from annotation_source_quotes import SourceQuotes
from verify_source_coordinates import FilteredSource,CoordinateError


def fail(reason):raise ValueError('selection_quote/'+reason)


def normalized(value):return ''.join(c for c in value if not c.isspace())


class Selection:
    def __init__(self,raw):
        try:
            self.quotes=SourceQuotes(raw,body_only=True)
            self.filtered=FilteredSource(raw,allow_multiple_bodies=True)
        except (ValueError,UnicodeError,CoordinateError):fail('source')
        self.raw=raw;self.characters=[];self.spans=[]
        for start,end,text,entity in self.quotes.spans:
            if entity:
                if unescape(text)==text:fail('entity')
                for char in unescape(text):
                    if not char.isspace():self.characters.append(char);self.spans.append((start,end))
            else:
                for index,char in enumerate(text):
                    if not char.isspace():self.characters.append(char);self.spans.append((start+index,start+index+1))
        self.visible=[i for i,c in enumerate(self.filtered.characters) if not c.isspace()]
        self.flat=''.join(self.characters)
        if self.flat!=''.join(self.filtered.characters[i] for i in self.visible):fail('source_text')

    def boundary(self,co):
        if type(co) is not int or not 0<=co<=16*1024*1024:fail('boundary')
        candidates=set();interior=False
        # Whitespace aliases participate in ambiguity checks even though the
        # quote excludes leading/trailing layout whitespace.
        flat=0;visible=False
        for char,start,end in zip(self.filtered.characters,self.filtered.starts,self.filtered.ends):
            if co==start:
                candidates.add(flat);visible=visible or not char.isspace()
            if not char.isspace():
                if co==end:candidates.add(flat+1);visible=True
                flat+=1
            if start<co<end:interior=True
        if interior or len(candidates)!=1 or not visible:fail('boundary')
        return next(iter(candidates))

    def project(self,first,last,text):
        if not isinstance(text,str) or not 0<len(text.encode())<=4096 or any(ord(c)<32 and c not in '\t\n\r' for c in text):fail('text')
        begin,end=self.boundary(first),self.boundary(last)
        if begin>=end or end>len(self.spans) or normalized(text)!=self.flat[begin:end]:fail('selection')
        start,stop=self.spans[begin][0],self.spans[end-1][1]
        quote=self.quotes.quote(f'{start}-{stop}').strip()
        if not quote or len(quote.encode())>4096 or normalized(quote)!=self.flat[begin:end]:fail('entity')
        return dict(range=f'{start}-{stop}',abstract=quote,raw_sha256=hashlib.sha256(self.raw.encode()).hexdigest(),raw_bytes=len(self.raw.encode()))

    def from_mark(self,row):
        marker=row['range'];first,last=map(int,marker.split('-'))
        selected=[index for index,(start,end) in enumerate(self.spans) if first<=start and end<=last]
        if not selected or selected!=list(range(selected[0],selected[-1]+1)):fail('range')
        start=self.filtered.starts[self.visible[selected[0]]];end=self.filtered.ends[self.visible[selected[-1]]]
        value=self.project(start,end,row['markText'])
        if self.quotes.quote(value['range']).strip()!=row['markText'].strip():fail('quote_changed')
        return dict(first=start,last=end,text=row['markText']),value
