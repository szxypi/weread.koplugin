-- Read-only, account-bound observations for single-chapter translation.
-- No missing position or counter is converted into a zero-valued progress point.
local Crypto=require('weread.lib.crypto')
local Remote=require('weread.lib.remote_progress')
local Native=require('weread.lib.native_read_access')
local Web=require('weread.lib.read_access')
local Position=require('weread.lib.native_position_protocol')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local Auth=require('weread.lib.native_authorization')
local Contract=require('weread.lib.readtime_transfer_contract')
local M={MAX_BOOK_BYTES=256*1024,MAX_DEPTH=8,MAX_NODES=10000}
local BASE='https://i.weread.qq.com'
local COUNTERS={readingTime=true,recordReadingTime=true,ttsTime=true}
local FIELDS={'chapterUid','chapterId','chapter_uid','chapterIdx','chapterIndex','chapter_idx','chapterOffset','chapterPos','offset','chapter_offset',
    'progress','readingProgress','bookProgress','percent','summary','chapterTitle','readingTime','recordReadingTime','ttsTime'}
local function fail(reason) error('translation_baseline/'..reason,0) end
local function integer(value,low,high)
    return type(value)=='number' and value==value and value%1==0 and value>=low and value<=high
end
local function canonical(codec,value,check_counters)
    local null=codec:json_decode('null')
    local array_mt=getmetatable(codec:json_decode('[]'))
    local count=0
    local function encode(item,depth)
        count=count+1;if depth>M.MAX_DEPTH or count>M.MAX_NODES then fail('limit') end
        if null~=nil and item==null then return 'z;' end
        local kind=type(item)
        if kind=='boolean' then return item and 't;' or 'f;' end
        if kind=='string' then if #item>M.MAX_BOOK_BYTES then fail('limit') end;return 's'..#item..':'..item end
        if kind=='number' then
            if item~=item or math.abs(item)==math.huge then fail('number') end
            return 'n'..(item==0 and '0' or string.format('%.17g',item))..';'
        end
        if kind~='table' then fail('value') end
        local keys={};for key in pairs(item) do keys[#keys+1]=key end
        local parts={}
        if array_mt and getmetatable(item)==array_mt then
            for _,key in ipairs(keys) do if not integer(key,1,#item) then fail('array') end end
            if #keys~=#item then fail('array') end
            parts[1]='a'..#keys..':'
            for _,child in ipairs(item) do parts[#parts+1]=encode(child,depth+1) end
        else
            for _,key in ipairs(keys) do if type(key)~='string' then fail('object') end end
            table.sort(keys);parts[1]='m'..#keys..':'
            for _,key in ipairs(keys) do
                if check_counters and COUNTERS[key] and not integer(item[key],0,9007199254740991) then fail('counter') end
                parts[#parts+1]=encode(key,depth+1);parts[#parts+1]=encode(item[key],depth+1)
            end
        end
        local joined=table.concat(parts);if #joined>M.MAX_BOOK_BYTES then fail('limit') end
        return joined
    end
    return encode(value,0)
end
function M.observe(codec,raw,id,kind)
    if not Position.id(id) or type(id)~='string' or kind~='native' and kind~='web' or type(raw)~='table' then fail('input') end
    local point,reason,provided=Remote.project(raw,id,kind)
    local node,node_reason=Remote.node(raw,id)
    if point and node and not reason then
        if not provided.chapter_uid or not provided.chapter_offset then fail('position') end
        local fields={}
        for _,key in ipairs(FIELDS) do
            if node[key]~=nil then
                local value=node[key]
                if type(value)~='string' and type(value)~='number' then fail('position') end
                if COUNTERS[key] and not integer(value,0,9007199254740991) then fail('counter') end
                fields[key]=value
            end
        end
        if kind=='native' then Position.counts(node) end
        return {present=true,digest=Crypto.sha256_hex(canonical(codec,{point=point,provided=provided,fields=fields},true))}
    end
    if reason~='progress_not_found' or node_reason~='progress_not_found' then fail('position') end
    local keys={bookId=true,book=true,canFreeRead=true,timestamp=true};local count=0
    for key in pairs(raw) do if not keys[key] then fail('absence') end;count=count+1 end
    local array_mt=getmetatable(codec:json_decode('[]'))
    if count~=4 or Position.id(raw.bookId)~=id or type(raw.book)~='table' or next(raw.book)==nil
        or array_mt and getmetatable(raw.book)==array_mt
        or raw.book.bookId~=nil and Position.id(raw.book.bookId)~=id
        or not integer(raw.canFreeRead,0,1) or not integer(raw.timestamp,0,9007199254740991) then fail('absence') end
    return {present=false,digest=Crypto.sha256_hex(canonical(codec,{book=raw.book,canFreeRead=raw.canFreeRead},true))}
end
local function current(settings,selected,web,options)
    if not selected or selected.renewal_pending or not selected.scope or not Position.credentials(selected.credentials)
        or selected.scope.vid~=selected.credentials.vid or not web or not web.web or not web.web.cookies
        or tostring(web.web.cookies.wr_vid or '')~=selected.scope.vid or not Native.matches(settings,selected)
        or not Web.matches(settings,web) or type(options.is_current)~='function' then return false end
    local ok,value=pcall(options.is_current);return ok and value==true
end
function M.read(client,settings,selected,web,id,options)
    options=options or {}
    if type(options)~='table' or type(id)~='string' or not Position.id(id) or not current(settings,selected,web,options) then return nil,'unavailable' end
    local function owns() return current(settings,selected,web,options) end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=owns})
    local ok,result=pcall(function()
        local native=auth:_request('translation_progress',BASE..'/book/getProgress?bookId='..id,nil,selected.credentials)
        local remote=client:get_progress_snapshot(id,web.web,{fresh=true})
        local n=M.observe(client,native,id,'native');local w=M.observe(client,remote,id,'web')
        if n.present~=w.present then fail('mixed_presence') end
        local native_shelf=Shelf.state_hash(auth:read_shelf(selected.credentials))
        local web_shelf=Shelf.state_hash(client:get_web_shelf(web.web.cookies))
        if not owns() then fail('stale') end
        local value={contract='translation-baseline-v1',book_id=id,native=n,web=w,native_shelf=native_shelf,web_shelf=web_shelf}
        return {digest=Contract.digest(value),position_present=n.present}
    end)
    auth:cancel()
    if not ok then return nil,'unavailable' end
    return result
end
function M.stable(client,settings,selected,web,id,options)
    local first=M.read(client,settings,selected,web,id,options)
    if not first then return nil,'unavailable' end
    local second=M.read(client,settings,selected,web,id,options)
    if not second or second.digest~=first.digest or second.position_present~=first.position_present then return nil,'changed' end
    return second
end
return M
