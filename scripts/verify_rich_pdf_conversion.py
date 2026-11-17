"""Inspect only the newly uploaded self-authored rich PDF's converted source in memory."""
from html.parser import HTMLParser
import re
from check_owner_full_book import Images
from fetch_weread_epub import decode_content_shards,decode_style_shard
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


class EmbeddedForms(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True);self.forms=0;self.style_urls=0;self.style_depth=0
    def handle_starttag(self,tag,attrs):
        if tag in ('svg','canvas','object','embed','iframe','picture'):self.forms+=1
        if tag=='style':self.style_depth+=1
        self.style_urls+=sum(len(re.findall(r'url\s*\(',value,re.I)) for name,value in attrs
                             if name=='style' and isinstance(value,str))
    def handle_endtag(self,tag):
        if tag=='style' and self.style_depth:self.style_depth-=1
    def handle_data(self,value):
        if self.style_depth:self.style_urls+=len(re.findall(r'url\s*\(',value,re.I))


def style_projection(shard):
    try:
        value=decode_style_shard(shard)
        if not isinstance(value,str) or len(value)>2*1024*1024:raise ValueError('style')
        return {'decoded':True,'url_functions':len(re.findall(r'url\s*\(',value,re.I))}
    except Exception:return {'decoded':False,'url_functions':0}


def project(source):
    if not isinstance(source,str) or len(source)>2*1024*1024:raise ValueError('rich_pdf/source')
    parser=BodyText();parser.feed(source);text=' '.join(''.join(parser.parts).split())
    images=Images();images.feed(source)
    forms=EmbeddedForms();forms.feed(source)
    return {'embedded_forms':forms.forms,'inline_css_url_functions':forms.style_urls,'style_decoded':False,'style_url_functions':0,'counts':[text.count(marker) for marker in MARKERS],
            'positions':[text.find(marker) for marker in MARKERS],
            'image_references':len(images.sources)}


def summarize(rows):
    if (not isinstance(rows,list) or not 1<=len(rows)<=4 or any(not isinstance(r,dict)
        or len(r.get('counts',[]))!=len(MARKERS) or len(r.get('positions',[]))!=len(MARKERS)
        or any(type(n) is not int or n<0 for n in r['counts'])
        or any(type(n) is not int or n< -1 for n in r['positions'])
        or any(type(r.get(k)) is not int or r[k]<0 for k in ('image_references','embedded_forms','inline_css_url_functions','style_url_functions'))
        or type(r.get('style_decoded')) is not bool for r in rows)):
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
            'embedded_form_elements':sum(row['embedded_forms'] for row in rows),
            'inline_css_url_functions':sum(row['inline_css_url_functions'] for row in rows),
            'style_shards_decoded':sum(row['style_decoded'] for row in rows),
            'style_shard_url_functions':sum(row['style_url_functions'] for row in rows),
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
        elif stage=='e_2' and self.projected:
            style=style_projection(result);self.projected[-1]['style_decoded']=style['decoded'];self.projected[-1]['style_url_functions']=style['url_functions']
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
        rows=[project(sample['source'])];style=style_projection(sample['shards'].get('e_2'))
        rows[0]['style_decoded']=style['decoded'];rows[0]['style_url_functions']=style['url_functions']
        count=len(sample['chapters']);declared_archives=sum(bool(row.get('tar')) for row in sample['chapters'] if isinstance(row,dict))
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
                    account_data_writes=0,authentication_posts=0,declared_chapter_archives=declared_archives,**summarize(rows))
    finally:
        if web:web.samples.clear();web.close()
        if full:full.samples.clear();full.manifest.clear();full.projected.clear();full._parts.clear();full.close()
        saved.clear()
