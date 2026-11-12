#!/usr/bin/env python3
"""Read-only MP catalog probe; optional single Web credential renewal.

Offline by default. --saved-session uses the existing project Keychain item.
--renew-web reserves a durable marker before one credential-maintenance POST;
unknown receipts are never replayed. Account data and headers stay in memory.
"""
import argparse
import hashlib
import subprocess
from datetime import datetime,timezone
import json
import re
from urllib.error import HTTPError,URLError
from urllib.parse import parse_qs,urlencode,urlsplit
from urllib.request import Request

from fetch_weread_epub import USER_AGENT,weread_e
from secure_weread_session import SessionStore,StoreError
from verify_web_source_progress import BASE,PreflightError,WebSourceProbe


KNOWN_REVIEW='MP_WXS_3286016687_9gm5eWle7VrEYNiwBGaaOQ'


class MPError(ValueError):pass


def article_projection(html):
    if not isinstance(html,str) or len(html.encode())>4*1024*1024:raise MPError('article_invalid')
    body=None
    for pattern in (r'<div[^>]*id="js_content"[^>]*>(.*?)</div>\s*<script',
                    r'class="rich_media_content[^"]*"[^>]*>(.*?)</div>\s*<script',
                    r'<div[^>]*id="js_content"[^>]*>(.*)'):
        match=re.search(pattern,html,re.S)
        if match:body=match[1];break
    if not body:raise MPError('article_missing')
    body=re.sub(r'<script.*?</script>','',body,flags=re.S)
    body=re.sub(r'<style.*?</style>','',body,flags=re.S)
    body=body.replace(' src=""','').replace(" src=''",'').replace('data-src=','src=')
    return dict(body_bytes=len(body.encode()),body_sha256=hashlib.sha256(body.encode()).hexdigest())


def book_id(value):
    return value if isinstance(value,str) and re.fullmatch(r'MP_WXS_[1-9][0-9]{0,19}',value) else None


def error_code(value):
    if value is None:return 0
    if type(value) is int and -(2**31)<=value<2**31:return value
    raise MPError('catalog_error_invalid')


def shape(value):
    return {key:type(item).__name__ for key,item in value.items() if isinstance(key,str) and re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,63}',key)} if isinstance(value,dict) else {}


