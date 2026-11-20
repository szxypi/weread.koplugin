-- Test whether search ranges can be independently verified by the existing
-- highlight source mapper. Private text and coordinates never leave the pipe.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-book-search-target-settings.lua')
local Device=require('device')
require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(8*1024*1024+1)
local ok,result=pcall(function()
    assert(#bytes<=8*1024*1024)
    local input=json.decode(bytes);bytes=nil
    local mapper=require('weread.lib.book_search_target')
    local counts={result='PASS',total=0,verified=0,quote_changed=0,ambiguous=0,other=0,
        nonstandard_total=0,nonstandard_verified=0,verified_offset_matches=0}
    assert(type(input.hits)=='table' and #input.hits<=200)
    for _i,hit in ipairs(input.hits) do
        counts.total=counts.total+1
        if hit.nonstandard then counts.nonstandard_total=counts.nonstandard_total+1 end
        local candidate={chapter_uid=input.chapter,text=input.keyword,start=hit.start,finish=hit.finish,source_verified=false}
        local target,reason=mapper.project(input.raw,input.book,candidate)
        if target then
            counts.verified=counts.verified+1
            if hit.nonstandard then counts.nonstandard_verified=counts.nonstandard_verified+1 end
            if target.chapter_offset==hit.start then counts.verified_offset_matches=counts.verified_offset_matches+1 end
        elseif reason=='my_mark_target/quote_changed' then counts.quote_changed=counts.quote_changed+1
        elseif reason=='my_mark_target/ambiguous' or reason=='my_mark_target/unmatched' then counts.ambiguous=counts.ambiguous+1
        else counts.other=counts.other+1 end
    end
    return counts
end)
print('\nWEREAD_BOOK_SEARCH_TARGET='..json.encode(ok and result or {result='UNVERIFIED'}))
os.exit(ok and result.result=='PASS' and 0 or 1)
