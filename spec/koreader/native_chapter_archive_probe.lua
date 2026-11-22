-- Packages and credentials arrive only through a private in-memory pipe.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local raw=io.stdin:read(48*1024*1024+1)
local ok,result=pcall(function()
    assert(#raw<=48*1024*1024)
    local input=json.decode(raw);raw=nil
    assert(type(input.samples)=='table' and #input.samples>0 and #input.samples<=20)
    local archive=require('weread.lib.native_chapter_archive')
    local crypto=require('weread.lib.crypto')
    local out={samples=json.decode('[]')}
    for _,sample in ipairs(input.samples) do
        local success,value=pcall(archive.read,require('mime').unb64(sample.archive),sample.envelope,sample.vid,
            {chapter_uid=sample.chapter_uid})
        if success then
            local assets=json.decode('[]')
            for _,asset in ipairs(value.assets) do
                assets[#assets+1]={digest=crypto.sha256_hex(asset.data),mime=asset.media_type,
                    safe_href=asset.href:match('^images/native%-%d+%.[a-z]+$')~=nil,
                    parent_source=asset.source:find('../',1,true)~=nil}
            end
            out.samples[#out.samples+1]={ok=true,body_sha256=crypto.sha256_hex(value.body),
                css_sha256=crypto.sha256_hex(value.css),is_text=value.is_text,
                web_coordinate_authority=value.coordinate_source_authoritative,assets=assets,
                image_signatures_recognized=value.image_signatures_recognized,unusable_resources=value.unusable_resources}
        else
            out.samples[#out.samples+1]={ok=false}
        end
    end
    return out
end)
io.stdout:write('\nWEREAD_NATIVE_ARCHIVE_RESULT='..json.encode(ok and result or {error='probe_failed'})..'\n')
os.exit(ok and 0 or 1)
