-- Existing official translated text only. No generation, mode or account writes.
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Archive=require('weread.lib.source_archive')
local DisplayArchive=require('weread.lib.translation_archive')
local Model=require('weread.lib.translation')
local Protocol=require('weread.lib.protocol')
local M={MAX_OUTPUT=48*1024*1024}
local function fail(reason) error('translation_fetch/'..reason,0) end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
function M.client(client,book,uid)
    local proxy=setmetatable({},{__index=client})
    local requests,asset_count,asset_bytes=0,0,0
    function proxy:request(options)
        local url,method=options.url,options.method or (options.body and 'POST' or 'GET')
        local allowed=method=='GET' and not options.body and (url==Protocol.reader_url(book.book_id) or url==Protocol.reader_url(book.book_id,uid))
        if method=='POST' and type(options.body)=='string' then
            local ok,value=pcall(client.json_decode,client,options.body)
            if ok and url=='https://weread.qq.com/web/book/chapterInfos' then allowed=equal(value,{bookIds={book.book_id}})
            elseif ok and type(url)=='string' and url:match('^https://weread%.qq%.com/web/book/chapter/e_[0-3]$') and book.psvts then
                local unsigned,count={},0
                local fields={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
                local valid=type(value)=='table'
                for k,v in pairs(valid and value or {}) do count=count+1;if not fields[k] then valid=false end;if k~='s' then unsigned[k]=v end end
                local stamp=valid and type(value.ct)=='string' and tonumber(value.ct)
                local nonce=valid and type(value.r)=='string' and tonumber(value.r)
                allowed=valid and count==10 and stamp and tostring(stamp)==value.ct and math.abs(os.time()-stamp)<=30
                    and nonce and nonce>=0 and nonce<=99980001 and tostring(nonce)==value.r and math.floor(math.sqrt(nonce))^2==nonce
                    and value.b==Protocol.e(book.book_id) and value.c==Protocol.e(uid) and value.ps==book.psvts
                    and value.pc==Protocol.e(stamp) and value.sc==1 and value.prevChapter==false
                    and value.st==(url:sub(-3)=='e_2' and 1 or 0) and value.s==Protocol.sign(Protocol.sorted_query(unsigned))
            end
        end
        if not allowed then fail('request_scope') end
        requests=requests+1;if requests>32 then fail('request_limit') end
        local copy={};for k,v in pairs(options) do copy[k]=v end
        copy.sensitive,copy.diagnostic_api=true,'translation_fetch'
        local chunks,bytes={},0
        copy.timeout={8,15}
        copy.sink=function(chunk)
            if not chunk then return 1 end
            bytes=bytes+#chunk;if bytes>6*1024*1024 then return nil,'translation_fetch_limit' end
            chunks[#chunks+1]=chunk;return 1
        end
        local _,code,headers,status=client:request(copy)
        if bytes>6*1024*1024 then fail('response_limit') end
        return table.concat(chunks),code,headers,status
    end
    -- Images are downloaded anonymously; redirects stay on the existing
    -- public asset allowlist, and every response has an enforced size bound.
    function proxy:get_binary(url)
        local function public(value)
            if type(value)~='string' or #value>8192 or value:find('[%z%c%s]') then return false end
            local host=value:match('^https://([^/]+)')
            return host and (host=='cdn.weread.qq.com' or host=='res.weread.qq.com'
                or host:match('^[%w-]+%.file%.myqcloud%.com$') or host:match('^[%w-]+%.image%.myqcloud%.com$'))~=nil
        end
        if not public(url) then fail('asset_scope') end
        asset_count=asset_count+1;if asset_count>256 or asset_bytes>=32*1024*1024 then fail('asset_limit') end
        local data=client:get_binary(url,{skip_cookie=true,persist_response_cookies=false,max_bytes=4*1024*1024,
            sensitive=true,diagnostic_api='translation_fetch_asset',on_redirect=function(_old,next_url) if not public(next_url) then fail('asset_scope') end end})
        if type(data)~='string' then fail('asset_limit') end
        asset_bytes=asset_bytes+#data;if asset_bytes>32*1024*1024 then fail('asset_limit') end
        return data
    end
    return proxy
end
local function document(raw) return raw:match('<body[%s>]') and raw or '<html><body>'..raw..'</body></html>' end
local function local_source(input,path)
    local uid=input.chapter_uid
    local headers=Archive.read(path,{[Identity.PATH]=Identity.MAX_BYTES,[Source.meta_path(uid)]=Source.MAX_META_BYTES})
    local original=headers and Identity.decode(headers[Identity.PATH])
    local metadata=headers and headers[Source.meta_path(uid)]
    local meta=metadata and Source.decode_metadata(metadata)
    if not original or not meta or original.book_id~=input.book_id or meta.chapter_uid~=uid or meta.format~='web_xhtml' then fail('source') end
    local values=Archive.read(path,{[Source.raw_path(meta.raw_sha256)]=Source.MAX_BYTES,[meta.render_path]=Source.MAX_RENDERED_BYTES})
    if not values or not Source.verify_snapshot{identity=original,book_id=input.book_id,chapter_uid=uid,metadata=metadata,
        raw=values[Source.raw_path(meta.raw_sha256)],rendered=values[meta.render_path]} then fail('source') end
    return Model.analyze(values[meta.render_path],uid,1,true),metadata,original
end
function M.saved(input,path)
    if path==input.path then fail('source') end
    local before,metadata=local_source(input,input.path)
    if metadata~=input.metadata then fail('source') end
    local after,_,identity=local_source(input,path)
    local profile=DisplayArchive.inspect(path,input.book_id)
    local info=require('libs/libkoreader-lfs').attributes(path)
    if not profile or profile.file_id~=identity.file_id or profile.blocks<1 or not info or info.size>M.MAX_OUTPUT then fail('output') end
    return {ok=true,bytes=info.size,blocks=profile.blocks,file_id=identity.file_id,
        target=Model.refresh_target(before,after,input.xpointer),chapter_uid=input.chapter_uid}
end
function M.run(client,settings,input,output)
    local book={book_id=input.book_id,title=input.title,author=input.author,cache_dir=input.directory}
    local uid=input.chapter_uid
    local meta=Source.decode_metadata(input.metadata)
    if not meta or meta.book_id~=book.book_id or meta.chapter_uid~=uid or meta.format~='web_xhtml' then fail('source') end
    local before,metadata=local_source(input,input.path)
    if metadata~=input.metadata then fail('source') end
    client=M.client(client,book,uid)
    Content.ensure_reader_state(client,book)
    local chapters,version=Content.fetch_catalog(client,book)
    local chapter
    for _,row in ipairs(chapters) do if tostring(row.chapterUid)==uid then if chapter then fail('catalog') end;chapter=row end end
    if not chapter then fail('catalog') end
    book.bookVersion=version
    local identity=Identity.capture(book)
    local raw,source=Content.fetch_chapter_xhtml(client,settings,book,chapter)
    if not source or source.format~='web_xhtml' then fail('format') end
    local profile=Model.analyze(document(raw),uid,1)
    if not profile or profile.blocks<1 then return {ok=false,reason='missing'} end
    local state={}
    local xhtml,assets=Content.finalize_single_chapter_content(client,settings,book,chapter,raw,state)
    local total=0
    for i,asset in ipairs(assets) do
        if i>256 or type(asset.data)~='string' or asset.path then fail('asset_limit') end
        total=total+#asset.data;if total>32*1024*1024 then fail('asset_limit') end
    end
    local css=Content.fetch_chapter_css(client,settings,book,chapter)
    local after=Model.analyze(document(xhtml),uid,1,true)
    if not after or after.blocks<1 then fail('content') end
    local target=Model.refresh_target(before,after,input.xpointer)
    -- Re-read the catalogue before saving; never relabel an old capture.
    local again,later=Content.fetch_catalog(client,book)
    if version~=later or not equal(chapters,again) then fail('catalog_changed') end
    Content.save_chapter_epub(settings,book,chapter,xhtml,assets,css,identity,source,output)
    local info=require('libs/libkoreader-lfs').attributes(output.path)
    if not info or info.size<1 or info.size>M.MAX_OUTPUT then fail('output') end
    local saved=DisplayArchive.inspect(output.path,book.book_id)
    if not saved or saved.blocks<1 then fail('output') end
    local read=Archive.read(output.path,{[Identity.PATH]=Identity.MAX_BYTES,[Source.meta_path(uid)]=Source.MAX_META_BYTES})
    local new_identity=read and Identity.decode(read[Identity.PATH])
    local new_meta=read and Source.decode_metadata(read[Source.meta_path(uid)])
    if not new_identity or not new_meta or saved.file_id~=new_identity.file_id or new_meta.file_id~=new_identity.file_id then fail('output') end
    return {ok=true,bytes=info.size,blocks=saved.blocks,pairs=saved.pairs,file_id=new_identity.file_id,
        chapter_uid=uid,raw_sha256=new_meta.raw_sha256,target=target,metadata=read[Source.meta_path(uid)],title=chapter.title}
end
return M
