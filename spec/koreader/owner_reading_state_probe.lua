-- Owner-authorized read-only comparison; private inputs stay on the pipe.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-reading-state-probe-settings.lua')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(2*1024*1024+1)
local stage,requests='input',0
local ok,result=pcall(function()
    assert(#bytes<=2*1024*1024)
    local input=json.decode(bytes);bytes=nil
    assert(type(input.samples)=='table' and #input.samples>=1 and #input.samples<=10)
    local selected={credentials=input.credentials,scope={vid=input.credentials.vid,epoch=1}}
    local Access=require('weread.lib.native_read_access')
    Access.matches=function(_settings,value) return value==selected end
    local Data=require('weread.lib.reading_state')
    local settings={get=function(_self,_key,default) return default end}
    local client=require('weread.lib.client'):new(settings)
    local allowed,seen={},{}
    for _,sample in ipairs(input.samples) do
        assert(Data.id(sample.book_id) and not allowed[sample.book_id])
        allowed[sample.book_id]=true
    end
    local request=client.request
    function client:request(options)
        local id=options.url:match('^https://i%.weread%.qq%.com/book/getProgress%?bookId=([A-Za-z0-9_]+)$')
        assert(id and allowed[id] and not seen[id] and options.method=='GET' and not options.body
            and options.skip_cookie and options.persist_response_cookies==false and options.sensitive
            and options.headers.vid==selected.scope.vid and options.headers.accessToken==selected.credentials.accessToken
            and not options.headers.Cookie and not options.headers.Authorization)
        seen[id]=true;requests=requests+1
        return request(self,options)
    end
    local model,native=json.decode('[]'),json.decode('[]')
    stage='model'
    for _,sample in ipairs(input.samples) do
        local flag,why=Data.project(sample.raw,sample.book_id,selected.scope.vid)
        assert(not why and type(flag)=='boolean')
        model[#model+1]=flag
    end
    stage='native'
    for _,sample in ipairs(input.samples) do
        local value=Data.read(client,settings,selected,sample.book_id)
        assert(value.kind=='known' and type(value.started)=='boolean')
        native[#native+1]=value.started
    end
    assert(requests==#input.samples)
    local output={model=model,native=native,requests=requests}
    if input.shelf then
        stage='contract'
        local Contract=require('weread.lib.reading_state_change_contract')
        for i,sample in ipairs(input.samples) do
            local plan=Contract.make(input.shelf,sample.raw,sample.book_id,selected.scope.vid,not model[i])
            assert(Contract.valid_metadata(plan.metadata) and Contract.unchanged(input.shelf,sample.raw,plan.metadata,selected.scope.vid))
            local changed=json.decode(json.encode(sample.raw));changed.book.isStartReading=model[i] and 0 or 1
            changed.book.startReadingTime=model[i] and 0 or 123
            assert(Contract.check(input.shelf,changed,plan.metadata,selected.scope.vid))
        end
        output.contract=true
    end
    return output
end)
io.stdout:write('\nWEREAD_OWNER_READING_STATE='..json.encode(ok and result or {error='probe_failed',stage=stage,requests=requests})..'\n')
os.exit(ok and 0 or 1)
