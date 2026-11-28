#!/usr/bin/env python3
"""Read-only public article-link preflight; offline unless explicitly enabled.

Derive one public source from the existing verified MP sample. A separate
anonymous opener performs at most one HTTPS GET, without cookies or redirects.
No article, URL, identifier or credential is written to reports or files.
"""
import argparse
from datetime import datetime,timezone
from html.parser import HTMLParser
import json
import re
from urllib.error import HTTPError,URLError
from urllib.parse import parse_qs,urlencode,urlsplit,urljoin
from urllib.request import HTTPRedirectHandler,Request,build_opener

from fetch_weread_epub import USER_AGENT
from secure_weread_session import SessionStore
from verify_mp_export import ExportProbe,Text,body_of
from verify_translation_preflight import save_refreshed_web_session

MAX_BYTES=4*1024*1024


class LinkError(ValueError):pass


def canonical(value):
    if not isinstance(value,str) or len(value)>4096 or re.search(r'[\x00-\x20\x7f\\]',value):return None
    try: parsed=urlsplit(value)
    except ValueError:return None
    if parsed.scheme!='https' or parsed.netloc!='mp.weixin.qq.com':return None
    if re.fullmatch(r'/s/[A-Za-z0-9_-]{8,128}',parsed.path):return 'https://mp.weixin.qq.com'+parsed.path
    if parsed.path!='/s':return None
    query=parse_qs(parsed.query,keep_blank_values=True)
    fields={}
    for key in ('__biz','mid','idx','sn','chksm'):
        if key in query:
            if len(query[key])!=1:return None
            fields[key]=query[key][0]
    if not re.fullmatch(r'[A-Za-z0-9+/=_-]{8,128}',fields.get('__biz','')):return None
    if not re.fullmatch(r'[1-9][0-9]{0,19}',fields.get('mid','')):return None
    if not re.fullmatch(r'[1-9][0-9]?',fields.get('idx','')):return None
    if not re.fullmatch(r'[a-fA-F0-9]{32}',fields.get('sn','')):return None
    if 'chksm' in fields and not re.fullmatch(r'[a-fA-F0-9]{8,128}',fields['chksm']):return None
    return 'https://mp.weixin.qq.com/s?'+urlencode(fields)


class Metadata(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.source=None;self.title=None;self.author=None
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag=='meta':
            name=attrs.get('property',attrs.get('name','')).lower();value=attrs.get('content')
            if name=='og:url' and value:self.source=canonical(value.replace('http://mp.weixin.qq.com/','https://mp.weixin.qq.com/',1))
            elif name=='og:title' and value:self.title=value
            elif name in ('author','article:author') and value:self.author=value
        elif tag=='link' and attrs.get('rel')=='canonical' and attrs.get('href'):
            self.source=self.source or canonical(attrs['href'])
    handle_startendtag=handle_starttag


def metadata(raw):
    if not isinstance(raw,str) or len(raw.encode())>MAX_BYTES:raise LinkError('invalid_response')
    value=Metadata();value.feed(raw)
    return value


def text_of(raw):
    value=Text();value.feed(body_of(raw));return value.value()


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*_args,**_kwargs):return None


def public_read(url,opener=None):
    if not url or canonical(url)!=url:raise LinkError('invalid_source')
    request=Request(url,headers={'User-Agent':USER_AGENT,'Accept':'text/html,application/xhtml+xml',
                                'Referer':'https://mp.weixin.qq.com/'},method='GET')
    report=dict(method='GET',cookies_sent=False,authorization_sent=False,redirects_followed=0)
    try:
        with (opener or build_opener(NoRedirect())).open(request,timeout=20) as response:
            report['status']=response.status
            raw=response.read(MAX_BYTES+1)
            if response.status!=200 or len(raw)>MAX_BYTES:raise LinkError('public_response_unavailable')
        return raw.decode('utf-8'),report
    except HTTPError as exc:
        report['status']=exc.code
        if exc.code in (301,302,303,307,308):
            target=urljoin(url,exc.headers.get('Location',''))
            path=urlsplit(target).path.lower()
            report['redirect_kind']='verification' if any(word in path for word in ('captcha','verify','wappoc')) else 'article' if canonical(target) else 'other'
        exc.close();return None,report
    except (OSError,ValueError,URLError):return None,dict(report,error='public_response_unavailable')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--public-source',action='store_true')
    args=parser.parse_args(argv)
    if args.public_source and not args.saved_session:parser.error('--public-source requires --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                catalog_reads=0,credential_renewals=0,private_articles_saved=False,credentials_written_to_files=False)
    if not args.saved_session:
        assert canonical('https://mp.weixin.qq.com/s/synthetic_token_123')
        print(json.dumps(report,indent=2));return 0
    probe=ExportProbe();saved={}
    try:
        store=SessionStore();saved=store.load();probe.vid=saved['vid']
        for key,value in saved['cookies'].items():probe.set_cookie(key,value)
        probe.verify_account()
        raw=probe.content();info=metadata(raw);source_text=text_of(raw)
        report.update(owner_verified=True,source_url_present=bool(info.source),title_present=bool(info.title),
                      author_present=bool(info.author),sample_has_body=bool(source_text))
        if not info.source:raise LinkError('public_source_missing')
        report['result']='PUBLIC_SOURCE_FOUND'
        if args.public_source:
            public,observation=public_read(info.source)
            report['public_read']=observation
            if not public:raise LinkError('public_source_unavailable')
            public_info=metadata(public)
            body=text_of(public)
            report.update(public_source_identity_matches=public_info.source==info.source,
                          public_title_matches=bool(info.title and public_info.title==info.title),
                          public_body_text_matches=bool(body and body==source_text))
            if not all(report[key] for key in ('public_source_identity_matches','public_title_matches','public_body_text_matches')):
                raise LinkError('public_source_mismatch')
            report['result']='PUBLIC_SOURCE_READ_VERIFIED'
    except LinkError as exc:report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:report.update(result='UNVERIFIED',reason='link_preflight_failed')
    finally:
        if probe.authenticated and saved:
            try:
                probe.verify_account()
                report['web_cookie_rotation_saved']=save_refreshed_web_session(store,saved,probe)
            except Exception:report.update(result='UNVERIFIED',reason='owner_session_unverified')
        report['stages']=probe.report['stages']
        saved.clear();probe.close()
    print(json.dumps(report,indent=2))
    return 0 if report['result'] in ('PUBLIC_SOURCE_FOUND','PUBLIC_SOURCE_READ_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
