-- Private source/model comparison; no network, settings or screenshots.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local input=io.stdin:read(20*1024*1024+1)
local ok,result=pcall(function()
    assert(#input<=20*1024*1024)
    local payload=json.decode(input);input=nil
    assert(type(payload.samples)=='table' and #payload.samples>=1 and #payload.samples<=8)
    local Source=require('weread.lib.source_coordinates')
    local Crypto=require('weread.lib.crypto')
    local results={}
    for _i,sample in ipairs(payload.samples) do
        assert(sample.source_format=='web_xhtml' or sample.source_format=='web_txt')
        local map=assert(Source.build(sample.source,{format=sample.source_format,allow_multiple_bodies=true}))
        local point=assert(map:locate(sample.source_text))
        local reverse=assert(map:anchor(point.co))
        assert(assert(map:locate_point(reverse.text,reverse.point_offset)).co==point.co)
        local _,count=sample.source:gsub('<body','')
        assert(count<=1 or Source.build(sample.source)==nil)
        results[#results+1]={source_raw_sha256=Crypto.sha256_hex(sample.source),source_sample_offset=point.co}
    end
    return results
end)
io.stdout:write('\nWEREAD_CB_READING_MODEL='..json.encode(ok and result or {error='model_unverified'})..'\n')
os.exit(ok and 0 or 1)
