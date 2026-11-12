#!/usr/bin/env python3
"""Read-only official translation prerequisites; offline unless explicit.

Only member summary, shelf, selected book metadata and full catalog reads are
allowed. The GET /trans/pdfepub changes server state and is forbidden here,
just like /en/bookread, trials, purchase and shelf/progress mutations.
Private account/catalog data and credentials stay in memory.
"""
import argparse
from datetime import datetime,timezone
import json
import math
import re
import subprocess
from html.parser import HTMLParser
from urllib.parse import parse_qs,urlencode,urlsplit

from secure_native_session import NativeSessionStore
from secure_weread_session import COOKIE_NAMES,SessionStore,StoreError
from verify_eink_login import BASE,NativeProbe,ProbeError
from verify_native_discovery import identity,page,DiscoveryError
from verify_web_source_progress import WebSourceProbe,PreflightError,BASE as WEB_BASE
from verify_reader_context import project as reader_context
from fetch_weread_epub import reader_url_for,make_content_params,weread_sign,sorted_query,decode_content_shards,weread_e

PLATFORM='wechat_wx-2001-android-100-weread'
PUBLIC_QUERY='Pride and Prejudice'


class TranslationError(ValueError): pass


def integer(value,maximum=9007199254740991):
    return type(value) is int and 0<=value<=maximum


def flag(value):
    if type(value) is bool: return value
    if type(value) is int and value in (0,1): return value==1
    if isinstance(value,str) and value in ('0','1','false','true'): return value in ('1','true')
    raise TranslationError('translation/invalid_flag')


def membership(raw):
    if not isinstance(raw,dict) or 'isPaying' not in raw: raise TranslationError('translation/member_schema_invalid')
    return dict(paying=flag(raw['isPaying']))


def catalog_body(book_id):
    if identity(book_id) is None: raise TranslationError('translation/book_identity_invalid')
    return dict(bookIds=[str(book_id)],synckeys=[0],updateTimes=[0],maxfreeIdx=[0])


def catalog(raw,book_id,info):
    book_id=identity(book_id)
    if not book_id or not isinstance(info,dict) or identity(info.get('bookId'))!=book_id:
        raise TranslationError('translation/book_identity_invalid')
    rows=raw.get('data') if isinstance(raw,dict) else None
    if not isinstance(rows,list) or len(rows)>4: raise TranslationError('translation/catalog_schema_invalid')
    matching=[row for row in rows if isinstance(row,dict) and identity(row.get('bookId'))==book_id]
    if len(matching)!=1 or not isinstance(matching[0].get('updated'),list) or len(matching[0]['updated'])>20000:
        raise TranslationError('translation/catalog_identity_invalid')
    record=matching[0]
    if isinstance(record.get('book'),dict) and record['book'].get('bookId') is not None and identity(record['book']['bookId'])!=book_id:
        raise TranslationError('translation/catalog_identity_invalid')
    source=record.get('book') if isinstance(record.get('book'),dict) else info
    format=source.get('format',info.get('format'))
    if format is not None and format not in ('epub','txt','pdf'): raise TranslationError('translation/book_format_invalid')
    version=source.get('version',info.get('version'))
    if version is not None and not integer(version): raise TranslationError('translation/book_version_invalid')
    result=dict(book_id=book_id,format=format,version=version,chapters=[])
    seen=set()
    for row in record['updated']:
        if not isinstance(row,dict): raise TranslationError('translation/chapter_schema_invalid')
        uid=row.get('chapterUid')
        if type(uid) is str and uid.isascii() and uid.isdigit() and len(uid)<=20 and (uid=='0' or not uid.startswith('0')): uid=int(uid)
        if not integer(uid) or uid in seen: raise TranslationError('translation/chapter_identity_invalid')
        seen.add(uid)
        value=dict(uid=uid)
        for name in ('wordCount','translateVersion','transWordCount'):
            if name in row:
                if not integer(row[name]): raise TranslationError('translation/chapter_counter_invalid')
                value[name]=row[name]
        if 'hasTranslated' in row: value['hasTranslated']=flag(row['hasTranslated'])
        price=row.get('price');paid=row.get('paid')
        if price is not None and (type(price) not in (int,float) or not math.isfinite(price) or abs(price)>1e12):
            raise TranslationError('translation/chapter_price_invalid')
        if paid is not None and not integer(paid): raise TranslationError('translation/chapter_paid_invalid')
        # This admission is for a future explicit download. Membership alone
        # never proves that a paid chapter can be requested without purchase.
        value['price_known']=type(price) in (int,float) and price>=0
        value['free_or_owned']=(price==0 and type(price) in (int,float)) or (integer(paid) and paid>0)
        result['chapters'].append(value)
    return result