class MPProbe(WebSourceProbe):
    def __init__(self,**kwargs):
        super().__init__(**kwargs)
        self.mp_book=None;self.web_headers={};self.renewal_attempted=False

    def guard(self,stage,url,body):
        u=urlsplit(url);query=parse_qs(u.query)
        if self.authenticated and u.scheme=='https' and u.netloc=='weread.qq.com' and not u.fragment:
            if (stage=='mp_catalog' and body is None and u.path=='/web/mp/articles' and book_id(self.mp_book)
                    and query.get('bookId')==[self.mp_book] and set(query)=={'bookId','maxIdx','count'}
                    and len(query['maxIdx'])==len(query['count'])==1 and re.fullmatch(r'[0-9]{1,12}',query['maxIdx'][0])
                    and query['count'][0] in ('20','100')):return
            if stage=='mp_content' and body is None and u.path=='/web/mp/content' and query=={'reviewId':[KNOWN_REVIEW]}:return
            if (stage=='web_renewal' and u.path=='/web/login/renewal' and not u.query
                    and body==dict(rq='%2Fweb%2Fbook%2Fread',ql=False)):return
        return super().guard(stage,url,body)

    def renew(self,store,saved):
        if self.renewal_attempted:raise MPError('renewal_already_attempted')
        body=dict(rq='%2Fweb%2Fbook%2Fread',ql=False)
        self.guard('web_renewal',BASE+'/web/login/renewal',body)
        pending=store.begin_renewal(saved)
        request=Request(BASE+'/web/login/renewal',data=json.dumps(body,separators=(',',':')).encode(),
                        headers={'User-Agent':USER_AGENT,'Origin':BASE,'Referer':BASE+'/',
                                 'Content-Type':'application/json;charset=UTF-8'})
        self.renewal_attempted=True
        record=dict(stage='web_renewal',method='POST');self.report['stages'].append(record)
        try:
            with self.opener.open(request,timeout=20) as response:
                record['status']=response.status
                raw=response.read(65537)
                if response.status!=200 or len(raw)>65536:raise MPError('renewal_unconfirmed')
                value=json.loads(raw)
                if not isinstance(value,dict) or value.get('succ') not in (True,1,'1'):raise MPError('renewal_unconfirmed')
                headers={key:response.headers[name] for key,name in (('wr_ticket','x-wr-ticket'),('wr_wrpa','x-wrpa-0')) if response.headers.get(name)}
            self.verify_account()
            committed=store.finish_renewal(self,pending,headers)
            self.web_headers=committed['web']['headers']
            return committed
        except HTTPError as exc:
            record['status']=exc.code;exc.close();raise MPError('renewal_unconfirmed') from None
        except (OSError,ValueError,URLError):raise MPError('renewal_unconfirmed') from None

    def catalog(self,max_idx=0,count=20):
        url=BASE+'/web/mp/articles?'+urlencode(dict(bookId=self.mp_book,maxIdx=max_idx,count=count))
        self.guard('mp_catalog',url,None)
        headers={'User-Agent':USER_AGENT,'Referer':BASE+'/web/mp/reader/'+weread_e(self.mp_book),
                 'Accept':'application/json, text/plain, */*'}
        for key,name in (('wr_ticket','x-wr-ticket'),('wr_wrpa','x-wrpa-0')):
            if self.web_headers.get(key):headers[name]=self.web_headers[key]
        record=dict(stage='mp_catalog',method='GET');self.report['stages'].append(record)
        try:
            with self.opener.open(Request(url,headers=headers),timeout=20) as response:
                record['status']=response.status;raw=response.read(4*1024*1024+1)
                if response.status!=200 or len(raw)>4*1024*1024:raise MPError('catalog_unavailable')
            value=json.loads(raw)
            if not isinstance(value,dict):raise MPError('catalog_invalid')
            return value
        except HTTPError as exc:
            record['status']=exc.code;exc.close();raise MPError('catalog_unavailable') from None
        except (OSError,ValueError,URLError):raise MPError('catalog_unavailable') from None


    def content(self):
        url=BASE+'/web/mp/content?'+urlencode(dict(reviewId=KNOWN_REVIEW))
        self.guard('mp_content',url,None)
        record=dict(stage='mp_content',method='GET');self.report['stages'].append(record)
        try:
            with self.opener.open(Request(url,headers={'User-Agent':USER_AGENT,'Referer':BASE+'/'}),timeout=20) as response:
                record['status']=response.status;raw=response.read(4*1024*1024+1)
                if response.status!=200 or len(raw)>4*1024*1024:raise MPError('content_unavailable')
            return raw.decode('utf-8')
        except HTTPError as exc:
            record['status']=exc.code;exc.close();raise MPError('content_unavailable') from None
        except (OSError,ValueError,URLError):raise MPError('content_unavailable') from None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--renew-web',action='store_true')
    parser.add_argument('--check-content',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.renew_web and not args.saved_session:parser.error('--renew-web requires --saved-session')
    if args.lua_command and not (args.saved_session and args.check_content):parser.error('Lua comparison requires --saved-session --check-content')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_writes_attempted=0,
                credential_renewal_attempts=0,credentials_written_to_files=False,private_articles_saved=False)
    if not args.saved_session:
        assert book_id('MP_WXS_900001') and not book_id('900001')
        print(json.dumps(report,indent=2));return 0
    probe=MPProbe()
    try:
        store=SessionStore();saved=store.load();probe.vid=saved['vid']
        for key,value in saved['cookies'].items():probe.set_cookie(key,value)
        probe.verify_account()
        shelf=probe.request('shelf',BASE+'/web/shelf/sync')
        books=shelf.get('books') if isinstance(shelf,dict) else None
        if not isinstance(books,list) or len(books)>5000:raise MPError('shelf_invalid')
        accounts=[row['bookId'] for row in books if isinstance(row,dict) and book_id(row.get('bookId'))]
        if not accounts:raise MPError('no_mp_accounts')
        probe.web_headers=saved.get('web',{}).get('headers',{})
        if args.renew_web:
            saved=probe.renew(store,saved)
            report.update(renewed_credentials_saved=True,renewal_pending_cleared=True,
                          web_ticket_present=bool(probe.web_headers.get('wr_ticket')),web_protection_header_present=bool(probe.web_headers.get('wr_wrpa')))
        observations=[];success=True
        for account in accounts[:2]:
            probe.mp_book=account
            data=probe.catalog(count=100)
            groups=data.get('reviews')
            observation=dict(top_level=shape(data),group_count=len(groups) if isinstance(groups,list) else 0,
                             errcode=error_code(data.get('errCode',data.get('errcode',0))))
            if isinstance(groups,list) and groups:
                observation['group_fields']=shape(groups[0])
                subs=groups[0].get('subReviews') if isinstance(groups[0],dict) else None
                if isinstance(subs,list) and subs:
                    observation['sub_fields']=shape(subs[0]);review=subs[0].get('review',subs[0])
                    observation['review_fields']=shape(review)
                    observation['mp_info_fields']=shape(review.get('mpInfo')) if isinstance(review,dict) else {}
                observation['article_count']=sum(len(g.get('subReviews',[])) for g in groups if isinstance(g,dict) and isinstance(g.get('subReviews'),list))
            else:success=False
            observations.append(observation)
        if args.check_content:
            html=probe.content();expected=article_projection(html)
            report['article_content_verified']=True
            if args.lua_command:
                refreshed={c.name:c.value for c in probe.cookies if c.name in ('wr_vid','wr_skey','wr_rt','wr_ql','wr_fp','wr_pf') and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'}
                payload=dict(html=html,session=dict(vid=probe.vid,cookies=refreshed),review_id=KNOWN_REVIEW,mp_books=accounts[:2],web_headers=probe.web_headers)
                encoded=json.dumps(payload,ensure_ascii=False).encode()
                if len(encoded)>12*1024*1024:raise MPError('probe_too_large')
                completed=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
                frame=b'\nWEREAD_MP_CONTENT_RESULT='
                if completed.returncode or len(completed.stdout)>65536 or completed.stdout.count(frame)!=1:raise MPError('lua_content_probe_failed')
                actual=json.loads(completed.stdout.split(frame)[1])
                if actual.get('model')!=expected or actual.get('native')!=expected:raise MPError('content_projection_mismatch')
                report.update(lua_content_projection_matches=True,native_https_content_matches=True,native_read_requests=actual.get('requests'),native_catalog=actual.get('catalog'))
            html=None;expected.clear()
        probe.verify_account();store.save(probe);saved.clear()
        report.update(result='MP_CATALOG_READ_VERIFIED' if success else 'MP_CATALOG_UNVERIFIED',owner_verified=True,
                      mp_account_count=len(accounts),samples=observations,stages=probe.report['stages'])
    except (StoreError,PreflightError,MPError) as exc:report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:report.update(result='UNVERIFIED',reason='verification_failed')
    finally:
        report['credential_renewal_attempts']=int(probe.renewal_attempted)
        probe.close()
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='MP_CATALOG_READ_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
