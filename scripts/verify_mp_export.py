#!/usr/bin/env python3
"""Read-only MP export conversion check; real HTML stays in private pipes.

Offline unless --saved-session is explicit. Only owner verification and one
known MP content GET are permitted; no catalog, renewal or account writes.
"""
import argparse
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
import re
import subprocess
from urllib.parse import parse_qs, urlsplit

from secure_weread_session import SessionStore, StoreError
from verify_mp_catalog import MPProbe, MPError, KNOWN_REVIEW, article_projection
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import PreflightError

SKIP={'script','style','iframe','object','embed','svg','math','template','audio','video','noscript'}
MISSING='MP_EXPORT_IMAGE_UNAVAILABLE'


class ExportProbe(MPProbe):
    def guard(self,stage,url,body):
        parsed=urlsplit(url)
        if body is not None: raise MPError('export/write_forbidden')
        if stage=='account': return super().guard(stage,url,body)
        if (stage=='mp_content' and self.authenticated and parsed.scheme=='https' and parsed.netloc=='weread.qq.com'
                and parsed.path=='/web/mp/content' and not parsed.fragment
                and parse_qs(parsed.query)=={'reviewId':[KNOWN_REVIEW]}): return
        raise MPError('export/request_forbidden')


def body_of(html):
    article_projection(html)  # Enforce the existing, real-verified extraction.
    for pattern in (r'<div[^>]*id="js_content"[^>]*>(.*?)</div>\s*<script',
                    r'class="rich_media_content[^"]*"[^>]*>(.*?)</div>\s*<script',
                    r'<div[^>]*id="js_content"[^>]*>(.*)'):
        match=re.search(pattern,html,re.S)
        if match: body=match[1];break
    body=re.sub(r'<script.*?</script>','',body,flags=re.S)
    body=re.sub(r'<style.*?</style>','',body,flags=re.S)
    return body.replace(' src=""','').replace(" src=''",'').replace('data-src=','src=')


class Text(HTMLParser):
    def __init__(self,source=False):
        super().__init__(convert_charrefs=True)
        self.source=source;self.parts=[];self.skip=[];self.images=0
    def handle_starttag(self,tag,attrs):
        if tag in SKIP and tag!='embed': self.skip.append(tag);return
        if self.skip: return
        if tag=='img':
            self.images+=1
            if self.source:
                value=dict(attrs).get('alt') or MISSING
                self.parts.append('['+value+']')
    def handle_startendtag(self,tag,attrs):
        self.handle_starttag(tag,attrs)
        if tag in self.skip: self.handle_endtag(tag)
    def handle_endtag(self,tag):
        if tag in self.skip:
            self.skip=self.skip[:len(self.skip)-1-self.skip[::-1].index(tag)]
    def handle_data(self,text):
        if not self.skip: self.parts.append(text)
    def value(self): return re.sub(r'\s+','', ''.join(self.parts))


def compare(source,xhtml):
    expected=Text(source=True);expected.feed(source)
    actual=Text();actual.feed(xhtml)
    if not expected.value() or actual.value()!=expected.value() or actual.images:
        raise MPError('export/text_mismatch')
    return expected.images


def child(command,payload):
    encoded=json.dumps(payload,ensure_ascii=False).encode()
    if len(encoded)>8*1024*1024: raise MPError('export/probe_too_large')
    result=subprocess.run(command,input=encoded,capture_output=True,timeout=90)
    frame=b'\nWEREAD_MP_EXPORT_RESULT='
    if result.returncode or len(result.stdout)>24*1024*1024 or result.stdout.count(frame)!=1:
        raise MPError('export/probe_failed')
    try: value=json.loads(result.stdout.split(frame)[1])
    except (ValueError,UnicodeError): raise MPError('export/probe_failed') from None
    if not isinstance(value,dict): raise MPError('export/probe_failed')
    return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session: parser.error('Lua check requires --saved-session')
    if args.saved_session and not args.lua_command: parser.error('--saved-session requires --lua-command')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                catalog_reads=0,credential_renewals=0,private_articles_saved=False,credentials_written_to_files=False)
    if not args.saved_session:
        compare('<p>合成文本</p><img alt="示例"/>','<p>合成文本</p><span>[示例]</span>')
        print(json.dumps(report,indent=2));return 0
    probe=ExportProbe();saved={};payload={}
    try:
        store=SessionStore();saved=store.load();probe.vid=saved['vid']
        for name,value in saved['cookies'].items(): probe.set_cookie(name,value)
        probe.verify_account()
        html=probe.content();body=body_of(html)
        cookies={cookie.name:cookie.value for cookie in probe.cookies if cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
        payload=dict(html=html,session=dict(vid=probe.vid,cookies=cookies),review_id=KNOWN_REVIEW,missing_label=MISSING)
        actual=child(args.lua_command,payload)
        counts=[]
        for name in ('model','native'):
            item=actual.get(name)
            if not isinstance(item,dict) or not isinstance(item.get('xhtml'),str) or len(item['xhtml'].encode())>8*1024*1024:
                raise MPError('export/probe_invalid')
            count=compare(body,item['xhtml'])
            if item.get('missing')!=count: raise MPError('export/image_count_mismatch')
            counts.append(count)
        if actual.get('requests')!=1: raise MPError('export/request_count_invalid')
        probe.verify_account()
        rotated=save_refreshed_web_session(store,saved,probe)
        report.update(result='READONLY_CONVERSION_VERIFIED',owner_verified=True,source_text_preserved=True,
            model_and_native_text_match=True,remote_images_not_fetched=True,unavailable_images=counts[0],
            model_native_image_counts_match=counts[0]==counts[1],native_content_gets=1,web_cookie_rotation_saved=rotated,
            stages=probe.report['stages'])
    except (StoreError,PreflightError,MPError): report.update(result='UNVERIFIED',reason='export_verification_failed')
    except Exception: report.update(result='UNVERIFIED',reason='export_verification_failed')
    finally:
        saved.clear();payload.clear();probe.close()
    print(json.dumps(report,indent=2));return 0 if report['result']=='READONLY_CONVERSION_VERIFIED' else 1


if __name__=='__main__': raise SystemExit(main())
