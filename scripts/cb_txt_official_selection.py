"""Observe one self-authored TXT selection; every attempted write is blocked.

The browser can load only the scoped reader, its source requests and public
assets. Before selecting text it is taken offline and every subsequent
request is aborted. No private browser content is exported or persisted.
"""
import base64
import re
from urllib.parse import urlsplit

from cb_official_viewport import allowed
from cb_txt_highlight_trial import TEXT
from fetch_weread_epub import reader_url_for
from secure_weread_session import COOKIE_NAMES
from verify_cb_progress import cb_id


DRAW_HOOK = r'''(() => {
  const old = CanvasRenderingContext2D.prototype.fillText;
  window.__wrSelectionDraws = [];
  CanvasRenderingContext2D.prototype.fillText = function(...args) {
    if (this.canvas.isConnected && window.__wrSelectionDraws.length < 20000) {
      const text = String(args[0]), metric = this.measureText(text), t = this.getTransform();
      window.__wrSelectionDraws.push({text, x:Number(args[1]), y:Number(args[2]),
        width:metric.width, ascent:metric.actualBoundingBoxAscent,
        rect:this.canvas.getBoundingClientRect().toJSON(),
        transform:[t.a,t.b,t.c,t.d,t.e,t.f], cw:this.canvas.width, ch:this.canvas.height});
    }
    return old.apply(this, args);
  };
})();'''

FIND_POINTS = r'''anchor => {
  const chars=Array.from(anchor).filter(c=>!(/\s/.test(c))).slice(0,8);
  const draws=(window.__wrSelectionDraws||[]).filter(v=>Array.from(v.text).length===1&&!(/\s/.test(v.text)));
  if (chars.length!==8) return null;
  for (let i=draws.length-chars.length;i>=0;i--) {
    const a=draws.slice(i,i+chars.length);
    if (!a.every((v,j)=>v.text===chars[j] && Math.abs(v.y-a[0].y)<1 && v.cw>0 && v.ch>0
        && v.rect.width>0 && v.rect.height>0)) continue;
    const point=(v,last)=>{
      const t=v.transform, dx=v.x+(last?v.width:0), dy=v.y-Math.max(3,v.ascent/2);
      return {x:v.rect.left+(t[0]*dx+t[2]*dy+t[4])*v.rect.width/v.cw,
              y:v.rect.top+(t[1]*dx+t[3]*dy+t[5])*v.rect.height/v.ch};
    };
    const start=point(a[0],false), end=point(a[a.length-1],true);
    if ([start,end].every(p=>Number.isFinite(p.x)&&Number.isFinite(p.y)&&p.x>=0&&p.x<innerWidth
        &&p.y>=0&&p.y<innerHeight) && end.x>start.x) return {start,end};
  }
  return null;
}'''


class CaptureError(ValueError):
    def __init__(self,reason,checks):
        super().__init__(reason)
        self.checks=checks


