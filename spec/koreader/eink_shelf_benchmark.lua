-- Synthetic shelf repaint benchmark, with no account, network or private data.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json');local report={result='UNVERIFIED',phase='init'}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));local source=home..'/plugins/weread.koplugin'
    package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local BB=require('ffi/blitbuffer');local UI=require('ui/uimanager');local socket=require('socket')
    local Screen=Device.screen;local View=require('weread.ui.library_view');local render=require('ui/renderimage')
    local image_reads,scales=0,0;local old_read,old_scale=render.renderImageFile,render.scaleBlitBuffer
    function render:renderImageFile(...) image_reads=image_reads+1;return old_read(self,...) end
    function render:scaleBlitBuffer(...) scales=scales+1;return old_scale(self,...) end
    local books,paths={},{}
    for index=1,18 do
        local book={bookId=tostring(1000+index),title='合成书籍 '..index,author='测试作者',_shelf_progress=index*4}
        books[index]=book
        if index~=3 then
            local path=home..'/synthetic-cover-'..index..'.thumb.png'
            local bitmap=BB.new(300,450,BB.TYPE_BB8);bitmap:fill(BB.COLOR_WHITE)
            bitmap:paintRect(0,0,300,100,BB.COLOR_BLACK);bitmap:paintRect(20,140,260,120,BB.COLOR_GRAY)
            bitmap:paintRect(index*5,350,150,30,BB.COLOR_BLACK);bitmap:writePNG(path);bitmap:free();paths[book]=path
        end
    end
    local layout=View.getLayout(true,#books,'books',108,{store=true})
    local wall,cpu,draw=0,0,0;local cache_stats={}
    collectgarbage('collect');local lua_before=collectgarbage('count')
    for iteration=1,8 do
        local started=socket.gettime();local cpu_start=os.clock()
        local view=View.show({mode='books',title='合成书架',books=books,cover_paths=paths,paged=true,page=1,
            cover_mode=true,page_size=layout.page_size,cover_columns=layout.columns,cover_rows=layout.rows,
            navigation={{text='Home'},{text='Bookshelf'},{text='Bookstore'},{text='My WeRead'}}}, {})
        wall=wall+(socket.gettime()-started);cpu=cpu+(os.clock()-cpu_start)
        local paint_start=socket.gettime();UI:forceRePaint();draw=draw+(socket.gettime()-paint_start)
        if iteration==8 then Screen:shot(assert(os.getenv('WEREAD_BENCH_SHOTS'))..'/shelf.png') end
        UI:close(view)
        local cache_module=package.loaded['weread.lib.shelf_cover_bitmap_cache']
        if cache_module then
            local cache=cache_module.shared();local count=0
            for _ in pairs(cache.entries) do count=count+1 end
            cache_stats[#cache_stats+1]={bytes=cache.bytes,count=count}
        end
    end
    -- Exercise the real filesystem and hash implementation, including an
    -- in-place replacement with unchanged size and modification time.
    local module=package.loaded['weread.lib.shelf_cover_bitmap_cache']
    local invalidation_checked=false
    if module then
        local cache=module.shared();local lfs=require('libs/libkoreader-lfs')
        local path=home..'/invalidation.thumb.png'
        local function write(value) local f=assert(io.open(path,'wb'));assert(f:write(value));assert(f:close()) end
        write('abcd');local attributes=assert(lfs.attributes(path));local loads=0
        local function load() loads=loads+1;return BB.new(10,10,BB.TYPE_BB8) end
        cache:render(path,10,10,'crop',load):free()
        cache:render(path,10,10,'crop',load):free()
        assert(loads==1,'unchanged thumbnail should hit cache')
        write('wxyz');assert(lfs.touch(path,attributes.access,attributes.modification))
        local updated=assert(lfs.attributes(path))
        assert(updated.size==attributes.size and updated.modification==attributes.modification)
        cache:render(path,10,10,'crop',load):free()
        assert(loads==2,'changed content should invalidate cache')
        assert(os.remove(path));cache:render(path,10,10,'crop',load):free()
        assert(loads==3,'deleted thumbnail should not hit cache')
        cache:clear();assert(cache.bytes==0);invalidation_checked=true
    end
    collectgarbage('collect');local lua_after=collectgarbage('count')
    report={result='PASS',iterations=8,page_size=layout.page_size,width=Screen:getWidth(),height=Screen:getHeight(),
        initialization_wall_ms=math.floor(wall*1000+.5),initialization_cpu_ms=math.floor(cpu*1000+.5),
        paint_wall_ms=math.floor(draw*1000+.5),image_reads=image_reads,scales=scales,
        lua_kib_before=math.floor(lua_before),lua_kib_after=math.floor(lua_after),cache_stats=cache_stats,
        invalidation_checked=invalidation_checked}
end)
if not ok then report.reason=tostring(reason):gsub('[\r\n]',' '):sub(1,160) end
print('\nWEREAD_EINK_BENCHMARK='..json.encode(report))
os.exit(ok and 0 or 1)
