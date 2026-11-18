-- Existing official translated text only. No generation, mode or account writes.
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Archive=require('weread.lib.source_archive')
local DisplayArchive=require('weread.lib.translation_archive')
local Model=require('weread.lib.translation')
local Protocol=require('weread.lib.protocol')
local M={MAX_OUTPUT=48*1024*1024,MAX_BOOK_SOURCE=16*1024*1024,MAX_BOOK_ASSETS=16*1024*1024,MAX_BOOK_CHAPTERS=2000,
    MAX_ANNOTATIONS=500,MAX_ANNOTATION_CHAPTERS=64}
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
        local signed_at
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
                if allowed then signed_at=stamp end
            end
        end
        if not allowed then fail('request_scope') end
        local copy={};for k,v in pairs(options) do copy[k]=v end
        copy.sensitive,copy.diagnostic_api=true,'translation_fetch'
        local chunks,bytes={},0
        copy.timeout={8,15}
        copy.sink=function(chunk)
            if not chunk then return 1 end
            bytes=bytes+#chunk;if bytes>6*1024*1024 then return nil,'translation_fetch_limit' end
            chunks[#chunks+1]=chunk;return 1
        end
        for attempt=1,2 do
            requests=requests+1;if requests>32 then fail('request_limit') end
            chunks,bytes={},0
            local ok,response,code,headers,status=pcall(client.request,client,copy)
            if bytes>6*1024*1024 then fail('response_limit') end
            local transient=ok and (code==502 or code==503 or code==504
                or code==nil and (status=='timeout' or status=='closed'))
                or not ok and response=='sensitive_request_failed'
            if attempt==1 and transient then
                require('socket').sleep(1)
                -- Signed chapter reads are short-lived. Never reuse a request
                -- outside the same freshness window after the backoff.
                if signed_at and math.abs(os.time()-signed_at)>30 then
                    if not ok then error(response,0) end
                    return table.concat(chunks),code,headers,status
                end
            else
                if not ok then error(response,0) end
                return table.concat(chunks),code,headers,status
            end
        end
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
    local ordinal=meta.render_path=='OEBPS/text/chapter.xhtml' and 1
        or tonumber(meta.render_path:match('^OEBPS/text/chapter%-(%d+)%.xhtml$'))
    if not ordinal or ordinal<1 or ordinal>M.MAX_BOOK_CHAPTERS then fail('source') end
    return Model.analyze(values[meta.render_path],uid,ordinal,true),metadata,original,ordinal,meta
end
function M.saved(input,path)
    if path==input.path then fail('source') end
    local before,metadata=local_source(input,input.path)
    if metadata~=input.metadata then fail('source') end
    local after,_,identity,ordinal,meta=local_source(input,path)
    local profile=DisplayArchive.inspect(path,input.book_id)
    local info=require('libs/libkoreader-lfs').attributes(path)
    if not profile or profile.file_id~=identity.file_id or profile.blocks<1 or not info or info.size>M.MAX_OUTPUT
        or not profile.chapters[ordinal] or profile.chapters[ordinal].member_path~=meta.render_path then fail('output') end
    local target=Model.refresh_target(before,after,input.xpointer,ordinal)
        or '/body/DocFragment['..ordinal..']/body'
    return {ok=true,bytes=info.size,blocks=profile.blocks,file_id=identity.file_id,
        target=target,chapter_uid=input.chapter_uid}
end

-- Build pointer candidates from independently read EPUB members. The reader
-- must still verify every target node and quote before creating any annotation.
function M.plan_annotations(input,path,items,target_file_id)
    if path==input.path or type(items)~='table' or #items>M.MAX_ANNOTATIONS then fail('annotation_scope') end
    local profile=DisplayArchive.inspect(path,input.book_id)
    if not profile or profile.file_id~=target_file_id or profile.blocks<1 then fail('annotation_output') end
    local grouped,order={},{}
    local function include(uid,metadata,index,field,xp)
        if type(uid)~='string' or #uid==0 or #uid>256 or type(metadata)~='string' or #metadata>Source.MAX_META_BYTES
            or type(xp)~='string' or #xp>4096 then fail('annotation_scope') end
        local group=grouped[uid]
        if not group then
            if #order>=M.MAX_ANNOTATION_CHAPTERS then fail('annotation_limit') end
            group={metadata=metadata,items={}};grouped[uid]=group;order[#order+1]=uid
        elseif group.metadata~=metadata then fail('annotation_scope') end
        group.items[#group.items+1]={index=index,field=field,xp=xp}
    end
    for index,item in ipairs(items) do
        if type(item)~='table' then fail('annotation_scope') end
        include(item.uid,item.metadata,index,'first',item.first)
        if item.last~=nil then include(item.last_uid,item.last_metadata,index,'last',item.last)
        elseif item.last_uid~=nil or item.last_metadata~=nil then fail('annotation_scope') end
    end
    local endpoints={}
    for _,uid in ipairs(order) do
        local group=grouped[uid]
        local selected={book_id=input.book_id,chapter_uid=uid}
        local before,metadata,identity=local_source(selected,input.path)
        if metadata~=group.metadata or identity.file_id~=input.source_file_id then fail('annotation_source') end
        local ok,after,_,copy_id,ordinal,meta=pcall(local_source,selected,path)
        if ok and after and copy_id.file_id==target_file_id and profile.chapters[ordinal]
            and profile.chapters[ordinal].member_path==meta.render_path then
            for _,item in ipairs(group.items) do
                local point=Model.refresh_point(before,after,item.xp,ordinal)
                if point then
                    endpoints[item.index]=endpoints[item.index] or {}
                    endpoints[item.index][item.field]=point
                end
            end
        end
    end
    local mapped={}
    for index,item in ipairs(items) do
        local points=endpoints[index]
        if points and points.first and (not item.last or points.last) then
            mapped[#mapped+1]={index=index,uid=item.uid,first=points.first,last=points.last,last_uid=item.last_uid}
        end
    end
    return {ok=true,mapped=mapped,total=#items}
end

-- Fetch only existing translated content, and publish a complete independent
-- EPUB through the caller's exclusively owned descriptor. Any missing chapter,
-- changed catalog or limit failure aborts the whole copy rather than silently
-- producing a truncated book.
function M.run_book(client,settings,input,output)
    local book={book_id=input.book_id,title=input.title,author=input.author,cache_dir=input.directory}
    local before,metadata=local_source(input,input.path)
    if metadata~=input.metadata then fail('source') end
    local initial=M.client(client,book,input.chapter_uid)
    Content.ensure_reader_state(initial,book)
    local chapters,version=Content.fetch_catalog(initial,book)
    if #chapters<1 then fail('catalog') end
    if #chapters>M.MAX_BOOK_CHAPTERS then fail('chapter_limit') end
    local seen,current={},nil
    for index,chapter in ipairs(chapters) do
        local uid=tostring(chapter.chapterUid or '')
        if uid=='' or seen[uid] then fail('catalog') end
        seen[uid]=true
        if uid==input.chapter_uid then current=index end
    end
    if not current then fail('catalog') end
    book.bookVersion=version
    local identity=Identity.capture(book)
    local bodies,sources,assets,state,block_counts={}, {}, {}, {}, {}
    local source_bytes,asset_bytes,blocks,translated,target,css=0,0,0,0,nil,nil
    for index,chapter in ipairs(chapters) do
        local uid=tostring(chapter.chapterUid)
        local scoped=M.client(client,book,uid)
        local raw,source=Content.fetch_chapter_xhtml(scoped,settings,book,chapter)
        if not source or source.format~='web_xhtml' then fail('format') end
        source_bytes=source_bytes+#raw
        if source_bytes>M.MAX_BOOK_SOURCE then fail('source_limit') end
        local profile=Model.analyze(document(raw),uid,index)
        if not profile then fail('content') end
        block_counts[index]=profile.blocks
        blocks=blocks+profile.blocks
        if profile.blocks>0 then translated=translated+1 end
        if blocks>DisplayArchive.MAX_PAIRS then fail('content_limit') end
        local xhtml,chapter_assets=Content.finalize_single_chapter_content(scoped,settings,book,chapter,raw,state)
        source_bytes=source_bytes+#xhtml
        if source_bytes>M.MAX_BOOK_SOURCE then fail('source_limit') end
        for _,asset in ipairs(chapter_assets) do
            if #assets>=256 or type(asset.data)~='string' or asset.path then fail('asset_limit') end
            asset_bytes=asset_bytes+#asset.data
            if asset_bytes>M.MAX_BOOK_ASSETS then fail('asset_limit') end
            assets[#assets+1]=asset
        end
        if not css then css=Content.fetch_chapter_css(scoped,settings,book,chapter) end
        if index==current then
            local after=Model.analyze(document(xhtml),uid,index,true)
            if not after then fail('content') end
            target=Model.refresh_target(before,after,input.xpointer,index)
        end
        bodies[uid],sources[uid]=xhtml,source
    end
    if blocks<1 then return {ok=false,reason='missing'} end
    local again,later=Content.fetch_catalog(M.client(client,book,input.chapter_uid),book)
    if version~=later or not equal(chapters,again) then fail('catalog_changed') end
    Content.save_book_epub(settings,book,chapters,bodies,'translation',assets,css,nil,identity,sources,output)
    local info=require('libs/libkoreader-lfs').attributes(output.path)
    local profile=DisplayArchive.inspect(output.path,book.book_id)
    if not info or info.size<1 or info.size>M.MAX_OUTPUT or not profile or profile.blocks~=blocks
        or #profile.chapters~=#chapters or not profile.chapters[current] then fail('output') end
    for index=1,#chapters do
        if profile.chapters[index].blocks~=block_counts[index] then fail('output') end
    end
    local headers=Archive.read(output.path,{[Identity.PATH]=Identity.MAX_BYTES,[Source.meta_path(input.chapter_uid)]=Source.MAX_META_BYTES})
    local result_identity=headers and Identity.decode(headers[Identity.PATH])
    local result_meta=headers and Source.decode_metadata(headers[Source.meta_path(input.chapter_uid)])
    if not result_identity or not result_meta or profile.file_id~=result_identity.file_id
        or result_meta.file_id~=result_identity.file_id or profile.chapters[current].member_path~=result_meta.render_path then fail('output') end
    return {ok=true,bytes=info.size,blocks=profile.blocks,chapters=#chapters,translated_chapters=translated,file_id=result_identity.file_id,
        chapter_uid=input.chapter_uid,matched=target~=nil,target=target or '/body/DocFragment['..current..']/body'}
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
