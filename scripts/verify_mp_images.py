#!/usr/bin/env python3
"""Read one known MP body and one anonymous bitmap; keep bytes/URLs in memory."""
import argparse
from datetime import datetime,timezone
from html.parser import HTMLParser
import json
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import build_opener,Request
from fetch_weread_epub import USER_AGENT
from secure_weread_session import SessionStore
from verify_mp_export import ExportProbe,body_of
from verify_mp_link import NoRedirect
from verify_translation_preflight import save_refreshed_web_session


def image_url(value):
    if not isinstance(value,str) or len(value)>4096 or any(ord(c)<33 or ord(c)==127 for c in value):return None
    if value.startswith('//'):value='https:'+value
    p=urlsplit(value)
    if p.scheme not in ('http','https') or p.netloc not in ('mmbiz.qpic.cn','mmbiz.qlogo.cn') or not p.path.startswith('/'):return None
    return 'https://'+p.netloc+p.path+('?' + p.query if p.query else '')


def media(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'):return 'image/png'
    if data.startswith(b'\xff\xd8\xff'):return 'image/jpeg'
    if data[:6] in (b'GIF87a',b'GIF89a'):return 'image/gif'
    if data[:4]==b'RIFF' and data[8:12]==b'WEBP':return 'image/webp'


class Images(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.urls=[]
    def handle_starttag(self,tag,attrs):
        if tag=='img':
            attrs=dict(attrs);url=image_url(attrs.get('src',attrs.get('data-src','')))
            if url and url not in self.urls:self.urls.append(url)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                images_written_to_files=False,private_articles_saved=False,credential_renewals=0)
    if not args.saved_session:print(json.dumps(report,indent=2));return 0
    probe=ExportProbe();saved={}
    try:
        store=SessionStore();saved=store.load();probe.vid=saved['vid']
        for name,value in saved['cookies'].items():probe.set_cookie(name,value)
        probe.verify_account();images=Images();images.feed(body_of(probe.content()))
        if not images.urls:raise ValueError()
        request=Request(images.urls[0],headers={'User-Agent':USER_AGENT,'Accept':'image/*','Referer':'https://weread.qq.com/'},method='GET')
        with build_opener(NoRedirect()).open(request,timeout=20) as response:
            raw=response.read(64*1024*1024+1);code=response.status
        kind=media(raw)
        if code!=200 or not kind or len(raw)>64*1024*1024:raise ValueError()
        report.update(result='READONLY_IMAGE_VERIFIED',owner_verified=True,source_images=len(images.urls),
                      image_gets=1,image_status=code,image_media=kind,image_bytes=len(raw),image_cookie_sent=False,
                      image_authorization_sent=False,redirects_followed=0)
    except HTTPError as exc:report.update(result='UNVERIFIED',image_status=exc.code);exc.close()
    except Exception:report.update(result='UNVERIFIED',reason='image_preflight_failed')
    finally:
        if probe.authenticated and saved:
            try:
                probe.verify_account();report['web_cookie_rotation_saved']=save_refreshed_web_session(store,saved,probe)
            except Exception:report.update(result='UNVERIFIED',reason='owner_session_unverified')
        report['stages']=probe.report['stages'];saved.clear();probe.close()
    print(json.dumps(report,indent=2));return 0 if report['result']=='READONLY_IMAGE_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
