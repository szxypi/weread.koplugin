-- Unicode case-folded search with exact original byte boundaries. Kept
-- separate from source-coordinate mapping: folded bytes never become offsets.
local ok, utf8proc = pcall(require, 'ffi/utf8proc')
local Dom = require('weread.lib.source_dom')
local M = {}

function M.available()
    return ok and type(utf8proc)=='table' and type(utf8proc.lowercase)=='function'
end

local function width(value,at)
    local lead=value:byte(at)
    if not lead then return nil end
    if lead<128 then return 1 end
    if lead>=194 and lead<=223 then return 2 end
    if lead>=224 and lead<=239 then return 3 end
    if lead>=240 and lead<=244 then return 4 end
    error('unicode_search/invalid_utf8')
end

local function folder()
    local cache,count={},0
    return function(value)
        if #value==1 then
            local byte=value:byte()
            return byte>=65 and byte<=90 and string.char(byte+32) or value
        end
        local found=cache[value]
        if found~=nil then return found end
        local result=utf8proc.lowercase(value,true)
        if type(result)~='string' then error('unicode_search/unavailable') end
        -- Compatibility folding can itself introduce whitespace; the search
        -- contract ignores that whitespace just like the original source.
        result=Dom.normalize(result)
        if type(result)~='string' then error('unicode_search/unavailable') end
        if count<2048 then cache[value]=result;count=count+1 end
        return result
    end
end

local function each(value,at,fold)
    local n=width(value,at)
    if not n or at+n-1>#value then error('unicode_search/invalid_utf8') end
    for i=at+1,at+n-1 do
        local byte=value:byte(i)
        if not byte or byte<128 or byte>191 then error('unicode_search/invalid_utf8') end
    end
    return fold(value:sub(at,at+n-1)),n
end

-- Blocks bound the reverse lookup work and avoid one table per character on
-- a multi-megabyte chapter. `from` is always an original flattened byte index.
function M.build(value,from,keyword)
    if not M.available() then return nil end
    local fold=folder()
    local words,word_at={},1
    while word_at<=#keyword do
        local mapped,n=each(keyword,word_at,fold)
        words[#words+1]=mapped;word_at=word_at+n
    end
    local needle=table.concat(words)
    if needle=='' then return nil,'invalid' end
    local at=from
    while at<=#value and value:byte(at)>=128 and value:byte(at)<=191 do at=at+1 end
    local pieces,block,blocks={}, {}, {}
    local length,count=0,0
    while at<=#value do
        if count==0 then blocks[#blocks+1]={byte=at,folded=length+1} end
        local mapped,n=each(value,at,fold)
        block[#block+1]=mapped;length=length+#mapped;count=count+1;at=at+n
        if count==512 then pieces[#pieces+1]=table.concat(block);block={};count=0 end
    end
    if count>0 then pieces[#pieces+1]=table.concat(block) end
    local folded=table.concat(pieces)
    local function locate(position)
        local lo,hi,best=1,#blocks,nil
        while lo<=hi do
            local mid=math.floor((lo+hi)/2)
            if blocks[mid].folded<=position then best=mid;lo=mid+1 else hi=mid-1 end
        end
        if not best then return nil end
        local source,flat=blocks[best].byte,blocks[best].folded
        while source<=#value do
            local mapped,n=each(value,source,fold)
            local last=flat+#mapped-1
            if #mapped>0 and position>=flat and position<=last then
                return source,n,position==flat,last
            end
            source,flat=source+n,last+1
        end
    end
    return {text=folded,needle=needle,locate=locate}
end

return M
