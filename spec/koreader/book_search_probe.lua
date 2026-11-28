-- Private input and output transport for read-only search model comparison.
-- Never print account data, keywords, source text or coordinates.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local Search=require('weread.lib.book_search')
local bytes=io.stdin:read(8*1024*1024+1)
local ok,result=pcall(function()
    assert(#bytes<=8*1024*1024)
    local input=json.decode(bytes);bytes=nil
    local state,reason=Search.new(input.book,input.keyword,input.chapters,input.first)
    if not state then return {result='UNVERIFIED',reason=reason} end
    local keys,all_unverified={},true
    for _i,page in ipairs(input.pages) do
        local result,err=Search.accept(state,page)
        if not result then return {result='UNVERIFIED',reason=err} end
        for _j,hit in ipairs(result.hits) do
            keys[#keys+1]=hit.chapter_uid..':'..string.format('%.0f',hit.start)..':'..string.format('%.0f',hit.finish)
            all_unverified=all_unverified and hit.source_verified==false
        end
    end
    table.sort(keys);table.sort(input.expected_keys)
    local matches=#keys==#input.expected_keys
    if matches then for i,key in ipairs(keys) do if key~=input.expected_keys[i] then matches=false;break end end end
    return {result='PASS',pages=state.pages,hits=#keys,independent_results_match=matches,
        candidates_unverified=all_unverified,finished=state.finished}
end)
print('\nWEREAD_BOOK_SEARCH_MODEL='..json.encode(ok and result or {result='UNVERIFIED',reason='model_failure'}))
os.exit(ok and result.result=='PASS' and result.independent_results_match and result.candidates_unverified and 0 or 1)
