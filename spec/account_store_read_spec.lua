package.path='./?.lua;'..package.path
local Read=require('weread.lib.account_store_read')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function fixture()
    local s={account='one',tables={queue=true,labels=true},opened=0,closed=0,queries={},calls=0}
    local library={}
    function library:accountKey() return s.account end
    function library.openRead(_library)
        s.opened=s.opened+1
        if s.open_error then error('storage') end
        if s.no_connection then return nil end
        local db={}
        function db:set_busy_timeout(value) expect(value==50,'unbounded lock wait') end
        function db:close() s.closed=s.closed+1 end
        function db.prepare(_db,sql)
            expect(sql:find('sqlite_master',1,true),'unexpected schema lookup')
            local query={}
            function query:bind(name) self.name=name;return self end
            function query:step()
                s.queries[#s.queries+1]=self.name
                if s.switch_after_lookup then s.account='two' end
                if s.query_error then error('storage') end
                return s.tables[self.name] and {self.name} or nil
            end
            function query:close() end
            return query
        end
        return db
    end
    local function callback(_db,account)
        s.calls=s.calls+1;expect(account=='one','wrong account')
        if s.callback_error then error('corrupt') end
        if s.switch_after_read then s.account='two' end
        return s.value
    end
    return library,s,callback
end
local lib,s,callback=fixture();s.value={valid=true}
local value,reason,handled=Read.try(lib,{'queue','labels'},callback)
expect(handled and not reason and value==s.value and s.calls==1 and s.closed==1 and #s.queries==2,'complete schema was not read')
lib,s,callback=fixture();value,reason,handled=Read.try(lib,{'queue','labels'},callback)
expect(handled and not reason and value==nil and s.calls==1,'valid missing record triggered initialization')
lib,s,callback=fixture();s.tables.labels=nil;value,reason,handled=Read.try(lib,{'queue','labels'},callback)
expect(not handled and not reason and not value and s.calls==0 and s.closed==1,'missing legacy table did not request initialization')
for _,fault in ipairs({'query_error','callback_error','switch_after_read'}) do
    lib,s,callback=fixture();s[fault]=true;value,reason,handled=Read.try(lib,{'queue','labels'},callback)
    expect(handled and not value and reason=='storage' and s.closed==1,'unsafe read fell back: '..fault)
end
lib,s,callback=fixture();s.tables.labels=nil;s.switch_after_lookup=true
value,reason,handled=Read.try(lib,{'queue','labels'},callback)
expect(handled and not value and reason=='account' and s.calls==0,'legacy initialization crossed account')
for _,fault in ipairs({'no_connection','open_error'}) do
    lib,s,callback=fixture();s[fault]=true;value,reason,handled=Read.try(lib,{'queue'},callback)
    expect(not handled and not reason and not value and s.calls==0,'unavailable read-only connection did not allow original initialization')
end
lib,s,callback=fixture();s.account=nil;value,reason,handled=Read.try(lib,{'queue'},callback)
expect(handled and not value and reason=='account' and s.opened==0,'logged-out account opened storage')
print('account_store_read_spec: '..checks..' checks')
