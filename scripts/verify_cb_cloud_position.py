#!/usr/bin/env python3
"""Read-only normal CB_ chapter, Web/native position and exact-source correlation."""
import argparse,json,re,subprocess
from datetime import datetime,timezone
from urllib.parse import urlsplit,parse_qs
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_cb_reading import CbReadingProbe
from verify_cb_progress import cb_ids
from verify_eink_login import NativeProbe,BASE as NATIVE
from verify_web_source_progress import BASE as WEB
from verify_translation_preflight import save_refreshed_web_session
from cb_cloud_position import state,observed,mapping
from source_remote_position import public_report


class Web(CbReadingProbe):
    def __init__(self):super().__init__();self.progress={}
    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage in ('progress_before','progress_after'):self.progress[(self.book_id,stage)]=value
        return value


class Native(NativeProbe):
    def __init__(self,credentials):super().__init__();self.allowed=set();self.used={};self.credentials=credentials
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        p=urlsplit(url);q=parse_qs(p.query)
        allowed=(p.path=='/shelf/sync' and not q or p.path=='/book/getProgress' and set(q)=={'bookId'} and len(q['bookId'])==1 and q['bookId'][0] in self.allowed)
        key=(p.path,p.query);limit=2
        if credentials!=self.credentials or body is not None or p.scheme!='https' or p.netloc!='i.weread.qq.com' or p.fragment or not allowed or self.used.get(key,0)>=limit:raise ValueError('cb_cloud/native_scope')
        self.used[key]=self.used.get(key,0)+1
        return super().request(stage,url,credentials=credentials,timeout=timeout)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--book-index',type=int,choices=range(1,9));p.add_argument('--source-lens',action='store_true');p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if (a.book_index is not None or a.source_lens) and not a.saved_session:p.error('source selection requires saved session')
    if a.lua_command is not None and (not a.saved_session or not a.lua_command):p.error('explicit session and private Lua command required')
    r=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,books=0,
           source_chapters=0,positions_unchanged=True,catalog_versions_unchanged=True,write_protocol_verified=False,private_data_on_regular_disk=False,channels=[])
    web=api=saved=grant=store=None;secrets=set();samples=[];phase='init'
    try:
        if a.saved_session:
            from verify_native_thought_trial import other_pending
            if other_pending():raise ValueError('cb_cloud/pending')
            store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid']);api=Native(grant);web=Web();web.vid=saved['vid']
            for k,v in saved['cookies'].items():web.set_cookie(k,v)
            secrets.update(str(v) for v in grant.values());secrets.update(saved['cookies'].values());secrets.add(web.vid)
            web.verify_account();phase='shelf'
            native_shelf=api.request('cb_cloud_shelf',NATIVE+'/shelf/sync',credentials=grant)
            ids=cb_ids(native_shelf);api.allowed=set(ids);web.allowed=set(ids)
            shelf=web.request('shelf',WEB+'/web/shelf/sync')
            if cb_ids(shelf)!=ids:raise ValueError('cb_cloud/shelf_changed')
            web.shelf_ids=[str(b['bookId']) for b in shelf['books']];web.shelf_count=len(shelf['books'])
            selected=ids
            if a.book_index is not None:
                if a.book_index>len(ids):raise ValueError('cb_cloud/book_index')
                selected=[ids[a.book_index-1]]
            for book in selected:
                phase='native_before';before=api.request('cb_cloud_before',NATIVE+'/book/getProgress?bookId='+book,credentials=grant)
                phase='source';sample=web.inspect(book);chapters=sample['chapters'];source=sample['source'];secrets.update((book,source,sample['source_text']))
                phase='native_after';after=api.request('cb_cloud_after',NATIVE+'/book/getProgress?bookId='+book,credentials=grant)
                if observed(before,book,chapters,'native')!=observed(after,book,chapters,'native'):raise ValueError('cb_cloud/native_changed')
                wb=web.progress[(book,'progress_before')];wa=web.progress[(book,'progress_after')]
                if observed(wb,book,chapters,'web')!=observed(wa,book,chapters,'web'):raise ValueError('cb_cloud/web_changed')
                pair={}
                for channel,raw in (('web',wb),('native',before)):
                    value=state(raw,book,chapters,channel);pair[channel]=value
                    samples.append(dict(raw=raw,book_id=book,chapters=chapters,channel=channel))
                    if value.get('summary'):secrets.add(value['summary'])
                    check=mapping(source,sample['chapter_uid'],value) if sample['source_format']=='web_xhtml' else None
                    row=dict(channel=channel,kind=value['kind'],reason=value.get('reason','none'),mapping=check)
                    if a.source_lens and value['kind']=='located' and value['chapter_uid']==sample['chapter_uid'] and sample['source_format']=='web_xhtml':
                        from cb_source_lens import compare
                        row['lens']=compare(source,value['chapter_offset'],value['summary'])
                    r['channels'].append(row)
                r['books']+=1;r['source_chapters']+=1
            phase='models'
            if a.lua_command:
                child=subprocess.run(a.lua_command,input=json.dumps(dict(samples=samples),ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180)
                marker=b'\nWEREAD_CB_CLOUD_POSITION='
                if child.returncode or child.stdout.count(marker)!=1 or len(child.stdout)>1024*1024:
                    r['lua_exit_code']=child.returncode;r['lua_frame_count']=min(child.stdout.count(marker),10)
                    r['lua_diagnostic']='environment' if b"module 'json' not found" in child.stderr else 'scope' if b'cb_cloud/scope' in child.stderr else 'unknown'
                    raise ValueError('cb_cloud/lua_frame')
                expected=[state(v['raw'],v['book_id'],v['chapters'],v['channel']) for v in samples]
                if json.loads(child.stdout.split(marker)[1])!=expected:raise ValueError('cb_cloud/lua_mismatch')
                r['python_lua_projection_matches']=True
            web.verify_account();save_refreshed_web_session(store,saved,web)
            if cb_ids(api.request('cb_cloud_shelf_after',NATIVE+'/shelf/sync',credentials=grant))!=ids:raise ValueError('cb_cloud/shelf_changed')
            r.update(result='CB_CLOUD_SOURCE_READ_OBSERVED',shelf_cb_identities_unchanged=True)
    except Exception as error:
        r.update(result='UNVERIFIED',failure_stage=phase)
        if re.fullmatch('cb_cloud/[a-z_]+',str(error)):r['reason']=str(error)
    finally:
        if web:
            if store and web.authenticated:
                try:save_refreshed_web_session(store,store.load(),web)
                except Exception:r['result']='UNVERIFIED'
            r['web_stages']=[{k:x[k] for k in ('stage','status') if k in x} for x in web.report['stages']];web.samples.clear();web.close()
        if api:r['native_stages']=[{k:x[k] for k in ('stage','status') if k in x} for x in api.report['stages']]
        for v in (saved,grant):
            if v:v.clear()
        samples.clear()
    r=public_report(r,secrets);print(json.dumps(r,indent=2));return int(r['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
