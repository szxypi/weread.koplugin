-- Read-only MP transport. Owner-approved Python probes cover body and CDN GETs.
local Content=require('weread.lib.content')
local Identity=require('weread.lib.mp_cache_identity')
local Access=require('weread.lib.read_access')
local Cookie=require('weread.lib.cookie')
local Protocol=require('weread.lib.protocol')
local Stage=require('weread.lib.mp_download_stage')
local Passive=require('weread.lib.mp_export')
local Output=require('weread.lib.notes_export_file')
local M={}
local function fail() error('mp_download/unavailable',0) end
local function scalar(value)
    if type(value)=='number' and value>=0 and value<=9007199254740991 and value%1==0 then value=string.format('%.0f',value) end
    return type(value)=='string' and #value<=512 and not value:find('[%z%c%s]') and value or nil
end
local function header(value)
    return type(value)=='string' and #value<=4096 and not value:find('[%z%c]') and value or nil
end
function M.capture(settings,book,article)
    local key=Identity.key(book,article)
    local access=Access.capture(settings)
    if not key or not Protocol.is_mp_book(book.book_id or book.bookId) or not access or not access.web then return nil end
    if article.title~=nil and (type(article.title)~='string' or #article.title>4096) then return nil end
    local ticket,wrpa=header(settings:get('wr_ticket','')),header(settings:get('wr_wrpa',''))
    if not ticket or not wrpa then return nil end
    local ids,seen={},{}
    local function add(value)
        if value==nil or value=='' then return end
        value=scalar(value);if not value or value=='' then fail() end
        if not seen[value] then ids[#ids+1]=value;seen[value]=true end
    end
    add(article.reviewId)
    if article.reviewIds~=nil then
        if type(article.reviewIds)~='table' or #article.reviewIds>8 then return nil end
        for _i,value in ipairs(article.reviewIds) do add(value) end
    end
    add(article.originalId)
    add((scalar(article.reviewId) or ''):match('^MP_WXS_%d+_(.+)$'))
    local id=scalar(article.bookId)
    if not id or id=='' then id=scalar(book.book_id or book.bookId) end
    local root=Content.book_resolved_dir(settings,book.book_id or book.bookId,book)
    if not Identity.path(root,key) or #ids<1 then return nil end
    return {key=key,root=root,access=access,ticket=ticket,wrpa=wrpa,ids=ids,
        book_id=book.book_id or book.bookId,article={title=article.title or 'Article'},
        referer=Protocol.mp_reader_url(id),images=settings:get('cache',{}).download_mp_images==true}
end
function M.matches(settings,input)
    return Access.matches(settings,input.access) and input.ticket==settings:get('wr_ticket','')
        and input.wrpa==settings:get('wr_wrpa','') and input.images==(settings:get('cache',{}).download_mp_images==true)
end
function M.refresh_access(settings,input)
    local access=Access.capture(settings)
    local ticket,wrpa=header(settings:get('wr_ticket','')),header(settings:get('wr_wrpa',''))
    if not access or not access.web or not ticket or not wrpa then return nil end
    local fresh={};for key,value in pairs(input) do fresh[key]=value end
    fresh.access=access;fresh.ticket=ticket;fresh.wrpa=wrpa;return fresh
end
function M.image_url(value)
    if type(value)~='string' or #value>4096 or value:find('[%z%c%s]') then return nil end
    if value:sub(1,2)=='//' then value='https:'..value end
    local host,path=value:match('^https?://([^/]+)(/[^#]*)')
    if host~='mmbiz.qpic.cn' and host~='mmbiz.qlogo.cn' then return nil end
    return 'https://'..host..path
end
local function body(client,input)
    for variant=1,2 do
        for _i,id in ipairs(input.ids) do
            local chunks,bytes,overflow={},0,false
            local headers={Cookie=Cookie.to_header(input.access.web.cookies),Accept='text/html,application/xhtml+xml,*/*',Referer=input.referer}
            if variant==1 then
                if input.ticket~='' then headers['x-wr-ticket']=input.ticket end
                if input.wrpa~='' then headers['x-wrpa-0']=input.wrpa end
            end
            local ok,_,code=pcall(client.request,client,{url='https://weread.qq.com/web/mp/content?reviewId='..Protocol.urlencode(id),
                method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,diagnostic_api='mp_read',timeout={10,20},
                headers=headers,sink=function(chunk)
                    if chunk then bytes=bytes+#chunk;if bytes>Stage.MAX_HTML then overflow=true;return nil,'response_limit' end;chunks[#chunks+1]=chunk end
                    return 1
                end})
            if overflow or code==429 then fail() end
            local text=table.concat(chunks)
            local login=ok and code==401
            if ok and code==200 and text:match('^%s*{') then
                local decoded,value=pcall(client.json_decode,client,text)
                if decoded and type(value)=='table' then
                    if value.errCode~=nil and value.errcode~=nil and value.errCode~=value.errcode then fail() end
                    login=value.errCode==-2012 or value.errcode==-2012
                    if value.errCode==-2041 or value.errcode==-2041 then error('mp_download/verification',0) end
                end
            end
            if login then
                if variant==1 and (input.ticket~='' or input.wrpa~='') then break end
                error('mp_download/login',0)
            end
            if ok and code==200 then
                local extracted=Content.extract_mp_body(text)
                if extracted and extracted~='' then return extracted end
            end
        end
    end
    fail()
end
function M.write(client,input,stage,labels)
    local revision=type(stage.version_name)=='string' and stage.version_name:match('^article%-([a-f0-9]+)%.html$')
    if not revision or #revision~=16 or not stage:images_owned() then fail() end
    local raw=body(client,input)
    local images,total,resolved=0,0,{}
    local function resolve(src)
        local url=M.image_url(src);if not url then return nil end
        if resolved[url] then return resolved[url] end
        if images>=Stage.MAX_IMAGES or not stage:images_owned() then fail() end
        local file=Output.create(stage.directory..'/images','bitmap','html');if not file then fail() end
        local size,head,failed=0,'',false
        local ok,_,code=pcall(client.request,client,{url=url,method='GET',skip_cookie=true,persist_response_cookies=false,
            sensitive=true,diagnostic_api='mp_image',timeout={10,20},headers={Accept='image/*',Referer='https://weread.qq.com/'},
            sink=function(chunk)
                if chunk then
                    size=size+#chunk
                    if size>Stage.MAX_IMAGE or total+size>Stage.MAX_TOTAL then failed=true;return nil,'response_limit' end
                    if #head<32 then head=(head..chunk):sub(1,32) end
                    if not file:write(chunk) then failed=true;return nil,'write_failed' end
                end
                return 1
            end})
        local media,ext=Passive.mime(head)
        if not ok or code~=200 or failed or not media or size<1 or not stage:images_owned()
            or not file:sync() or not file:accept(size) then file:abort();fail() end
        local name=string.format('img-%04d.%s',images+1,ext)
        if not os.rename(file.path,stage.directory..'/images/'..name) then file:abort();fail() end
        images=images+1;total=total+size
        resolved[url]=stage.generation..'/images/'..name;return resolved[url]
    end
    if not input.images then raw=Content.strip_mp_images(raw) end
    local converted,missing=Passive.convert('<html><body>'..raw..'</body></html>',resolve,require('util').htmlEntitiesToUtf8,labels.missing)
    local html=Content.render_mp_article_html(input.article,converted,input.key,revision)
    if #html>Stage.MAX_HTML or not stage:images_owned() or not stage.output:write(html) or not stage.output:sync() then fail() end
    return {ok=true,bytes=#html,images=images,image_bytes=total,missing=missing}
end
return M
