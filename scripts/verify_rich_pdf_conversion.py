"""Inspect only the newly uploaded self-authored rich PDF's converted source in memory."""
from check_owner_full_book import Images
from fetch_weread_epub import decode_content_shards
from secure_weread_session import SessionStore
from verify_cb_full_reading import CbFullReadingProbe
from verify_cb_progress import cb_id,cb_ids
from verify_cb_reading import BASE,CbReadingProbe
from verify_pdf_page_mapping import BodyText
from verify_translation_preflight import save_refreshed_web_session

MARKERS=('Mixed PDF fixture: page one','LEFT COLUMN START','Left column second sentence.',
         'RIGHT COLUMN START','Right column second sentence.','Illustration follows:',
         'IMAGE CAPTION: checkerboard image.','Page one trailing paragraph.',
         'Mixed PDF fixture: page two','Page two first paragraph.','SECOND IMAGE CAPTION',
         'Page two final paragraph.')


def project(source):
    if not isinstance(source,str) or len(source)>2*1024*1024:raise ValueError('rich_pdf/source')
    parser=BodyText();parser.feed(source);text=' '.join(''.join(parser.parts).split())
    images=Images();images.feed(source)
    return {'counts':[text.count(marker) for marker in MARKERS],
            'positions':[text.find(marker) for marker in MARKERS],
            'image_references':len(images.sources)}


def summarize(rows):
    if (not isinstance(rows,list) or not 1<=len(rows)<=4 or any(not isinstance(r,dict)
        or len(r.get('counts',[]))!=len(MARKERS) or len(r.get('positions',[]))!=len(MARKERS)
        or any(type(n) is not int or n<0 for n in r['counts'])
        or any(type(n) is not int or n< -1 for n in r['positions'])
        or type(r.get('image_references')) is not int or r['image_references']<0 for r in rows)):
        raise ValueError('rich_pdf/projection')
    counts=[sum(row['counts'][i] for row in rows) for i in range(len(MARKERS))]
    positions=[]
    for index,count in enumerate(counts):
        found=[(chapter,row['positions'][index]) for chapter,row in enumerate(rows) if row['positions'][index]>=0]
        positions.append(found[0] if count==1 and len(found)==1 else None)
    def before(a,b):return positions[a] is not None and positions[b] is not None and positions[a]<positions[b]
    return {'all_text_markers_once':all(n==1 for n in counts),
            'left_column_order_preserved':before(1,2),'right_column_order_preserved':before(3,4),
            'page_order_preserved':before(0,8),'captions_present':counts[6]==counts[10]==1,
            'image_references':sum(row['image_references'] for row in rows),
            'converted_chapters_checked':len(rows)}


class RichProbe(CbFullReadingProbe):
    MAX_CHAPTERS=4
    MAX_TOTAL_BYTES=4*1024*1024
    def __init__(self):
        super().__init__(interval=1);self.projected=[];self._parts={}
    def request(self,*args,**kwargs):
        result=super().request(*args,**kwargs);stage=args[0]
        if stage=='e_0':self._parts={'e_0':result}
        elif stage=='e_1':self._parts['e_1']=result
        elif stage=='e_3':
            self._parts['e_3']=result
            raw=decode_content_shards(self._parts['e_0'],self._parts['e_1'],self._parts['e_3'])
            self.projected.append(project(raw));self._parts.clear()
        return result


def verify(target):
    if not cb_id(target):raise ValueError('rich_pdf/target')
    store=SessionStore();saved=store.load();owner=saved['vid'];web=full=None
    try:
        web=CbReadingProbe();web.vid=owner;web.allowed={target}
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();ids=cb_ids(web.request('shelf',BASE+'/web/shelf/sync'))
        if target not in ids:raise ValueError('rich_pdf/missing')
        sample=web.inspect(target);web.verify_account()
        if (sample['book_id']!=target or sample['source_format']!='web_xhtml'
            or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
            or not all(v is True for v in web.last_checks.values())):raise ValueError('rich_pdf/source')
        rows=[project(sample['source'])];count=len(sample['chapters'])
        save_refreshed_web_session(store,saved,web);web.samples.clear();web.close();web=None
        if 2<=count<=4:
            saved.clear();saved=store.load()
            if saved['vid']!=owner:raise ValueError('rich_pdf/owner_changed')
            full=RichProbe();full.vid=owner
            for key,value in saved['cookies'].items():full.set_cookie(key,value)
            full.verify_account();full.prepare(ids.index(target)+1,expected_book_id=target);full.verify_account()
            if (set(full.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                or not all(v is True for v in full.last_checks.values())):raise ValueError('rich_pdf/changed')
            rows=full.projected;save_refreshed_web_session(store,saved,full)
        elif count!=1:raise ValueError('rich_pdf/chapter_limit')
        return dict(result='RICH_PDF_SOURCE_INSPECTED',target_bound=True,cloud_position_unchanged=True,
                    account_data_writes=0,authentication_posts=0,**summarize(rows))
    finally:
        if web:web.samples.clear();web.close()
        if full:full.samples.clear();full.manifest.clear();full.projected.clear();full._parts.clear();full.close()
        saved.clear()
