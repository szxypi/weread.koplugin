-- Read-only binding of a current local EPUB chapter to two live source reads
-- and independently repeated native entitlement checks. No generation request.
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Archive=require('weread.lib.source_archive')
local Model=require('weread.lib.translation')
local Fetch=require('weread.lib.translation_fetch')
local Access=require('weread.lib.translation_generation_access')
local Native=require('weread.lib.native_read_access')
local Crypto=require('weread.lib.crypto')
local M={}
local function fail(reason) error('translation_source/'..reason,0) end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function current(settings,selected,options)
    if type(options.is_current)~='function' or not Native.matches(settings,selected) then return false end
    local ok,value=pcall(options.is_current);return ok and value==true
end
local function local_snapshot(input)
    local path=Source.meta_path(input.chapter_uid)
    local headers=Archive.read(input.path,{[Identity.PATH]=Identity.MAX_BYTES,[path]=Source.MAX_META_BYTES})
    local identity=headers and Identity.decode(headers[Identity.PATH])
    local metadata=headers and headers[path]
    local meta=Source.decode_metadata(metadata)
    if not identity or not meta or metadata~=input.metadata or identity.book_id~=input.book_id
        or identity.file_id~=input.file_id or meta.chapter_uid~=input.chapter_uid or meta.format~='web_xhtml' then fail('local_source') end
    local raw_path=Source.raw_path(meta.raw_sha256)
    local contents=Archive.read(input.path,{[raw_path]=Source.MAX_BYTES,[meta.render_path]=Source.MAX_RENDERED_BYTES})
    if not contents then fail('local_source') end
    local record=Source.verify_snapshot{identity=identity,book_id=input.book_id,chapter_uid=input.chapter_uid,
        metadata=metadata,raw=contents[raw_path],rendered=contents[meta.render_path]}
    if not record then fail('local_source') end
    return {raw_sha256=record.raw_sha256,file_id=identity.file_id,book_version=identity.book_version}
end
local function document(raw)
    return raw:match('<body[%s>]') and raw or '<html><body>'..raw..'</body></html>'
end
local function structural(title)
    if type(title)~='string' then return false end
    local value=title:lower():gsub('^%s+',''):gsub('%s+$','')
    local compact=value:gsub('%s+','')
    return value:match('%f[%a]copyright%f[%A]')~=nil or compact:find('版权',1,true)~=nil
        or compact=='目录' or compact=='封面' or compact=='封底' or compact=='扉页' or compact=='书名页'
        or value=='contents' or value=='table of contents' or value=='cover' or value=='front cover'
        or value=='back cover' or value=='title page'
end
local reasons={session_changed=true,local_source=true,catalog=true,catalog_changed=true,version=true,
    source_changed=true,missing_original=true,structural=true,unavailable=true}
function M.inspect(client,settings,selected,input,options)
    options=options or {}
    if type(options)~='table' or type(input)~='table' or type(input.book_id)~='string'
        or type(input.chapter_uid)~='string' or not input.chapter_uid:match('^[1-9]%d*$') or #input.chapter_uid>10
        or tonumber(input.chapter_uid)>2147483647 or type(input.path)~='string'
        or type(input.metadata)~='string' or type(input.file_id)~='string' then return nil,'unavailable' end
    local function owns() return current(settings,selected,options) end
    local ok,result=pcall(function()
        if not owns() then fail('session_changed') end
        local uid=tonumber(input.chapter_uid)
        local first=Access.inspect(client,settings,selected,input.book_id,uid,options)
        if not first then fail('unavailable') end
        if structural(first.title) then fail('structural') end
        local local_before=local_snapshot(input)
        if local_before.book_version>0 and local_before.book_version~=first.version then fail('version') end
        local book={book_id=input.book_id}
        local proxy=Fetch.client(client,book,input.chapter_uid)
        Content.ensure_reader_state(proxy,book)
        local chapters,version=Content.fetch_catalog(proxy,book)
        if type(version)~='number' or version<0 or version%1~=0
            or version>0 and version~=first.version then fail('version') end
        local chapter
        for _,row in ipairs(chapters) do
            if tostring(row.chapterUid)==input.chapter_uid then if chapter then fail('catalog') end;chapter=row end
        end
        if not chapter then fail('catalog') end
        local digest,available
        for _=1,2 do
            if not owns() then fail('session_changed') end
            local raw,source=Content.fetch_chapter_xhtml(proxy,settings,book,chapter)
            if type(raw)~='string' or #raw==0 or #raw>Model.MAX_HTML_BYTES or not source
                or source.format~='web_xhtml' or source.book_id~=input.book_id or source.chapter_uid~=input.chapter_uid
                or source.raw~=raw or source.raw_sha256~=Crypto.sha256_hex(raw) then fail('unavailable') end
            local profile=Model.analyze(document(raw),input.chapter_uid,1,false,true)
            if not profile or profile.recoveries>0 or profile.ambiguous_translation then fail('unavailable') end
            local found=profile.blocks>0
            if digest and (digest~=source.raw_sha256 or available~=found) then fail('source_changed') end
            digest,available=source.raw_sha256,found
            if not found and (profile.original_text_bytes or 0)<100 then fail('missing_original') end
        end
        local again,later=Content.fetch_catalog(proxy,book)
        if later~=version or not same(chapters,again) then fail('catalog_changed') end
        local last=Access.inspect(client,settings,selected,input.book_id,uid,options)
        if not last or not same(first,last) then fail('catalog_changed') end
        local local_after=local_snapshot(input)
        if not same(local_before,local_after) then fail('source_changed') end
        if not owns() then fail('session_changed') end
        if available then return {kind='available',book_id=input.book_id,chapter_uid=input.chapter_uid} end
        if local_before.raw_sha256~=digest then fail('source_changed') end
        return {kind='source_verified',book_id=input.book_id,chapter_uid=input.chapter_uid,
            source_sha256=digest,catalog_sha256=first.catalog_sha256,version=first.version,
            translate_version=first.translate_version,file_id=input.file_id}
    end)
    if ok then return result end
    local reason=type(result)=='string' and result:match('^translation_source/([a-z_]+)$')
    return nil,reasons[reason] and reason or 'unavailable'
end
return M
