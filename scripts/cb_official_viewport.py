"""Read-only, target-bound browser comparison for an imported book.

The browser receives an existing authenticated session in an incognito
context. It can fetch only public assets, the selected reader, its read-info
and the selected book's catalog/content. Every other POST, including reading
progress, renewal and analytics, is blocked. No DOM, text, cookies or book
identities are returned by this module.
"""
import base64
import json
from pathlib import Path
import subprocess
from urllib.parse import parse_qs, urlsplit

from fetch_weread_epub import reader_url_for, weread_e
from secure_weread_session import COOKIE_NAMES
from verify_cb_progress import cb_id

SHARDS=frozenset('/web/book/chapter/'+kind+'_'+str(index)
                 for kind in ('e','t') for index in range(4))
OCR=Path(__file__).resolve().with_name('compare_visible_anchor.swift')


def compare_visible(image,anchors):
    """Perform local OCR through a private pipe and return no recognized text."""
    if (not isinstance(image,bytes) or not 1<=len(image)<=10_000_000 or not isinstance(anchors,list)
            or not 1<=len(anchors)<=3 or any(not isinstance(x,str) or not 1<=len(x)<=128 for x in anchors)):
        raise ValueError('viewport/ocr_input')
    payload=json.dumps(dict(image=base64.b64encode(image).decode('ascii'),anchors=anchors),ensure_ascii=False).encode()
    child=subprocess.run(['swift',str(OCR)],input=payload,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
    if child.returncode or len(child.stdout)>4096:raise ValueError('viewport/ocr_unavailable')
    value=json.loads(child.stdout)
    if (not isinstance(value,dict) or set(value)!={'result','recognized_lines','matches'}
            or value['result']!='OK' or type(value['recognized_lines']) is not int or value['recognized_lines']<0
            or not isinstance(value['matches'],list) or len(value['matches'])!=len(anchors)
            or any(not isinstance(x,dict) or set(x)!={'exact','windows'} or type(x['exact']) is not bool
                   or type(x['windows']) is not int or x['windows']<0 for x in value['matches'])):
        raise ValueError('viewport/ocr_result')
    return value


def allowed(method,url,body,book,chapters):
    if not cb_id(book) or not isinstance(chapters,(set,frozenset)) or not chapters:return False
    try:
        u=urlsplit(url)
        if u.scheme!='https' or u.username or u.password or u.port not in (None,443) or u.fragment:return False
        if method=='GET' and u.hostname=='cdn.weread.qq.com':return True
        if u.hostname!='weread.qq.com':return False
        if method=='GET':
            if url==reader_url_for(book):return True
            if u.path=='/feconfig/font/list':return True
            if u.path in ('/web/book/readInfo','/web/book/getProgress'):
                query=parse_qs(u.query,keep_blank_values=True)
                return query.get('bookId')==[book]
            return False
        if method!='POST' or u.query or not isinstance(body,str) or len(body)>16384:return False
        value=json.loads(body)
        if not isinstance(value,dict):return False
        if u.path in SHARDS:
            return value.get('b')==weread_e(book) and value.get('c') in {weread_e(uid) for uid in chapters}
        if u.path=='/web/book/chapterInfos':return value.get('bookIds')==[book]
    except (TypeError,ValueError,UnicodeError):
        return False
    return False


def observe(book,chapters,cookies,offset,*,source_anchors=None,timeout=30000):
    if (not cb_id(book) or type(offset) is not int or offset<0 or not isinstance(cookies,dict)
            or not cookies or any(k not in COOKIE_NAMES or not isinstance(v,str) or not v for k,v in cookies.items())
            or source_anchors is not None and (not isinstance(source_anchors,list) or not 1<=len(source_anchors)<=3
                or any(not isinstance(x,str) or not 1<=len(x)<=128 for x in source_anchors))):
        raise ValueError('viewport/scope')
    chapter_ids=frozenset(str(value) for value in chapters)
    if not chapter_ids or len(chapter_ids)>5000 or any(not uid.isdigit() or len(uid)>20 for uid in chapter_ids):
        raise ValueError('viewport/chapters')
    from playwright.sync_api import sync_playwright
    counts={'read_posts':0,'blocked_posts':0,'blocked_other':0};total=0
    with sync_playwright() as playwright:
        browser=playwright.chromium.launch(channel='chrome',headless=True)
        context=None
        try:
            context=browser.new_context(service_workers='block',viewport={'width':1024,'height':768})
            context.add_cookies([dict(name=k,value=v,domain='.weread.qq.com',path='/',secure=True)
                                 for k,v in cookies.items()])
            def gate(route):
                nonlocal total
                total+=1
                request=route.request
                permitted=total<=200 and allowed(request.method,request.url,request.post_data,book,chapter_ids)
                if request.method=='POST':
                    counts['read_posts' if permitted else 'blocked_posts']+=1
                elif not permitted:counts['blocked_other']+=1
                if permitted:route.continue_()
                else:route.abort()
            context.route('**/*',gate)
            context.route_web_socket('**/*',lambda websocket:websocket.close())
            page=context.new_page();page.goto(reader_url_for(book),wait_until='domcontentloaded',timeout=timeout)
            page.wait_for_timeout(5000)
            # No private comparison text is supplied until further network is
            # blocked, including browser-initiated background requests.
            context.route('**/*',lambda route:route.abort())
            context.set_offline(True)
            shape=page.evaluate('''input => {
                const nodes=[...document.querySelectorAll('[data-wr-co]')];
                const visible=nodes.filter(n=>{const r=n.getBoundingClientRect();
                    return r.width>0 && r.height>0 && r.bottom>0 && r.top<innerHeight
                        && r.right>0 && r.left<innerWidth;});
                const spans=visible.map(n=>({start:Number(n.getAttribute('data-wr-co')),
                    length:(n.textContent||'').length})).filter(x=>Number.isSafeInteger(x.start) && x.start>=0);
                const text=document.body ? document.body.innerText : '';
                const normalize=s=>s.replace(/\\s/g,'');
                return {coordinate_nodes:nodes.length,visible_coordinate_nodes:spans.length,
                    offset_in_visible_node:spans.some(x=>x.start<=input.offset && input.offset<x.start+x.length),
                    source_anchor_present:input.anchor ? normalize(text).includes(normalize(input.anchor)) : false,
                    text_characters:text.length,canvas_elements:document.querySelectorAll('canvas').length,
                    login_prompt_visible:text.includes('扫码登录')};
            }''',dict(offset=offset,anchor=source_anchors[0] if source_anchors else None))
            if (not isinstance(shape,dict) or set(shape)!={'coordinate_nodes','visible_coordinate_nodes','offset_in_visible_node',
                    'source_anchor_present','text_characters','canvas_elements','login_prompt_visible'}
                    or type(shape['coordinate_nodes']) is not int or type(shape['visible_coordinate_nodes']) is not int
                    or type(shape['text_characters']) is not int or type(shape['canvas_elements']) is not int
                    or any(type(shape[k]) is not bool for k in ('offset_in_visible_node','source_anchor_present','login_prompt_visible'))):
                raise ValueError('viewport/shape')
            if source_anchors:
                ocr=compare_visible(page.screenshot(),source_anchors)
                shape.update(ocr_lines=ocr['recognized_lines'],ocr_matches=ocr['matches'])
            return dict(shape,**counts)
        finally:
            if context is not None:context.close()
            browser.close()