class TranslationText(HTMLParser):
    """Count actual translated text only; this does not prove source pairing."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack=[];self.blocks=0;self.nonempty=0
    def handle_starttag(self,tag,attrs):
        if len(self.stack)>=256: raise TranslationError('translation/content_depth_limit')
        parent=self.stack[-1] if self.stack else None
        owner=parent[1] if parent else None
        if owner is None and 'wr-translation' in (dict(attrs).get('class') or '').split():
            owner=dict(nonempty=False);self.blocks+=1
        row=[tag,owner,owner is not None and (not parent or owner is not parent[1])]
        self.stack.append(row)
        if tag in ('area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'):
            self.handle_endtag(tag)
    def handle_startendtag(self,tag,attrs):
        self.handle_starttag(tag,attrs)
        if self.stack and self.stack[-1][0]==tag: self.handle_endtag(tag)
    def handle_data(self,value):
        if self.stack and self.stack[-1][1] and value.strip() and not any(row[0] in ('script','style') for row in self.stack):
            self.stack[-1][1]['nonempty']=True
    def handle_endtag(self,tag):
        at=next((i for i in range(len(self.stack)-1,-1,-1) if self.stack[i][0]==tag),None)
        if at is None: return
        for row in self.stack[at:]:
            if row[2] and row[1]['nonempty']: self.nonempty+=1
        del self.stack[at:]
    def finish(self):
        for row in self.stack:
            if row[2] and row[1]['nonempty']: self.nonempty+=1
        self.stack=[]
        return dict(translation_blocks=self.blocks,nonempty_translation_blocks=self.nonempty)


def content_summary(source):
    if not isinstance(source,str) or not 0<len(source.encode('utf-8'))<=2*1024*1024:
        raise TranslationError('translation/content_invalid')
    parser=TranslationText();parser.feed(source);parser.close()
    return parser.finish()


class TranslationWebProbe(WebSourceProbe):
    def __init__(self):
        super().__init__();self.fields=None;self.samples=[]
    def guard(self,stage,url,body):
        if stage=='account': return super().guard(stage,url,body)
        if not self.authenticated or not self.book_id or not self.chapter:
            raise TranslationError('translation/web_request_outside_scope')
        if stage=='reader' and body is None and url==reader_url_for(self.book_id,self.chapter): return
        if stage in ('e_0','e_1','e_3') and url==WEB_BASE+'/web/book/chapter/'+stage and body==self.fields and self.fields is not None:
            required={'b','c','r','ct','ps','pc','sc','st','s'}
            if self.fields.get('sc')==1: required.add('prevChapter')
            if (set(body)==required and body['b']==weread_e(self.book_id) and body['c']==weread_e(self.chapter)
                    and type(body['sc']) is int and body['sc'] in (0,1) and type(body['st']) is int and body['st']==0
                    and ('prevChapter' not in body or body['prevChapter'] is False) and len(json.dumps(body))<=16384): return
        raise TranslationError('translation/web_request_outside_scope')
    def inspect_content(self,sample):
        model=sample['expected']
        safe=[row for row in model['chapters'] if row['uid']>0 and row.get('wordCount',0)>=200 and row['free_or_owned']]
        if not safe: return dict(attempted=False,reason='no_explicit_free_or_owned_chapter')
        row=max(safe,key=lambda item:(item.get('transWordCount',0)>0,item.get('translateVersion',0)>0,item.get('hasTranslated') is True,-item['uid']))
        self.book_id=sample['book_id'];self.chapter=str(row['uid'])
        html=self.request('reader',reader_url_for(self.book_id,self.chapter),as_json=False)
        state=reader_context(dict(book_id=self.book_id),html)
        if str(state['current_chapter'].get('chapterUid'))!=self.chapter: raise TranslationError('translation/web_chapter_mismatch')
        attempts=[]
        for compatibility in (False,True):
            fields=make_content_params(self.book_id,self.chapter,state['psvts'],sc=1 if compatibility else 0)
            if not compatibility:
                fields.pop('prevChapter');fields.pop('s')
                if state.get('pclts') is not None and str(state['pclts'])!='': fields['pc']=str(state['pclts'])
                fields['s']=weread_sign(sorted_query(fields))
            self.fields=fields
            raw=[self.request(stage,WEB_BASE+'/web/book/chapter/'+stage,fields,as_json=False) for stage in ('e_0','e_1','e_3')]
            try: source=decode_content_shards(*raw)
            except Exception: raise TranslationError('translation/content_decode_failed') from None
            attempts.append(dict(representation='download' if compatibility else 'browser',decoded_bytes=len(source.encode('utf-8'))))
            if source:
                summary=content_summary(source)
                html=source if re.search(r'<body(?:\s|>)',source,re.I) else '<html><body>'+source+'</body></html>'
                self.samples.append(dict(html=html,expected_blocks=summary['nonempty_translation_blocks']))
                return dict(attempted=True,same_book_and_chapter_verified=True,content_decoded=True,attempts=attempts,**summary)
        return dict(attempted=True,same_book_and_chapter_verified=True,content_decoded=False,attempts=attempts,
                    reason='empty_read_representation',translation_blocks=0,nonempty_translation_blocks=0)



class TranslationProbe(NativeProbe):
    def __init__(self,opener=None):
        super().__init__(opener)
        self.allowed_ids=set();self.samples=[]

    def guard(self,stage,url,body):
        parsed=urlsplit(url);query=parse_qs(parsed.query,keep_blank_values=True)
        if parsed.scheme!='https' or parsed.netloc!='i.weread.qq.com' or parsed.fragment:
            raise TranslationError('translation/request_outside_scope')
        if stage=='shelf' and parsed.path=='/shelf/sync' and not query and body is None: return
        if stage=='member' and parsed.path=='/pay/memberCardSummary' and query=={'pf':[PLATFORM]} and body is None: return
        if stage=='public_english' and parsed.path=='/store/search' and query=={'keyword':[PUBLIC_QUERY],'scope':['10'],'count':['20'],'maxIdx':['0']} and body is None: return
        if stage=='book' and parsed.path=='/book/info' and set(query)=={'bookId'} and len(query['bookId'])==1 and query['bookId'][0] in self.allowed_ids and body is None: return
        if stage=='catalog' and parsed.path=='/book/chapterInfos' and not query and isinstance(body,dict):
            for key in self.allowed_ids:
                if body==catalog_body(key): return
        raise TranslationError('translation/request_outside_scope')

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        self.guard(stage,url,body)
        return super().request(stage,url,body,credentials,timeout)

    def inspect(self,credentials,sample_count=2,public_english=False):
        if type(sample_count) is not int or not 1<=sample_count<=3: raise TranslationError('translation/sample_limit_invalid')
        shelf=self.request('shelf',BASE+'/shelf/sync',credentials=credentials)
        rows=shelf.get('books') if isinstance(shelf,dict) else None
        if not isinstance(rows,list) or len(rows)>5000: raise TranslationError('translation/shelf_invalid')
        member_raw=self.request('member',BASE+'/pay/memberCardSummary?'+urlencode(dict(pf=PLATFORM)),credentials=credentials)
        member=membership(member_raw)
        keys=[]
        if public_english:
            raw=self.request('public_english',BASE+'/store/search?'+urlencode(dict(keyword=PUBLIC_QUERY,scope=10,count=20,maxIdx=0)),credentials=credentials)
            found=page('search',raw)['books']
            for row in found:
                title=row['title']
                letters=sum(c.isascii() and c.isalpha() for c in title)
                if letters>=10 and letters/max(1,len(title))>=0.6: keys.append(row['bookId'])
                if len(keys)==sample_count: break
        else:
            for row in rows:
                key=identity(row.get('bookId')) if isinstance(row,dict) else None
                if key and key not in keys: keys.append(key)
                if len(keys)==sample_count: break
        if not keys: raise TranslationError('translation/no_eligible_sample')
        self.allowed_ids=set(keys)
        report=dict(shelf_book_count=len(rows),member_contract_verified=True,member_value_type=type(member_raw['isPaying']).__name__,
                    sampled_book_count=len(keys),public_search_fixture=public_english,samples=[])
        self.member=member
        for key in keys:
            info=self.request('book',BASE+'/book/info?'+urlencode(dict(bookId=key)),credentials=credentials)
            raw=self.request('catalog',BASE+'/book/chapterInfos',body=catalog_body(key),credentials=credentials)
            model=catalog(raw,key,info)
            self.samples.append(dict(book_id=key,info=info,source=raw,expected=model))
            report['samples'].append(dict(chapter_count=len(model['chapters']),format=model['format'],
                version_present=model['version'] is not None,
                translation_field_counts={field:sum(field in c for c in model['chapters']) for field in ('hasTranslated','translateVersion','transWordCount')},
                translated_flag_true_count=sum(c.get('hasTranslated') is True for c in model['chapters']),
                positive_translate_version_count=sum(c.get('translateVersion',0)>0 for c in model['chapters']),
                positive_trans_word_count=sum(c.get('transWordCount',0)>0 for c in model['chapters']),
                explicit_free_or_owned_readable_chapters=sum(c['free_or_owned'] and c.get('wordCount',0)>0 for c in model['chapters'])))
        return report


def save_refreshed_web_session(store,saved,probe):
    refreshed={cookie.name:cookie.value for cookie in probe.cookies if cookie.name in COOKIE_NAMES
               and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
    if refreshed==saved['cookies']: return False
    if not probe.authenticated or str(probe.vid)!=saved['vid'] or store.load()!=saved:
        raise StoreError('session_changed')
    store.save(probe)
    return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--sample',type=int,choices=(1,2,3),default=2)
    parser.add_argument('--public-english',action='store_true')
    parser.add_argument('--check-content',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.public_english and not args.saved_session: parser.error('public search requires --saved-session')
    if args.check_content and not (args.saved_session and args.public_english): parser.error('content checks require saved session and public English samples')
    if args.lua_command and not args.check_content: parser.error('Lua model check requires --check-content')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                translation_mode_changes_attempted=0,generation_requests_attempted=0,trial_activations_attempted=0,
                purchase_requests_attempted=0,credentials_written_to_files=False,private_catalog_saved=False)
    credentials=None;probe=None;web=None
    if not args.saved_session:
        assert catalog_body('900001')['bookIds']==['900001']
        print(json.dumps(report,indent=2));return 0
    try:
        saved=SessionStore().load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
        probe=TranslationProbe();report.update(probe.inspect(credentials,args.sample,args.public_english))
        report.update(result='TRANSLATION_READ_PREREQUISITES_VERIFIED',same_owner_verified=True)
        if args.check_content:
            web=TranslationWebProbe();web.vid=owner
            for name,value in saved['cookies'].items(): web.set_cookie(name,value)
            web.verify_account()
            report['content_checks']=[web.inspect_content(sample) for sample in probe.samples[:2]]
            web.verify_account()
            if save_refreshed_web_session(SessionStore(),saved,web): report['refreshed_web_session_saved_to_keychain']=True
            report['web_stages']=web.report['stages']
            report['existing_translated_text_confirmed']=any(row.get('nonempty_translation_blocks',0)>0 for row in report['content_checks'])
            if report['existing_translated_text_confirmed']: report['result']='TRANSLATION_EXISTING_CONTENT_VERIFIED'
            if args.lua_command:
                encoded=json.dumps(dict(samples=web.samples),ensure_ascii=False).encode()
                if len(encoded)>8*1024*1024: raise TranslationError('translation/model_input_limit')
                child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=60)
                marker=b'\nWEREAD_TRANSLATION_RESULT='
                if child.returncode or len(child.stdout)>256*1024 or child.stdout.count(marker)!=1: raise TranslationError('translation/lua_model_failed')
                value=json.loads(child.stdout.split(marker)[1])
                if not isinstance(value.get('samples'),list) or len(value['samples'])!=len(web.samples): raise TranslationError('translation/lua_model_mismatch')
                for actual,sample in zip(value['samples'],web.samples):
                    if actual.get('blocks')!=sample['expected_blocks']: raise TranslationError('translation/lua_model_mismatch')
                report['lua_translation_model']=value['samples']


    except (StoreError,ProbeError,PreflightError,TranslationError,DiscoveryError) as exc: report.update(result='UNVERIFIED',reason=str(exc))
    except Exception: report.update(result='UNVERIFIED',reason='translation_preflight_failed')
    finally:
        if probe: report['stages']=[{key:row[key] for key in ('stage','status','error_code') if key in row} for row in probe.report['stages']]
        if credentials: credentials.clear()
        if web:
            report['web_stages']=web.report['stages']
            web.close()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('TRANSLATION_READ_PREREQUISITES_VERIFIED','TRANSLATION_EXISTING_CONTENT_VERIFIED') else 1


if __name__=='__main__': raise SystemExit(main())
