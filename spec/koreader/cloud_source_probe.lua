-- Private source and credentials only enter through captured stdin memory.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-cloud-source-probe-settings.lua')
local Device=require('device')
require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local input=io.stdin:read(8*1024*1024+1)
local ok,result=pcall(function()
    assert(#input<=8*1024*1024)
    local payload=json.decode(input);input=nil
    local sample=payload.sample
    local Cloud=require('weread.lib.source_cloud')
    local output={model=Cloud.project(sample.book_id,sample.before,sample.reader,sample.source,sample.after,sample.source_format)}
    if payload.credentials then
        local credentials=payload.credentials
        local scope={vid=credentials.vid,epoch=1}
        local settings={get=function(_self,key,default) return key=='cookies' and credentials.cookies or default end,
            get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
        local client=require('weread.lib.client'):new(settings)
        local request,reads=client.request,0
        local Protocol=require('weread.lib.protocol')
        local allowed={['https://weread.qq.com/web/book/getProgress?bookId='..sample.book_id]='GET',
            [Protocol.reader_url(sample.book_id,output.model.chapter_uid)]='GET'}
        local shards=sample.source_format=='web_txt' and {'e_0','t_0','t_1'} or {'e_0','e_1','e_3'}
        for _,name in ipairs(shards) do allowed['https://weread.qq.com/web/book/chapter/'..name]='POST' end
        function client:request(options)
            assert(allowed[options.url]==options.method,'cloud_read_scope_required')
            reads=reads+1;assert(reads<=6)
            return request(self,options)
        end
        output.native=Cloud.fetch(client,sample.book_id)
        output.requests=reads
    end
    return output
end)
io.stdout:write('\nWEREAD_CLOUD_TARGET_RESULT='..json.encode(ok and result or {error='cloud_source_probe_failed'})..'\n')
os.exit(ok and 0 or 1)
