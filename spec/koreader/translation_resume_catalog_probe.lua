-- Private catalogue data enters only through stdin. SQLite contains only
-- synthetic IDs/text and catalogue hashes; output contains aggregate facts.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local path=assert(arg[2])
assert(path:match('^/dev/shm/weread%-resume%-catalog%-[a-f0-9]+%.db$'))
local lfs=require('libs/libkoreader-lfs')
for _,suffix in ipairs({'','-wal','-shm'}) do assert(not lfs.symlinkattributes(path..suffix),'probe path already exists') end
local json=require('json')
local raw=io.stdin:read(12*1024*1024+1)
local ok,result=pcall(function()
    assert(raw and #raw<=12*1024*1024)
    local input=json.decode(raw);raw=nil
    assert(type(input.samples)=='table' and #input.samples>=1 and #input.samples<=3)
    local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
    local SQ3=require('lua-ljsqlite3/init')
    local library={settings={auth_scope_matches=function() return true end},accountKey=function() return 'synthetic' end,
        open=function() return SQ3.open(path) end}
    local store=require('weread.lib.translation_resume'):new(library,codec,{account='synthetic'})
    local content=require('weread.lib.content');local version=require('weread.lib.catalog_source_version')
    local out={samples=json.decode('[]')}
    for index,sample in ipairs(input.samples) do
        assert(type(sample.book_id)=='string' and sample.book_id:match('^[1-9]%d*$'))
        local first=content.readable_chapters(content.normalize_chapters(sample.first,sample.book_id))
        local second=content.readable_chapters(content.normalize_chapters(sample.second,sample.book_id))
        assert(#first>0 and #first<=2000 and #second>0 and #second<=2000)
        local a=assert(store:begin(tostring(900000+index),string.rep('a',64),first,version.read(sample.first,sample.book_id),false))
        assert(store:put(a,'synthetic','synthetic chapter'))
        local b=assert(store:begin(a.book_id,string.rep('a',64),second,version.read(sample.second,sample.book_id),true))
        local kept=store:get(b,'synthetic')=='synthetic chapter'
        out.samples[index]={chapters=#first,resumed=a.generation==b.generation,kept=kept}
        assert(store:clear(b))
    end
    return out
end)
for _,suffix in ipairs({'','-wal','-shm'}) do os.remove(path..suffix) end
io.stdout:write('\nWEREAD_RESUME_CATALOG='..json.encode(ok and result or {error='probe_failed'})..'\n')
os.exit(ok and 0 or 1)
