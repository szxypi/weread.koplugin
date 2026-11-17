"""Read only a newly uploaded synthetic PDF's bounded converted chapters."""
from html.parser import HTMLParser
from fetch_weread_epub import decode_content_shards
from secure_weread_session import SessionStore
from synthetic_upload_pdf import TEXT,SECOND
from verify_cb_full_reading import CbFullReadingProbe
from verify_cb_progress import cb_id,cb_ids
from verify_cb_reading import BASE,CbReadingProbe
from verify_translation_preflight import save_refreshed_web_session

MARKERS=(TEXT,'Page 1 line 45 contains self-authored text for native reading checks.',
         SECOND,'Page 2 line 45 contains self-authored text for native reading checks.')


class BodyText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True);self.skip=0;self.parts=[]
    def handle_starttag(self,tag,_attrs):
        tag=tag.lower()
        if tag in ('head','script','style'):self.skip+=1
        elif not self.skip and tag in ('p','div','br','li','h1','h2','h3'):self.parts.append(' ')
    def handle_endtag(self,tag):
        tag=tag.lower()
        if tag in ('head','script','style') and self.skip:self.skip-=1
        elif not self.skip and tag in ('p','div','li','h1','h2','h3'):self.parts.append(' ')
    def handle_data(self,text):
        if not self.skip:self.parts.append(text)


def markers(source):
    parser=BodyText();parser.feed(source);text=' '.join(''.join(parser.parts).split())
    return [text.find(value) if text.count(value)<=1 else -2 for value in MARKERS]


def ordered(rows):
    if (not isinstance(rows,list) or not rows or len(rows)>4
            or any(not isinstance(row,list) or len(row)!=len(MARKERS) or any(type(value) is not int or value < -1 for value in row) for row in rows)):
        return False
    positions=[]
    for index in range(len(MARKERS)):
        matches=[(chapter,row[index]) for chapter,row in enumerate(rows) if row[index]>=0]
        if len(matches)!=1:return False
        positions.append(matches[0])
    return positions==sorted(positions) and len(set(positions))==len(positions)


class MappingFullProbe(CbFullReadingProbe):
    MAX_CHAPTERS=4
    MAX_TOTAL_BYTES=4*1024*1024
    def __init__(self):
        super().__init__(interval=1);self.page_markers=[];self._parts={}
    def request(self,*args,**kwargs):
        result=super().request(*args,**kwargs);stage=args[0]
        if stage=='e_0':self._parts={'e_0':result}
        elif stage=='e_1':self._parts['e_1']=result
        elif stage=='e_3':
            self._parts['e_3']=result
            raw=decode_content_shards(self._parts['e_0'],self._parts['e_1'],self._parts['e_3'])
            self.page_markers.append(markers(raw));self._parts.clear()
        return result


def verify(target):
    if not cb_id(target):raise ValueError('pdf_mapping/target')
    store=SessionStore();saved=store.load();owner=saved['vid'];web=full=None
    try:
        web=CbReadingProbe();web.vid=saved['vid'];web.allowed={target}
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();ids=cb_ids(web.request('shelf',BASE+'/web/shelf/sync'))
        if target not in ids:raise ValueError('pdf_mapping/missing')
        sample=web.inspect(target);web.verify_account()
        if (sample['book_id']!=target or sample['source_format']!='web_xhtml'
                or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                or not all(v is True for v in web.last_checks.values())):
            raise ValueError('pdf_mapping/source')
        rows=[markers(sample['source'])];count=len(sample['chapters'])
        save_refreshed_web_session(store,saved,web);web.samples.clear();web.close();web=None
        if not ordered(rows) and 2<=count<=4:
            saved.clear();saved=store.load()
            if saved['vid']!=owner:raise ValueError('pdf_mapping/owner_changed')
            full=MappingFullProbe();full.vid=saved['vid']
            for key,value in saved['cookies'].items():full.set_cookie(key,value)
            full.verify_account();full.prepare(ids.index(target)+1,expected_book_id=target);full.verify_account()
            if (set(full.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                    or not all(v is True for v in full.last_checks.values())):raise ValueError('pdf_mapping/changed')
            rows=full.page_markers;save_refreshed_web_session(store,saved,full)
        if not ordered(rows):raise ValueError('pdf_mapping/unverified')
        return dict(result='PDF_PAGE_CONTENT_MAPPING_VERIFIED',original_pages=2,converted_chapters_checked=len(rows),
                    target_bound=True,original_page_markers_ordered=True,cloud_position_unchanged=True,
                    account_data_writes=0,authentication_posts=0)
    finally:
        if web:web.samples.clear();web.close()
        if full:full.samples.clear();full.manifest.clear();full.page_markers.clear();full._parts.clear();full.close()
        saved.clear()
