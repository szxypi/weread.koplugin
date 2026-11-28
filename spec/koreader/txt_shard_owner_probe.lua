-- Owner data comes only from a captured pipe; never print source or identity.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local raw=io.stdin:read(8*1024*1024+1)
local ok,result=pcall(function()
    assert(#raw<=8*1024*1024)
    local input=json.decode(raw);raw=nil
    assert(type(input)=='table' and type(input.t0)=='string' and type(input.t1)=='string' and type(input.plain)=='string')
    local Content=require('weread.lib.content')
    local cache_count=0
    Content.cache_annotation_source=function(_,_,_,value,is_raw)
        assert(value==input.plain and is_raw==true);cache_count=cache_count+1
    end
    local function client(fail)
        local out={json_encode=function() return '{}' end}
        function out:request(options)
            if options.url:match('/t_0$') then return input.t0,200 end
            assert(options.url:match('/t_1$'))
            if fail then return '{}',503 end
            return input.t1,200
        end
        return out
    end
    local book={book_id='900001',psvts='synthetic',_content_format='txt'}
    local html,source=Content.fetch_txt_as_xhtml(client(false),{},book,{chapterUid=1})
    assert(type(html)=='string' and source and source.raw==input.plain and cache_count==1)
    local success=pcall(Content.fetch_txt_as_xhtml,client(true),{},book,{chapterUid=1})
    assert(not success and cache_count==1)
    return {result='PASS',complete_source_matches=true,second_shard_failure_rejected=true,partial_source_not_cached=true}
end)
io.write('\nWEREAD_TXT_SHARD_RESULT='..json.encode(ok and result or {result='UNVERIFIED'})..'\n')
os.exit(ok and 0 or 1)
