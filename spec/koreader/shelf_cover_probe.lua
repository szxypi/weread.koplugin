-- Explicit real anonymous bitmap probe. Only synthetic labels are rendered.
-- Caller supplies a fresh tmpfs KO_HOME; no private URL/bitmap touches disk.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local report={result='UNVERIFIED',phase='init',anonymous_only=false,digest_matches=false,thumbnail_bounded=false,
    source_removed=false,worker_reaped=false,offline_reused=false,painted_cover=false,memory_profile=false,
    image_gets=0,screenshots=0,forbidden_requests=0}
local plugin,counters
local ok=pcall(function()
    local home,source=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_SOURCE'))
    assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-cover%-[%w_]+/profile$'))
    assert(source==home..'/plugins/weread.koplugin')
    local lfs=require('libs/libkoreader-lfs')
    assert(not lfs.symlinkattributes(home..'/weread') and not lfs.symlinkattributes(home..'/settings.reader.lua'))
    report.memory_profile=true
    report.phase='input'
    local raw=assert(io.stdin:read(16385));assert(#raw<=16384)
    local input=json.decode(raw)
    assert(type(input.url)=='string' and input.url:match('^https://') and #input.url<=8192)
    assert(type(input.bytes)=='number' and input.bytes>=16 and input.bytes<=3*1024*1024)
    assert(type(input.sha256)=='string' and #input.sha256==64 and input.sha256:match('^[a-f0-9]+$'))
    package.path=source..'/?.lua;'..package.path
    report.phase='setup'
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('screenshots disabled',0) end
    local UIManager=require('ui/uimanager')
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local memory=ffi.C.mmap(nil,64,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    counters=ffi.cast('int *',memory)
    report.phase='transport'
    local Client=require('weread.lib.client');local request,binary=Client.request,Client.get_binary
    function Client:request(options)
        local headers=options.headers or {}
        if options.url~=input.url or options.method~='GET' or options.body~=nil
            or not options.skip_cookie or options.persist_response_cookies~=false or not options.sensitive
            or headers.Cookie or headers.Authorization or headers.accessToken or headers.vid or counters[0]~=0 then
            counters[1]=counters[1]+1;error('cover scope rejected',0)
        end
        counters[0]=counters[0]+1
        return request(self,options)
    end
    function Client:get_binary(url,options)
        assert(options.max_bytes==3*1024*1024)
        local data=binary(self,url,options)
        assert(#data==input.bytes and require('weread.lib.crypto').sha256_hex(data)==input.sha256)
        counters[2]=1
        return data
    end
    local Plugin=dofile(source..'/main.lua')
    report.phase='plugin'
    plugin=Plugin:new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkOnline=function() return true end
    plugin.prepareShelfProgress=function() end;plugin.refreshVisibleShelfProgress=function() end
    local book={bookId='900001',title='封面验证',author='合成展示名称',cover=input.url}
    plugin:applyShelfSnapshot({book},{})
    report.phase='loading'
    plugin:showShelfView('books')
    assert(plugin.shelf_view.cover_mode and plugin.shelf_cover_job)
    local socket=require('socket');local deadline=socket.gettime()+35
    while plugin.shelf_cover_job do
        assert(socket.gettime()<deadline)
        UIManager:setInputTimeout(0);UIManager:handleInput();socket.sleep(.01)
    end
    assert(counters[0]==1 and counters[1]==0 and counters[2]==1)
    report.image_gets,report.forbidden_requests=tonumber(counters[0]),tonumber(counters[1])
    report.anonymous_only,report.digest_matches,report.worker_reaped=true,true,true
    report.phase='readback'
    local cache=plugin:getShelfCoverCache();local path=assert(cache:pathFor(book))
    local image=assert(require('ui/renderimage'):renderImageFile(path,false,nil,nil))
    assert(image:getWidth()>=1 and image:getWidth()<=300 and image:getHeight()>=1 and image:getHeight()<=450)
    image:free();report.thumbnail_bounded=true
    local files=0
    for name in lfs.dir(cache.dir) do
        if name~='.' and name~='..' then assert(name==cache:key(book)..'.thumb.png');files=files+1 end
    end
    assert(files==1 and not cache:sourcePathFor(book));report.source_removed=true
    UIManager:forceRePaint()
    assert(plugin.shelf_view._item_rows[1]._has_cover);report.painted_cover=true
    plugin.isNetworkOnline=function() return false end
    plugin:showShelfView('books',nil,plugin.shelf_view)
    UIManager:forceRePaint()
    assert(plugin.shelf_view._item_rows[1]._has_cover and not plugin.shelf_cover_job and counters[0]==1)
    report.offline_reused=true
    plugin:closeWeReadUI();report.result='PASS';report.phase='complete'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
-- Also reap an in-flight bitmap child if a probe assertion failed mid-load.
if plugin and plugin.shelf_cover_job then
    local job=plugin.shelf_cover_job
    local util=require('ffi/util')
    util.terminateSubProcess(job.pid)
    report.worker_reaped=util.isSubProcessDone(job.pid,true)
    if job.read_fd then util.readAllFromFD(job.read_fd) end
    plugin.shelf_cover_job=nil
end
if counters then
    report.image_gets,report.forbidden_requests=tonumber(counters[0]),tonumber(counters[1])
    ffi.C.munmap(counters,64)
end
io.write('\nWEREAD_COVER_RESULT='..json.encode(report)..'\n')
os.exit(ok and report.result=='PASS' and 0 or 1)
