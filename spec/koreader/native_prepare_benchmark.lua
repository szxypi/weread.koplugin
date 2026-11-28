require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local baseline=assert(loadfile(arg[2]))()
local current=require('weread.lib.native_chapter_remote')
local Resources=require('weread.lib.native_chapter_resources')
local Crypto=require('weread.lib.crypto')
local original_prepare=Resources.prepare
local preparations=0
Resources.prepare=function(...) preparations=preparations+1;return original_prepare(...) end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not equal(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local image='\137PNG\r\n\26\n'..('synthetic image bytes'):rep(5000)
local text=('<p>这是用于模拟章节正文的中文段落，验证来源完整性及资源定位。</p>'):rep(5000)
local function source(kind)
    local picture=kind=='local_image' and '<img src="../cover.png"/>'
        or kind=='missing_local' and '<img src="../missing.png"/>'
        or kind=='remote_image' and '<img src="https://img.qq.com/a.png"/>' or ''
    local link=kind=='local_image' and '<link rel="stylesheet" href="../style/book.css"/>' or ''
    local body='<html><body>'..link..text..picture..'</body></html>'
    local assets=kind=='local_image' and {{source='cover.png',data=image,media_type='image/png'}} or {}
    local css=kind=='local_image' and 'p{background:url("../cover.png")}' or ''
    local styles=kind=='local_image' and {{source='style/book.css',data=css}} or {}
    return {book_id='42',chapter_uid='7',book_version=1,catalog_sha256=string.rep('a',64),
        source_channel='eink',coordinate_source_authoritative=false,is_text=false,unusable_resources=0,
        body=body,css=css,assets=assets,body_parts={{source='text/7.xhtml',data=body}},style_parts=styles}
end
local calls=0
local client={request=function(_,request)
    calls=calls+1
    assert(request.url=='https://img.qq.com/a.png' and request.skip_cookie)
    request.sink(image)
    return nil,200,{}
end}
local result={body_bytes=#text,preparations_per_run=3,runs=3,cases={}}
for _,kind in ipairs({'plain','local_image','missing_local','remote_image'}) do
    local input=source(kind)
    local options={is_current=function() return true end,allow_missing_images=kind=='missing_local'}
    local old=assert(baseline.complete(client,input,options))
    local new=assert(current.complete(client,input,options))
    assert(equal(old,new),'prepared chapter differs')
    local cases={}
    for _,case in ipairs({{'baseline',baseline},{'optimized',current}}) do
        local rows={}
        for _=1,3 do
            collectgarbage('collect');preparations,calls=0,0
            local start=os.clock()
            local output
            for _i=1,3 do output=assert(case[2].complete(client,input,options)) end
            local elapsed=os.clock()-start
            assert(equal(output,old),'prepared result changed')
            local expected=(case[1]=='baseline' or kind=='remote_image') and 6 or 3
            assert(preparations==expected,'unexpected preparation count')
            assert(calls==(kind=='remote_image' and 3 or 0),'unexpected network requests')
            rows[#rows+1]={cpu_seconds=elapsed,preparations=preparations,requests=calls,
                body_sha256=Crypto.sha256_hex(output.xhtml)}
        end
        cases[case[1]]=rows
    end
    result.cases[kind]=cases
end
io.write('\nWEREAD_NATIVE_PREPARE_BENCHMARK='..require('json').encode(result)..'\n')
