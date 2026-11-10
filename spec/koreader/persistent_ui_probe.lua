-- Opt-in live owner UI + a new offline process. All generated files are tmpfs.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local mode=arg[1]
local report={result='UNVERIFIED',phase='init',mode=mode,anonymous_credentials=false,credential_file_audit=false,
    file_backed_sqlite=false,bookstore_readback=false,transport_guard_selftest=false,progress_display_matches=false,
    covers_visible=false,workers_reaped=false,preferences_readback=false,paged_shelf=false,
    shelf_books=0,shelf_groups=0,painted_views=0,cover_gets=0,progress_gets=0,cover_cells=0,cover_retries=0,
    progress_snapshots=0,known_progress=0,profile_files_audited=0,screenshots=0,forbidden_requests=0,request_counts={0,0},
    failed_line=0,progress_http_status=0,progress_fetch_result=0,progress_parse_result=0,progress_shape=0,
    denied_kind=0,denied_reason=0,cover_redirects=0,cover_http_redirects=0,redirect_address_kind=0}
local plugin,counters
local descriptors={}
local ok,reason=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'))
    assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-persistent%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin'
    local lfs=require('libs/libkoreader-lfs')
    assert(lfs.symlinkattributes(source,'mode')=='directory')
    assert((lfs.symlinkattributes(home..'/weread')~=nil)==(mode=='reopen'))
    local raw=assert(io.stdin:read(256*1024+1));assert(#raw<=256*1024)
    local input=json.decode(raw)
    local all_pages=input.all_shelf_pages==true
    assert(input.all_shelf_pages==nil or type(input.all_shelf_pages)=='boolean')
    if all_pages then
        assert(type(input.shelf_books)=='number' and input.shelf_books>=1 and input.shelf_books<=160)
        assert(type(input.expected_shelf)=='table')
        report.shelf_coverage={reference_books=0,regular_books=0,public_accounts=0,forward_pages=0,reverse_pages=0,
            unique_cells=0,progress_eligible=0,cover_eligible=0,partition_verified=false,
            reference_fields_match=false,page_cache_matches=false,boundaries_verified=false}
    end
    local grant=assert(input.credentials)
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$'))
    assert(type(input.book_id)=='string' and input.book_id:match('^[1-9]%d*$') and #input.book_id<=20)
    assert(type(input.cookies)=='table' and tostring(input.cookies.wr_vid)==grant.vid)
    assert(type(input.expected_metadata)=='table' and input.expected_metadata.bookId==input.book_id)
    package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    local LuaSettings=require('luasettings')
    G_reader_settings=LuaSettings:open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('screenshots disabled',0) end
    local UIManager=require('ui/uimanager')
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-persistent-probe',1));assert(fd>=0)
        descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local offset=0
        while offset<#bytes do
            local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset))
            assert(n>0);offset=offset+n
        end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=grant.vid,name=''},cookies=input.cookies,api_key=''}
    local scope_path=anonymous(auth)
    local saved={};for key,value in pairs(grant) do saved[key]=value end
    saved.epoch,saved.verified_at,saved.book_count=1,os.time(),input.shelf_books
    local grant_path=anonymous({revision=1,authorization=saved})
    local Settings=require('weread.lib.settings');local new_settings=Settings.new
    function Settings:new()
        local value=new_settings(self);assert(not value.mock_endpoint)
        -- Keep all production preference, book-index and BookStore file I/O.
        -- Only auth material is injected from anonymous descriptors and omitted
        -- from preference flushes; no collection backend is replaced.
        local flush=value.store.flush
        local secret_keys={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
        value.store.flush=function(store,...)
            local held={}
            for _i,key in ipairs(secret_keys) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(secret_keys) do store.data[key]=held[key] end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        if mode=='live' then
            value:set('shelf',{source='native',view_mode='cover',paginated=true,sort_order='time_desc'})
            value:set('home',{view_mode='cover',recent_limit=6});value:flush()
        end
        value.settings_file=scope_path
        assert(value.store.file==home..'/settings/weread.lua')
        return value
    end
    local Credentials=require('weread.lib.native_credentials');local new_credentials=Credentials.new
    function Credentials:new(settings,...)
        local value=new_credentials(self,settings,...);value.path=grant_path;return value
    end
    report.anonymous_credentials=true
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local memory=ffi.C.mmap(nil,131072,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    counters=ffi.cast('int *',memory)
    local Cookie=require('weread.lib.cookie')
    local cookie=Cookie.to_header(input.cookies)
    local native_urls={'https://i.weread.qq.com/shelf/sync','https://i.weread.qq.com/book/info?bookId='..input.book_id}
    local allowed,slot={},16
    for index,url in ipairs(native_urls) do allowed[url]={kind='native',slot=index-1} end
    local function classify(options)
        local h=options.headers or {};local rule=allowed[options.url]
        if not rule or mode~='live' or options.method~='GET' or options.body~=nil
            or options.skip_cookie~=true or options.persist_response_cookies~=false or options.sensitive~=true then return end
        if rule.kind=='native' then
            if h.vid==grant.vid and h.accessToken==grant.accessToken and not h.Cookie and not h.Authorization then return rule end
        elseif not h.vid and not h.accessToken and not h.Authorization then
            if rule.kind=='progress' and h.Cookie==cookie or rule.kind=='cover' and not h.Cookie then return rule end
        end
    end
    local permitted={url=native_urls[1],method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    if mode=='live' then assert(classify(permitted)) else assert(not classify(permitted)) end
    for _i,change in ipairs({'method','body','url','cookie','owner','token','persist','skip','sensitive'}) do
        local value={};for key,item in pairs(permitted) do value[key]=item end
        value.headers={vid=grant.vid,accessToken=grant.accessToken}
        if change=='method' then value.method='POST' elseif change=='body' then value.body='{}'
        elseif change=='url' then value.url=native_urls[1]..'?unexpected=1'
        elseif change=='cookie' then value.headers.Cookie='forbidden' elseif change=='owner' then value.headers.vid='0'
        elseif change=='token' then value.headers.accessToken='invalid' elseif change=='persist' then value.persist_response_cookies=true
        elseif change=='skip' then value.skip_cookie=false else value.sensitive=false end
        assert(not classify(value))
    end
    for _i,kind in ipairs({'progress','cover'}) do
        local url='https://probe.invalid/'..kind
        allowed[url]={kind=kind,slot=15}
        local value={url=url,method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
            headers=kind=='progress' and {Cookie=cookie} or {}}
        assert((classify(value)~=nil)==(mode=='live'))
        value.headers.accessToken=grant.accessToken;assert(not classify(value));value.headers.accessToken=nil
        value.headers.Authorization='forbidden';assert(not classify(value));value.headers.Authorization=nil
        value.headers.Cookie=kind=='progress' and 'invalid' or cookie;assert(not classify(value))
        allowed[url]=nil
    end
    report.transport_guard_selftest=true
    local Client=require('weread.lib.client');local request,binary=Client.request,Client.get_binary
    function Client:request(options)
        local rule=classify(options)
        local index=rule and (rule.kind=='cover' and 2 or rule.kind=='progress' and 3)
        local maximum=rule and rule.kind=='cover' and 2 or 1
        local global_limit=index==2 and (all_pages and 640 or 48) or (all_pages and 160 or 24)
        if not rule or counters[rule.slot]>=maximum or index and counters[index]>=global_limit then
            local kind=allowed[options.url] and allowed[options.url].kind
            counters[10]=kind=='native' and 1 or kind=='progress' and 2 or kind=='cover' and 3 or 0
            counters[11]=not allowed[options.url] and 1 or not rule and 2 or counters[rule.slot]>=maximum and 3 or 4
            counters[4]=counters[4]+1;error('persistent UI read scope rejected',0)
        end
        if rule.kind=='cover' and counters[rule.slot]>0 then counters[9]=counters[9]+1 end
        counters[rule.slot]=counters[rule.slot]+1
        if index then counters[index]=counters[index]+1 end
        local response,code,headers,status=request(self,options)
        if rule.kind=='progress' then counters[5]=tonumber(code) or 0 end
        return response,code,headers,status
    end
    function Client:get_binary(url,options)
        assert(options.max_bytes==3*1024*1024)
        options.on_redirect=function(previous,next_url)
            counters[12]=counters[12]+1
            local rule=allowed[previous]
            local URL=require('socket.url');local a,b=URL.parse(previous),URL.parse(next_url)
            local function address_kind(host)
                if type(host)~='string' then return false end
                local first,second,third,last=host:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
                if first then
                    first,second,third,last=tonumber(first),tonumber(second),tonumber(third),tonumber(last)
                    if first>255 or second>255 or third>255 or last>255 or first==0 or first==10 or first==127
                        or first>=224 or first==100 and second>=64 and second<=127 or first==169 and second==254
                        or first==172 and second>=16 and second<=31 or first==192 and (second==0 or second==168)
                        or first==198 and (second==18 or second==19 or second==51 and third==100)
                        or first==203 and second==0 and third==113 then return 2 end
                    return 1
                end
                if #host<=253 and host:match('^[a-zA-Z%d.-]+%.[a-zA-Z][a-zA-Z]+$')
                    and not host:match('%.local$') and not host:match('%.localhost$') and not host:match('%.internal$') then return 3 end
                return 4
            end
            local kind=b and address_kind(b.host) or 4;counters[15]=kind or 4
            local public=kind==1 or kind==3
            if not rule or rule.kind~='cover' or rule.redirect or not a or not b
                or b.scheme~='https' and b.scheme~='http' or not public
                or b.authority~=b.host or b.fragment or next_url:find('[%z%c%s]') then
                local host=b and type(b.host)=='string' and b.host:lower() or ''
                local domain=host:match('%.([a-z%-]+%.[a-z]+)$') or host:match('^([a-z%-]+%.[a-z]+)$')
                if domain and #domain<=80 then
                    ffi.copy(ffi.cast('char *',counters)+130816,domain,#domain);counters[14]=#domain
                end
                counters[10]=3
                counters[11]=not rule and 1 or rule.redirect and 2 or (not b or not b.host) and 3
                    or b.scheme~='https' and b.scheme~='http' and 4 or not public and 5
                    or b.authority~=b.host and 6 or b.fragment and 7 or 8
                counters[4]=counters[4]+1
                error('cover redirect outside probe scope',0)
            end
            if b.scheme=='http' then counters[13]=counters[13]+1 end
            -- A redirect aliases its originating cover's quota. Every fork
            -- receives fresh Lua tables; its shared slot must stay disjoint.
            allowed[next_url]={kind='cover',slot=rule.slot+16384,redirect=true}
        end
        return binary(self,url,options)
    end
    local Progress=require('weread.lib.shelf_progress');local fetch,parse=Progress.fetch,Progress.parse
    function Progress.parse(data,...)
        local value,why=parse(data,...)
        counters[7]=value and 1 or why=='unavailable' and 2 or why=='invalid' and 3 or 4
        counters[8]=type(data)~='table' and 1
            or data.errcode~=nil and tonumber(data.errcode)~=0 and 2
            or data.errCode~=nil and tonumber(data.errCode)~=0 and 2
            or data.succ~=nil and data.succ~=true and tonumber(data.succ)~=1 and 3
            or type(data.book)~='table' and 4 or data.book.progress==nil and 5
            or type(data.book.progress)~='number' and 6 or not value and why~='unavailable' and 7 or 0
        return value,why
    end
    function Progress.fetch(...)
        local value=fetch(...)
        counters[6]=value.stale and 1 or value.web_expired and 2 or value.failed and 3 or 4
        return value
    end
    local Plugin=dofile(source..'/main.lua')
    plugin=Plugin:new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkOnline,plugin.isNetworkConnected=function() return mode=='live' end,function() return mode=='live' end
    assert(plugin.settings:auth_scope_matches(plugin.settings:get_auth_scope()))
    assert(Credentials:new(plugin.settings):read().vid==grant.vid)
    report.preferences_readback=plugin.settings:get('shelf').view_mode=='cover'
        and plugin.settings:get('home').recent_limit==6
    assert(report.preferences_readback)
    local socket=require('socket')
    local function pump(predicate)
        local deadline=socket.gettime()+50
        while not predicate() do
            assert(socket.gettime()<deadline)
            UIManager:setInputTimeout(0);UIManager:handleInput();socket.sleep(.01)
        end
    end
    report.phase='shelf'
    if mode=='live' then
        local loaded=false
        plugin:refreshBookshelf(nil,{on_loaded=function(success) loaded=success end})
        pump(function() return not plugin.shelf_refreshing end)
        assert(loaded and plugin.shelf_active_source=='native')
    end
    local books=assert(plugin.library_db:getShelf());assert(#books==input.shelf_books)
    plugin:applyShelfSnapshot(books,assert(plugin.library_db:getShelfArchives()))
    report.shelf_books,report.shelf_groups=#books,#plugin.shelf_groups
    if all_pages then
        local coverage=report.shelf_coverage
        for _id in pairs(input.expected_shelf) do coverage.reference_books=coverage.reference_books+1 end
        assert(coverage.reference_books==#books)
        for _i,book in ipairs(books) do
            local expected=assert(input.expected_shelf[tostring(book.bookId)])
            assert(book.title==expected.title and (book.author or '')==expected.author and (book.cover or '')==expected.cover)
            if tostring(book.bookId):match('^[1-9]%d*$') then coverage.progress_eligible=coverage.progress_eligible+1 end
            if book.cover and book.cover~='' then coverage.cover_eligible=coverage.cover_eligible+1 end
        end
        coverage.regular_books,coverage.public_accounts=#plugin.shelf_regular,#plugin.shelf_mp
        assert(coverage.regular_books+coverage.public_accounts==coverage.reference_books)
        coverage.reference_fields_match=true
    end
    local function allow(url,kind)
        if not allowed[url] then slot=slot+1;assert(slot<12000);allowed[url]={kind=kind,slot=slot} end
    end
    for _i,book in ipairs(books) do
        local id=tostring(book.bookId)
        if id:match('^[1-9]%d*$') then allow('https://weread.qq.com/web/book/getProgress?bookId='..id,'progress') end
        local cover=book.cover
        if type(cover)=='string' and cover:match('^http://wx%.qlogo%.cn/') then cover='https://'..cover:sub(8) end
        if type(cover)=='string' and cover:match('^https://[%w.-]+/') and not cover:find('[%z%c%s]') then allow(cover,'cover') end
    end
    local db=assert(plugin.library_db:open())
    local _,name,file=db:rowexec('PRAGMA database_list')
    assert(name=='main' and file==plugin.library_db:databasePath() and lfs.symlinkattributes(file,'mode')=='file')
    db:close();report.file_backed_sqlite=true
    local seen_covers,seen_progress,seen_cells={},{},{}
    local manifest={pages={}}
    local manifest_path=home..'/full-shelf-pages.json'
    if all_pages and mode=='reopen' then
        local handle=assert(io.open(manifest_path,'rb'));local bytes=handle:read(1024*1024+1);handle:close()
        assert(#bytes<=1024*1024);manifest=json.decode(bytes);assert(type(manifest.pages)=='table')
    elseif all_pages then assert(not lfs.symlinkattributes(manifest_path)) end
    local function settled()
        local context=plugin.shelf_progress_context
        return not plugin.shelf_cover_job and not plugin.shelf_cover_pending
            and (not context or not context.request and not context.renewing)
    end
    local function paint(tag,reverse)
        pump(settled)
        local view=assert(plugin.shelf_view);assert(view.cover_mode)
        local visible=view:getVisibleBooks();local ids={}
        for _i,book in ipairs(visible) do ids[#ids+1]=tostring(book.bookId) end
        local progress=plugin.library_db:getShelfProgress(ids)
        local entries={}
        assert(#view._item_rows==#visible)
        for _i,row in ipairs(view._item_rows) do
            local book=row.book;local id=tostring(book.bookId)
            assert(tostring(visible[_i].bookId)==id)
            if allowed['https://weread.qq.com/web/book/getProgress?bookId='..id] then
                local snapshot=assert(progress[id]);assert(book._shelf_progress==snapshot.percent)
                seen_progress[id]=snapshot
            end
            if book.cover and book.cover~='' then
                assert(row._has_cover and plugin:getShelfCoverCache():pathFor(book));seen_covers[id]=true
            end
            if all_pages and tag then
                local expected=assert(input.expected_shelf[id])
                assert(book.title==expected.title and (book.author or '')==expected.author and (book.cover or '')==expected.cover)
                if not reverse then assert(not seen_cells[id]);seen_cells[id]=true end
                local cover_path=plugin:getShelfCoverCache():pathFor(book)
                local hash=''
                if cover_path then
                    local handle=assert(io.open(cover_path,'rb'));local bytes=handle:read('*a');handle:close()
                    hash=require('weread.lib.crypto').sha256_hex(bytes)
                end
                local snapshot=progress[id]
                entries[#entries+1]={id,book.title,book.author or '',book.cover or '',
                    snapshot and snapshot.percent or -1,snapshot and snapshot.unavailable==true or false,hash}
            end
        end
        if all_pages and tag then
            local key=tag..':'..view.page;local encoded=json.encode(entries)
            if mode=='live' then assert(not manifest.pages[key]);manifest.pages[key]=encoded
            else assert(manifest.pages[key]==encoded) end
        end
        UIManager:forceRePaint();report.painted_views=report.painted_views+1
    end
    if all_pages then
        local coverage=report.shelf_coverage
        for _i,tag in ipairs({'books','public_account'}) do
            local count=tag=='books' and #plugin.shelf_regular or #plugin.shelf_mp
            if count>0 then
                plugin:showShelfView(tag,nil,plugin.shelf_view,{page=1});paint(tag)
                local total=plugin.shelf_view.page_count
                if total>1 then report.paged_shelf=true end
                local first=plugin.shelf_view;first:onShelfSwipe(nil,{direction='east'});assert(plugin.shelf_view==first)
                coverage.forward_pages=coverage.forward_pages+1
                for page=2,total do
                    plugin.shelf_view:onShelfSwipe(nil,{direction='west'});paint(tag)
                    assert(plugin.shelf_view.page==page and plugin.shelf_view.page_count==total)
                    coverage.forward_pages=coverage.forward_pages+1
                end
                local last=plugin.shelf_view;last:onShelfSwipe(nil,{direction='west'});assert(plugin.shelf_view==last)
                if mode=='reopen' then
                    for page=total-1,1,-1 do
                        plugin.shelf_view:onShelfSwipe(nil,{direction='east'});paint(tag,true)
                        assert(plugin.shelf_view.page==page)
                        coverage.reverse_pages=coverage.reverse_pages+1
                    end
                end
            end
        end
        for _id in pairs(seen_cells) do coverage.unique_cells=coverage.unique_cells+1 end
        assert(coverage.unique_cells==coverage.reference_books)
        coverage.partition_verified,coverage.page_cache_matches,coverage.boundaries_verified=true,true,true
        if mode=='live' then
            local handle=assert(io.open(manifest_path,'wb'));assert(handle:write(json.encode(manifest)));assert(handle:close())
        end
    else
        plugin:showShelfView('books',nil,nil,{page=1});paint()
        if plugin.shelf_view.page_count>1 then
            plugin:showShelfView('books',nil,nil,{page=2});paint();report.paged_shelf=true
        end
    end
    report.phase='home';plugin:closeWeReadUI();plugin:showHome();paint()
    report.phase='book';plugin:closeWeReadUI()
    local target;for _i,book in ipairs(books) do if book.bookId==input.book_id then target=book end end
    assert(target);plugin:showBookRecord(target);pump(function() return not plugin.book_metadata_context end)
    local record=assert(plugin.settings:get_book(input.book_id))
    for key,value in pairs(input.expected_metadata) do
        assert((key=='bookId' and tostring(record.bookId or record.book_id) or record[key])==value)
    end
    assert(record.detail_source=='native' and plugin._book_detail_view.data.title==input.expected_metadata.title)
    assert(plugin._book_detail_view.data.intro==input.expected_metadata.intro)
    local file_record=assert(require('weread.lib.book_store').load(plugin.settings,input.book_id,{cache_dir=record.cache_dir}))
    for key,value in pairs(input.expected_metadata) do
        assert((key=='bookId' and tostring(file_record.bookId or file_record.book_id) or file_record[key])==value)
    end
    assert(lfs.symlinkattributes(record.cache_dir..'/metadata.json','mode')=='file')
    report.bookstore_readback=true
    UIManager:forceRePaint();report.painted_views=report.painted_views+1
    plugin:closeWeReadUI();pump(settled);plugin.settings:flush();G_reader_settings:flush()
    report.workers_reaped=settled()
    for _id in pairs(seen_covers) do report.cover_cells=report.cover_cells+1 end
    for _id,snapshot in pairs(seen_progress) do
        report.progress_snapshots=report.progress_snapshots+1
        if type(snapshot.percent)=='number' then report.known_progress=report.known_progress+1 end
    end
    assert(report.cover_cells>0 and report.progress_snapshots>0)
    report.covers_visible,report.progress_display_matches=true,true
    report.phase='audit'
    local secrets={grant.accessToken,grant.refreshToken,grant.deviceId}
    for _name,value in pairs(input.cookies) do secrets[#secrets+1]=value end
    local function audit(path)
        for entry in lfs.dir(path) do
            if entry~='.' and entry~='..' and not (path==home and entry=='plugins') then
                local filename=path..'/'..entry;local info=assert(lfs.symlinkattributes(filename))
                if info.mode=='directory' then audit(filename)
                elseif info.mode=='file' then
                    report.profile_files_audited=report.profile_files_audited+1
                    assert(report.profile_files_audited<=512 and info.size<=4*1024*1024)
                    local handle=assert(io.open(filename,'rb'));local bytes=handle:read('*a');handle:close()
                    for _i,value in ipairs(secrets) do if type(value)=='string' and #value>=8 then assert(not bytes:find(value,1,true)) end end
                else error('unexpected profile entry',0) end
            end
        end
    end
    audit(home);report.credential_file_audit=true
    assert(counters[4]==0)
    assert(counters[0]==(mode=='live' and 1 or 0) and counters[1]==(mode=='live' and 1 or 0))
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then
    report.request_counts={tonumber(counters[0]),tonumber(counters[1])}
    report.cover_gets,report.progress_gets,report.forbidden_requests=tonumber(counters[2]),tonumber(counters[3]),tonumber(counters[4])
    report.progress_http_status=tonumber(counters[5])
    report.progress_fetch_result,report.progress_parse_result=tonumber(counters[6]),tonumber(counters[7])
    report.progress_shape=tonumber(counters[8])
    report.cover_retries=tonumber(counters[9])
    report.denied_kind,report.denied_reason,report.cover_redirects=tonumber(counters[10]),tonumber(counters[11]),tonumber(counters[12])
    report.cover_http_redirects=tonumber(counters[13])
    report.redirect_address_kind=tonumber(counters[15])
    if counters[14]>0 and counters[14]<=80 then
        io.stderr:write('\nWEREAD_PUBLIC_COVER_DOMAIN='..ffi.string(ffi.cast('char *',counters)+130816,counters[14])..'\n')
        io.stderr:flush()
    end
    ffi.C.munmap(counters,131072)
end
for _i,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then
    report.result='UNVERIFIED'
    report.failed_line=tonumber(type(reason)=='string' and reason:match('persistent_ui_probe%.lua:(%d+):')) or 0
end
io.stdout:write('\nWEREAD_PERSISTENT_UI_RESULT='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
