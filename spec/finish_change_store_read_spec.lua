package.path='./?.lua;'..package.path
local Store=require('weread.lib.finish_change_store')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local state={account='one',exists=true,closed=0,reads=0,writes=0}
    local library={}
    function library:accountKey() return state.account end
    local function connection(read_only)
        local db={}
        function db:set_busy_timeout(value)
            expect(read_only and value==50,'read-only lock wait was not bounded')
            if state.timeout_error then error('timeout configuration failed') end
            state.timeouts=(state.timeouts or 0)+1
        end
        function db:exec(sql)
            if read_only then error('read-only journal attempted a write or pragma') end
            if state.exec_error then error('storage error') end
            expect(sql=='PRAGMA synchronous=FULL' or sql:find('CREATE TABLE',1,true),'unexpected setup')
        end
        function db:close() state.closed=state.closed+1 end
        function db.prepare(_db,sql)
            if state.prepare_error then error('storage error') end
            local query={}
            function query:bind(...) return self end
            function query:step()
                if state.step_error then error('storage error') end
                if sql:find('sqlite_master',1,true) then
                    if state.account_during_lookup then state.account='two' end
                    return state.exists and {'finish_write_state'} or nil
                end
                if state.corrupt then return {1,'corrupt'} end
                return nil
            end
            function query:close() end
            return query
        end
        return db
    end
    function library:openRead()
        state.reads=state.reads+1
        if state.read_error then error('unavailable') end
        if state.read_missing then return nil end
        return connection(true)
    end
    function library:open() state.writes=state.writes+1;return connection(false) end
    local codec={json_decode=function() return {} end}
    return Store:new(library,codec),state,library
end
local store,s=fixture();local result=assert(store:read())
expect(result.phase=='idle' and result.account=='one' and s.reads==1 and s.writes==0 and s.closed==1 and s.timeouts==1,
    'existing journal did not use a read-only connection')
store,s=fixture();s.exists=false;result=assert(store:read())
expect(result.phase=='idle' and s.reads==1 and s.writes==1 and s.closed==2,'missing journal was not initialized')
store,s=fixture();s.read_missing=true;result=assert(store:read())
expect(result.phase=='idle' and s.writes==1 and s.closed==1,'missing database did not use initialization')
store,s=fixture();s.read_error=true;result=assert(store:read())
expect(result.phase=='idle' and s.writes==1,'unavailable read-only connection lacked existing fallback')
for _,fault in ipairs({'timeout_error','prepare_error','step_error','corrupt'}) do
    store,s=fixture();s[fault]=true;local value,reason=store:read()
    expect(not value and reason=='storage' and s.writes==0 and s.closed==1,'bad journal treated as empty: '..fault)
end
store,s=fixture();s.account_during_lookup=true
local value,reason=store:read();expect(not value and reason=='storage' and s.writes==0,'old account journal was accepted')
store,s=fixture();s.exists=false;s.account_during_lookup=true
value,reason=store:read();expect(not value and reason=='account' and s.writes==0,'fallback crossed account change')
store,s=fixture();s.account=nil;value,reason=store:read()
expect(not value and reason=='account' and s.reads==0 and s.writes==0,'logged-out account opened storage')
local library;store,s,library=fixture();library.openRead=nil;result=assert(store:read())
expect(result.phase=='idle' and s.writes==1,'library without read-only support lost its existing fallback')
print('finish_change_store_read_spec: '..checks..' checks')