def verify_capture(sample,row):
    if not isinstance(sample,dict) or not isinstance(row,dict):raise ValueError('official_txt/scope')
    book=sample.get('book_id');uid=sample.get('chapter_uid');raw=sample.get('source')
    if (not cb_id(book) or not isinstance(uid,str) or not uid.isdigit() or not isinstance(raw,str)
            or sample.get('source_format')!='web_txt' or raw.count(TEXT)!=1 or raw.count('😀')!=1
            or raw.index('😀')>=raw.index(TEXT) or row.get('bookId')!=book
            or str(row.get('chapterUid'))!=uid or type(row.get('type')) is not int or row['type']!=1):
        raise ValueError('official_txt/scope')
    marker=row.get('range');match=re.fullmatch(r'([0-9]{1,10})-([0-9]{1,10})',marker) if isinstance(marker,str) else None
    if not match or not isinstance(row.get('markText'),str):raise ValueError('official_txt/selection')
    try:quote=base64.b64decode(row['markText'],validate=True).decode('utf-8')
    except (ValueError,UnicodeError):raise ValueError('official_txt/selection') from None
    source=raw.removeprefix('\ufeff');first,last=map(int,match.groups())
    valid=0<=first<last<=len(source)
    checks=dict(range_in_bounds=valid,quote_length_valid=3<=len(quote)<=len(TEXT),
                scalar_range_matches=valid and source[first:last]==quote,
                quote_inside_fixture=bool(quote) and quote in TEXT,quote_unique=bool(quote) and source.count(quote)==1,
                non_bmp_before_range=valid and len(source[:first].encode('utf-16-le'))//2!=first,
                utf16_range_matches=False)
    try:
        raw_utf16=source.encode('utf-16-le')
        checks['utf16_range_matches']=bool(quote) and raw_utf16[first*2:last*2].decode('utf-16-le')==quote
    except UnicodeError:pass
    if not all(checks[key] for key in ('range_in_bounds','quote_length_valid','scalar_range_matches',
                                        'quote_inside_fixture','quote_unique','non_bmp_before_range')):
        raise CaptureError('official_txt/range',checks)
    return dict(result='PASS',same_book_and_chapter=True,exact_quote_and_range=True,
                selected_from_fixture=True,non_bmp_before_selection=True,attempted_write_blocked=True)


def observe(sample,cookies,*,timeout=30000):
    book=sample.get('book_id') if isinstance(sample,dict) else None
    chapters=sample.get('chapters') if isinstance(sample,dict) else None
    if (not cb_id(book) or sample.get('source_format')!='web_txt' or not isinstance(chapters,list)
            or not isinstance(cookies,dict) or not cookies
            or any(k not in COOKIE_NAMES or not isinstance(v,str) or not v for k,v in cookies.items())):
        raise ValueError('official_txt/scope')
    ids=frozenset(str(row.get('chapterUid')) for row in chapters if isinstance(row,dict))
    if not ids or len(ids)>5000 or any(not x.isdigit() or len(x)>20 for x in ids):raise ValueError('official_txt/scope')
    from playwright.sync_api import sync_playwright
    with sync_playwright() as playwright:
        browser=playwright.chromium.launch(channel='chrome',headless=True);context=None
        try:
            context=browser.new_context(service_workers='block',viewport={'width':1024,'height':768})
            context.add_cookies([dict(name=k,value=v,domain='.weread.qq.com',path='/',secure=True) for k,v in cookies.items()])
            total=0
            def gate(route):
                nonlocal total
                total+=1;request=route.request
                if total<=250 and allowed(request.method,request.url,request.post_data,book,ids):route.continue_()
                else:route.abort()
            context.route('**/*',gate);context.route_web_socket('**/*',lambda ws:ws.close())
            page=context.new_page();page.add_init_script(DRAW_HOOK)
            page.goto(reader_url_for(book),wait_until='domcontentloaded',timeout=timeout);page.wait_for_timeout(6000)
            captured=[]
            def trap(route):
                request=route.request;url=urlsplit(request.url)
                if (request.method=='POST' and url.scheme=='https' and url.hostname=='weread.qq.com'
                        and url.path=='/web/book/addBookmark' and len(captured)==0):
                    try:captured.append(request.post_data_json)
                    except Exception:captured.append(None)
                route.abort()
            context.route('**/*',trap);context.set_offline(True)
            points=page.evaluate(FIND_POINTS,TEXT)
            if not isinstance(points,dict):raise ValueError('official_txt/not_visible')
            a,b=points['start'],points['end'];page.mouse.move(a['x'],a['y']);page.mouse.down()
            page.mouse.move(b['x'],b['y'],steps=12);page.mouse.up();page.wait_for_timeout(1000)
            button=page.locator('button.underlineStraight')
            if button.count()!=1:raise ValueError('official_txt/no_toolbar')
            button.click(timeout=5000);page.wait_for_timeout(1000)
            if len(captured)!=1:raise ValueError('official_txt/no_request')
            return verify_capture(sample,captured[0])
        finally:
            if context:context.close()
            browser.close()
