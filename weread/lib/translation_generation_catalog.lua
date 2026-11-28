-- Native membership and catalogue projection for a single translation request.
-- This validates access evidence only; it does not authorize any write.
local Crypto=require('weread.lib.crypto')
local M={MAX_CHAPTERS=20000}
local function fail(reason) error('translation_catalog/'..reason,0) end
local function integer(value,low,high)
    return type(value)=='number' and value==value and value%1==0 and value>=low and value<=high
end
local function id(value)
    if type(value)=='number' and integer(value,1,9007199254740991) then value=string.format('%.0f',value) end
    return type(value)=='string' and #value<=20 and value:match('^[1-9]%d*$') and value or nil
end
local function array(value,maximum)
    if type(value)~='table' then fail('array') end
    local count=0
    for key in pairs(value) do
        if not integer(key,1,maximum) then fail('array') end
        count=count+1
    end
    if count>maximum then fail('array') end
    for i=1,count do if value[i]==nil then fail('array') end end
    return count
end
local function flag(value)
    if value==true or value==1 or value=='1' or value=='true' then return true end
    if value==false or value==0 or value=='0' or value=='false' then return false end
    fail('flag')
end
local function text(value,maximum)
    return type(value)=='string' and #value<=maximum and not value:find('[%z%c]')
end
local function successful(raw)
    if type(raw)~='table' then return false end
    for _,key in ipairs({'errcode','errCode','code'}) do
        if raw[key]~=nil and raw[key]~=0 then return false end
    end
    return raw.succ==nil or raw.succ==true or raw.succ==1
end
function M.membership(raw)
    if not successful(raw) or raw.isPaying==nil then fail('membership') end
    return {paying=flag(raw.isPaying)}
end
function M.catalog_body(book_id)
    if not id(book_id) or type(book_id)~='string' then fail('book') end
    return {bookIds={book_id},synckeys={0},updateTimes={0},maxfreeIdx={0}}
end
local function scalar(value)
    if value==nil then return 'z;' end
    local kind=type(value)
    if kind=='boolean' then return value and 't;' or 'f;' end
    if kind=='string' then return 's'..#value..':'..value end
    if kind=='number' and value==value and math.abs(value)<math.huge then
        return 'n'..(value==0 and '0' or string.format('%.17g',value))..';'
    end
    fail('scalar')
end
function M.catalog(raw,book_id,info,allow_txt)
    if type(book_id)~='string' or id(book_id)~=book_id or not successful(info) or id(info.bookId)~=book_id then fail('book') end
    if not successful(raw) or array(raw.data,4)<1 then fail('catalog') end
    local selected
    for _,row in ipairs(raw.data) do
        if type(row)~='table' then fail('catalog') end
        if id(row.bookId)==book_id then if selected then fail('catalog') end;selected=row end
    end
    if not selected or array(selected.updated,M.MAX_CHAPTERS)<1 then fail('catalog') end
    if selected.book~=nil and type(selected.book)~='table' then fail('catalog') end
    if selected.book and selected.book.bookId~=nil and id(selected.book.bookId)~=book_id then fail('book') end
    local book=selected.book or info
    local format=book.format
    if format==nil then format=info.format end
    local version=book.version
    if version==nil then version=info.version end
    local txt=allow_txt==true and format=='txt'
    if txt and version==nil then
        version=book.bookVersion
        if version==nil then version=info.bookVersion end
        if version==nil then version=0 end
    end
    if (format~='epub' and not txt) or not integer(version,0,2147483647) then fail('format') end
    local chapters,seen={},{}
    local parts={'native-translation-catalog-v1;',scalar(book_id),scalar(format),scalar(version)}
    for _,row in ipairs(selected.updated) do
        if type(row)~='table' then fail('chapter') end
        local uid=row.chapterUid
        if type(uid)=='string' and #uid<=16 and uid:match('^%d+$') and (uid=='0' or uid:sub(1,1)~='0') then uid=tonumber(uid) end
        if not integer(uid,0,9007199254740991) or seen[uid] then fail('chapter') end
        seen[uid]=true
        local clean={uid=uid,title=row.title}
        if clean.title~=nil and not text(clean.title,4096) then fail('title') end
        for _,key in ipairs({'wordCount','translateVersion','transWordCount'}) do
            if row[key]~=nil and not integer(row[key],0,9007199254740991) then fail('counter') end
            clean[key]=row[key]
        end
        if row.hasTranslated~=nil then clean.hasTranslated=flag(row.hasTranslated) end
        if row.price~=nil and (type(row.price)~='number' or row.price~=row.price or math.abs(row.price)>1e12) then fail('price') end
        if row.paid~=nil and not integer(row.paid,0,9007199254740991) then fail('paid') end
        clean.price,clean.paid=row.price,row.paid
        clean.free_or_owned=type(clean.price)=='number' and clean.price==0 or type(clean.paid)=='number' and clean.paid>0 or false
        chapters[#chapters+1]=clean
        for _,key in ipairs({'uid','title','wordCount','translateVersion','transWordCount','hasTranslated','price','paid'}) do
            parts[#parts+1]=scalar(clean[key])
        end
    end
    return {book_id=book_id,format=format,version=version,chapters=chapters,digest=Crypto.sha256_hex(table.concat(parts))}
end
function M.chapter(model,uid)
    if type(model)~='table' or type(model.chapters)~='table' or not integer(uid,1,2147483647) then fail('chapter') end
    local found
    for _,row in ipairs(model.chapters) do
        if row.uid==uid then if found then fail('chapter') end;found=row end
    end
    if not found or found.free_or_owned~=true or not integer(found.wordCount,200,9007199254740991)
        or found.translateVersion~=nil and not integer(found.translateVersion,0,2147483647) then fail('not_readable') end
    return found
end
return M
