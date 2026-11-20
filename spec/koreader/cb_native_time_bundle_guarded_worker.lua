-- Isolated native CB time task. The parent owns the one-shot claim and ACK.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local length=assert(io.stdin:read('*l'))
assert(length:match('^[1-9]%d*$') and tonumber(length)<=65536)
local input=json.decode(assert(io.stdin:read(tonumber(length))))
assert(type(input.token)=='string' and #input.token==32 and input.token:match('^[a-f0-9]+$'))
assert(type(arg[1])=='string' and type(arg[2])=='string' and type(arg[3])=='string')
local function emit(kind,value)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_'..kind..'='..json.encode(value)..'\n');io.stdout:flush()
end
local function rpc(kind,extra)
    local value=extra or {};value.kind=kind;emit('STEP',value)
    local reply=json.decode(assert(io.stdin:read('*l')))
    assert(reply.kind==kind and type(reply.ok)=='boolean')
    return reply.ok
end
local worked,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));package.path=home..'/plugins/weread.koplugin/?.lua;'..arg[1]..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    local Contract=require('weread.lib.readtime_transfer_contract')
    assert(Contract.cb_id(input.book_id) and input.owner==input.grant.vid and input.cookies.wr_vid == input.owner)
    assert(type(input.months)=='table' and type(input.armed)=='boolean')
    local scope={vid=input.owner,epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value)
        return type(value)=='table' and value.vid==scope.vid and value.epoch==scope.epoch
    end,get=function(_self,key,default) if key=='cookies' then return input.cookies end;return default end}
    local credentials={read=function() return input.grant,1,nil,false end}
    local Client=require('weread.lib.client');local client=Client:new(settings)
    if input.mock_port~=nil then
        assert(type(input.mock_port)=='number' and input.mock_port%1==0 and input.mock_port>=1 and input.mock_port<=65535
            and input.owner=='900000' and input.book_id=='CB_SyntheticResume' and input.cookies.wr_skey=='mock_key'
            and input.grant.accessToken=='mock-native-access' and input.grant.refreshToken=='mock-native-refresh')
        local original=client.request
        function client:request(options)
            self.settings.mock_endpoint='http://127.0.0.1:'..input.mock_port
            local values={pcall(original,self,options)};self.settings.mock_endpoint=nil
            if not values[1] then error('guarded_cb_worker/mock_transport',0) end
            return unpack(values,2)
        end
    end
    local account=assert(require('weread.lib.native_position_contract').account_key(input.owner))
    local Ledger=require('weread.lib.offline_time_store');local Coverage=require('weread.lib.readtime_coverage')
    local ledger=Ledger:new(arg[2]);local coverage=Coverage:new(arg[2])
    assert(coverage:initialize()<=input.start_time)
    local queue=require('weread.lib.readtime_transfer_queue'):new{ledger=ledger,coverage=coverage}
    local offered=assert(queue:select(account,input.book_id,{allow_cb=true,historical=true}))
    local selection=assert(offered.selection);assert(selection.seconds==input.seconds)
    assert(rpc('selection',{selection=selection}),'guarded_cb_worker/selection')
    local Journal=require('weread.lib.readtime_transfer_store')
    local journal=Journal:new{coverage=coverage,ledger=ledger,codec=client}
    local months={};for month in pairs(input.months) do months[#months+1]=assert(tonumber(month)) end;table.sort(months)
    local guard=require('spec.koreader.native_time_http_guard').install(client,{
        grant=input.grant,book_id=input.book_id,chapter_uid=input.chapter_uid,imported=true,cookies=input.cookies,
        months=months,now=os.time,current=function() return true end,selection=function() return selection end,
        record=function() local record=assert(journal:pending(account));assert(record.phase=='claimed');return record end,
        rpc=function(kind,value)
            local allowed=rpc(kind,value)
            if kind=='claim' and not input.armed then return false end
            return allowed
        end})
    local native=assert(require('weread.lib.native_read_access').capture(settings,credentials))
    local web=assert(require('weread.lib.read_access').capture(settings))
    local references={{file=arg[3],chapter_uid=input.chapter_uid,chapter_idx=input.chapter_idx}}
    local result=require('weread.lib.readtime_transfer_task').run(client,settings,native,web,selection,references,journal,
        {account=account,experimental_cb=true,is_current=function() return true end})
    local pending=journal:pending(account)
    assert(type(result)=='table' and type(result.attempted)=='boolean' and type(result.acknowledged)=='boolean')
    emit('RESULT',{result='PASS',task_kind=result.kind,attempted=result.attempted,acknowledged=result.acknowledged,
        forwarded=guard.write_forwarded,local_phase=pending and pending.phase or 'none'})
end)
if not worked then
    local module,line
    if type(reason)=='string' then module,line=reason:match('([%w_%-]+%.lua):(%d+):') end
    emit('RESULT',{result='UNVERIFIED',failed_module=module or 'unknown',failed_line=tonumber(line) or 0})
    os.exit(1)
end
