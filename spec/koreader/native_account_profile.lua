-- Anonymous account/grant descriptors for isolated owner-only UI probes.
-- This helper never opens a network route or persists login values.
local ffi=require('ffi');require('ffi/posix_h')
local M={fds={}}
function M.start(home,grant,count)
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-owner-probe',1));assert(fd>=0);M.fds[#M.fds+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local at=0
        while at<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+at,#bytes-at));assert(n>0);at=at+n end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=grant.vid,name=''},cookies={},api_key=''}
    local auth_path=anonymous(auth);local saved={};for key,value in pairs(grant) do saved[key]=value end
    saved.epoch,saved.verified_at,saved.book_count=1,os.time(),count
    local grant_path=anonymous{revision=1,authorization=saved}
    local Settings=require('weread.lib.settings');local factory=Settings.new
    function Settings:new()
        local value=factory(self);assert(not value.mock_endpoint)
        local flush=value.store.flush;local keys={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
        value.store.flush=function(store,...)
            local held={};for _i,key in ipairs(keys) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(keys) do store.data[key]=held[key] end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value:set('shelf',{source='native',view_mode='list',paginated=true});value:flush();value.settings_file=auth_path
        return value
    end
    local Credentials=require('weread.lib.native_credentials');local new=Credentials.new
    function Credentials:new(settings,...)
        local value=new(self,settings,...);value.path=grant_path
        value._write=function() error('owner_probe/authentication_changes_disabled',0) end
        return value
    end
    assert(home:match('^/dev/shm/'))
end
function M.close() for _i,fd in ipairs(M.fds) do ffi.C.close(fd) end;M.fds={} end
return M
