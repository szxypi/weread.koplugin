-- Unicode case-folded search with exact original byte boundaries. Kept
-- separate from source-coordinate mapping: folded bytes never become offsets.
local ok, utf8proc = pcall(require, 'ffi/utf8proc')
local Dom = require('weread.lib.source_dom')
local normalized, canonical = pcall(require, 'weread.lib.unicode_normalize')
local M = {}

function M.available()
    return ok and type(utf8proc)=='table' and type(utf8proc.lowercase)=='function'
end

function M.canonical_available()
    return M.available() and normalized and type(canonical)=='table' and type(canonical.decompose)=='function'
        and type(canonical.is_combining)=='function'
end

local function scalar(value,at)
    local a,b,c,d=value:byte(at,at+3)
    if not a then return nil end
    if a<128 then return a,1 end
    local function tail(v) return v and v>=128 and v<=191 end
    if a>=194 and a<=223 and tail(b) then return (a-192)*64+b-128,2 end
    if a>=224 and a<=239 and tail(b) and tail(c) and (a~=224 or b>=160) and (a~=237 or b<160) then
        return (a-224)*4096+(b-128)*64+c-128,3
    end
    if a>=240 and a<=244 and tail(b) and tail(c) and tail(d)
        and (a~=240 or b>=144) and (a~=244 or b<=143) then
        return (a-240)*262144+(b-128)*4096+(c-128)*64+d-128,4
    end
    error('unicode_search/invalid_utf8')
end

local function marker()
    local cache,count={},0
    return function(cp)
        if not cp or cp<128 or not M.canonical_available() or type(canonical.is_combining)~='function' then return false end
        local found=cache[cp]
        if found~=nil then return found end
        local result=canonical.is_combining(cp)==true
        if count<2048 then cache[cp]=result;count=count+1 end
        return result
    end
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
        if M.canonical_available() then
            result=canonical.decompose(result)
            if type(result)~='string' then error('unicode_search/unavailable') end
        end
        -- Compatibility folding can itself introduce whitespace; the search
        -- contract ignores that whitespace just like the original source.
        result=Dom.normalize(result)
        if type(result)~='string' then error('unicode_search/unavailable') end
        if count<2048 then cache[value]=result;count=count+1 end
        return result
    end
end

local function each(value,at,fold,is_mark)
    local _,n=scalar(value,at)
    if not n then error('unicode_search/invalid_utf8') end
    local after=at+n
    -- Normalize a base and its following combining marks as one unit. This
    -- also makes canonical mark reordering independent of source encoding.
    while after<=#value do
        local cp,next_width=scalar(value,after)
        if not is_mark(cp) then break end
        after=after+next_width
    end
    return fold(value:sub(at,after-1)),after-at
end

-- Blocks bound the reverse lookup work and avoid one table per character on
-- a multi-megabyte chapter. `from` is always an original flattened byte index.
function M.build(value,from,keyword)
    if not M.available() then return nil end
    local fold,is_mark=folder(),marker()
    local words,word_at={},1
    while word_at<=#keyword do
        local mapped,n=each(keyword,word_at,fold,is_mark)
        words[#words+1]=mapped;word_at=word_at+n
    end
    local needle=table.concat(words)
    if needle=='' then return nil,'invalid' end
    local at=from
    while at<=#value and value:byte(at)>=128 and value:byte(at)<=191 do at=at+1 end
    -- Continuations are original byte offsets and may land inside a grouped
    -- base/mark sequence. Skip its remaining marks rather than repeat it.
    if at>1 and at<=#value and is_mark(scalar(value,at)) then
        while at<=#value do
            local cp,n=scalar(value,at)
            if not is_mark(cp) then break end
            at=at+n
        end
    end
    local pieces,block,blocks={}, {}, {}
    local length,count=0,0
    while at<=#value do
        if count==0 then blocks[#blocks+1]={byte=at,folded=length+1} end
        local mapped,n=each(value,at,fold,is_mark)
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
            local mapped,n=each(value,source,fold,is_mark)
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
