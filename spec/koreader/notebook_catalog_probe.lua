-- Isolated native plugin catalog acceptance. All private data stays in tmpfs and pipes.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1]
local report={result='UNVERIFIED',mode=mode,phase='init',anonymous_credentials=false,transport_guard=false,
    worker_heartbeat=false,native_filemanager=false,menu_navigation=false,search_sort=false,saved_note_search=false,file_sqlite=false,account_isolation=false,
    cache_session_free=false,workers_reaped=false,credential_audit=false,pages=0,books=0,requests=0,forbidden=0,failed_line=0}
local plugin,memory,counters,output;local descriptors={}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-notebook%-[%w_]+/profile$'))
    assert(mode=='live' or mode=='reopen')
    local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
    local input=json.decode(raw);local grant=assert(input.credentials);local synthetic=input.synthetic==true
    assert(synthetic==(os.getenv('WEREAD_NOTEBOOK_SYNTHETIC')=='1'))
    local real_samples=os.getenv('WEREAD_NOTEBOOK_SAVED_SAMPLES')=='1'
    assert(real_samples==(input.saved_samples~=nil) and not (synthetic and real_samples))
    local bulk_notes=os.getenv('WEREAD_NOTEBOOK_BULK')=='1'
    assert(bulk_notes==(input.bulk_notes==true) and not (bulk_notes and (synthetic or real_samples)))
    local owner_search=os.getenv('WEREAD_NOTEBOOK_OWNER_SEARCH')=='1'
    assert(owner_search==(input.search_cases~=nil))
    if synthetic then assert(grant.vid=='900000' and grant.accessToken=='synthetic-notebook-access'
        and grant.refreshToken=='synthetic-notebook-refresh' and grant.deviceId==string.rep('1',32)) end
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    local Data=require('weread.lib.notebook_catalog')
    local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
    local expected=Data.project(codec,input.source,input.now)
    assert(input.owner==grant.vid and #expected.books>0)
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-notebook',1));assert(fd>=0);descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local offset=0
        while offset<#bytes do
            local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(n>0);offset=offset+n
        end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=grant.vid,name=''},cookies={},api_key=''}
    local scope_path=anonymous(auth);local saved={}
    for key,v in pairs(grant) do saved[key]=v end
    saved.epoch,saved.verified_at,saved.book_count=1,os.time(),0
    local grant_path=anonymous{revision=1,authorization=saved}
    local Settings=require('weread.lib.settings');local new_settings=Settings.new
    function Settings:new()
        local value=new_settings(self);assert(not value.mock_endpoint)
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};local fields={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _i,key in ipairs(fields) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(fields) do store.data[key]=held[key] end
            assert(result[1]);return unpack(result,2)
        end
        for key,v in pairs(auth) do value.store:saveSetting(key,v) end
        value.settings_file=scope_path;return value
    end
    local Credentials=require('weread.lib.native_credentials');local new_credentials=Credentials.new
    function Credentials:new(settings,...)
        local value=new_credentials(self,settings,...);value.path=grant_path;return value
    end
    report.anonymous_credentials=true
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local target='https://i.weread.qq.com/user/notebooks?count=100'
    local bulk_urls,bulk_ids,seen={}, {},{}
    if bulk_notes then
        local marks=require('weread.lib.my_cloud_marks');local slot=16
        for _,book in ipairs(expected.books) do
            local id=marks.display_id(book.bookId)
            if id and not seen[id] then
                assert(#bulk_ids<64,'owner bulk acceptance scope exceeded')
                seen[id]=true;bulk_ids[#bulk_ids+1]=id
                bulk_urls['https://i.weread.qq.com/book/bookmarklist?bookId='..id..'&synckey=0']=slot;slot=slot+1
                for _,count in ipairs({20,40,80,160,320,640,1280,2560,5000}) do
                    bulk_urls['https://i.weread.qq.com/review/list?bookId='..id
                        ..'&listType=11&listMode=0&mine=1&synckey=0&count='..count]=slot;slot=slot+1
                end
            end
        end
        assert(#bulk_ids>0 and slot<1024)
        report.bulk_notes={books=#bulk_ids,saved=0,skipped=#expected.books-#bulk_ids,requests=0,
            menu_started=false,cache_verified=false,resume_checked=false,resume_requests=0}
    end
    local function allowed(options)
        local headers=options.headers or {}
        return mode=='live' and options.url==target and options.method=='GET' and options.body==nil
            and options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and headers.vid==grant.vid and headers.accessToken==grant.accessToken and not headers.Cookie and not headers.Authorization
    end
    local valid={url=target,method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    assert(allowed(valid)==(mode=='live'))
    for _,key in ipairs({'url','method','body','cookie','owner','token','authorization','skip','persist','sensitive'}) do
        local test={};for name,v in pairs(valid) do test[name]=v end
        test.headers={vid=grant.vid,accessToken=grant.accessToken}
        if key=='url' then test.url='https://i.weread.qq.com/login' elseif key=='method' then test.method='POST'
        elseif key=='body' then test.body='{}' elseif key=='cookie' then test.headers.Cookie='forbidden'
        elseif key=='owner' then test.headers.vid='0' elseif key=='token' then test.headers.accessToken='forbidden'
        elseif key=='authorization' then test.headers.Authorization='forbidden' elseif key=='skip' then test.skip_cookie=false
        elseif key=='persist' then test.persist_response_cookies=true else test.sensitive=false end
        assert(not allowed(test))
    end
    local function allowed_bulk(options)
        local slot=bulk_urls[options.url];local h=options.headers or {}
        if slot and mode=='live' and options.method=='GET' and options.body==nil
            and options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and h.vid==grant.vid and h.accessToken==grant.accessToken and not h.Cookie and not h.Authorization then return slot end
    end
    if bulk_notes then
        local valid_bulk={url='https://i.weread.qq.com/book/bookmarklist?bookId='..bulk_ids[1]..'&synckey=0',
            method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
            headers={vid=grant.vid,accessToken=grant.accessToken}}
        assert((allowed_bulk(valid_bulk)~=nil)==(mode=='live'))
        for _,key in ipairs({'url','method','body','cookie','owner','token','authorization','skip','persist','sensitive'}) do
            local test={};for name,v in pairs(valid_bulk) do test[name]=v end
            test.headers={vid=grant.vid,accessToken=grant.accessToken}
            if key=='url' then test.url=valid_bulk.url..'&extra=1' elseif key=='method' then test.method='POST'
            elseif key=='body' then test.body='{}' elseif key=='cookie' then test.headers.Cookie='forbidden'
            elseif key=='owner' then test.headers.vid='0' elseif key=='token' then test.headers.accessToken='forbidden'
            elseif key=='authorization' then test.headers.Authorization='forbidden' elseif key=='skip' then test.skip_cookie=false
            elseif key=='persist' then test.persist_response_cookies=true else test.sensitive=false end
            assert(not allowed_bulk(test))
        end
    end
    report.transport_guard=true
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        if allowed(options) and counters[0]<1 and tonumber(ffi.C.getpid())~=parent then
            counters[0]=counters[0]+1
            if synthetic then require('socket').sleep(.35);return json.encode(input.source),200 end
            return request(self,options)
        end
        local slot=allowed_bulk(options)
        local first=slot and counters[slot]==0
        local resume=slot==16 and counters[slot]==1 and counters[3]==1 and counters[4]==0
        if slot and (first or resume) and counters[2]<641 and tonumber(ffi.C.getpid())~=parent then
            counters[slot]=counters[slot]+1;counters[2]=counters[2]+1
            if resume then counters[4]=counters[4]+1 end
            return request(self,options)
        end
        counters[1]=counters[1]+1;error('notebook read scope rejected',0)
    end
    local fetch=Data.fetch
    function Data.fetch(client,access,options) options=options or {};options.now=input.now;return fetch(client,access,options) end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start;local workers={}
    function Worker:start(...)
        local result={start(self,...)}
        if self.job then workers[#workers+1]={pid=self.job.pid,runner=self.runner} end
        return unpack(result)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    assert(plugin.ui==FM.instance and not plugin.ui.document);report.native_filemanager=true
    plugin.isNetworkOnline=function() return mode=='live' end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local UI,socket=require('ui/uimanager'),require('socket')
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(predicate)
        local deadline=socket.gettime()+60
        while not predicate() do assert(socket.gettime()<deadline);tick() end
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for key,v in pairs(a) do if not same(v,b[key]) then return false end end
        for key in pairs(b) do if a[key]==nil then return false end end
        return true
    end
    report.phase='open'
    local tr=require('weread.lib.plugin_util').tr;local entry
    for _,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('My notebooks') then entry=item end end
    assert(entry and entry.callback);entry.callback()
    local owner=assert(plugin._notebook_owner);local menu=assert(plugin._notebook_menu)
    if mode=='live' then
        assert(owner.context and owner.worker.job)
        local heartbeat=false;UI:scheduleIn(.1,function() heartbeat=true end);wait(function() return heartbeat end)
        report.worker_heartbeat=true;wait(function() return not owner.context end)
    else assert(not owner.context and not owner.worker);report.worker_heartbeat=true end
    assert(same(owner.value,expected))
    if synthetic then
        dofile('/source/spec/koreader/notebook_bulk_case.lua')(plugin,owner,mode,counters,wait,tick)
    end
    if bulk_notes then
        dofile('/source/spec/koreader/notebook_owner_bulk_case.lua')(plugin,owner,mode,bulk_ids,counters,report.bulk_notes,home)
    end
    report.phase='views'
    for page=1,menu.page_num do menu:onGotoPage(page);UI:forceRePaint();report.pages=report.pages+1 end
    local positions={};for index,row in ipairs(menu.item_table) do if row.notebook_id then positions[#positions+1]=index end end
    assert(#positions==#expected.books)
    local FontSmoke=synthetic and assert(loadfile('/source/spec/koreader/thought_text_smoke.lua'))() or nil
    for index,book in ipairs(expected.books) do
        local position=positions[index];local item=menu.item_table[position]
        assert(item.text==book.title and item.mandatory==book.author)
        menu:onGotoPage(menu:getPageNumber(position));report.books=report.books+1
        if synthetic and index==1 then FontSmoke.menu_emoji(menu,'😀') end
        if synthetic and index==2 then FontSmoke.menu_emoji(menu,'🙂') end
    end
    -- Exercise each per-book destination without additional network requests.
    local chosen,position
    local Marks=require('weread.lib.my_cloud_marks')
    for index,book in ipairs(expected.books) do if Marks.display_id(book.bookId) then chosen=book;position=positions[index];break end end
    assert(chosen);plugin.isNetworkOnline=function() return false end
    for index,variant in ipairs({'highlights','thoughts','bookmarks'}) do
        menu:onGotoPage(menu:getPageNumber(position));menu:onMenuSelect(menu.item_table[position])
        local popup=assert(menu._shelf_popup);assert(#popup.buttons==3)
        popup.buttons[index][1].callback();local child=assert(plugin._my_marks_owner)
        assert(child.id==chosen.bookId and not child.context and (variant~='thoughts' or child.thoughts)
            and (variant~='bookmarks' or child.bookmarks));plugin:cancelMyCloudMarks()
    end
    report.menu_navigation=true
    local function item(label)
        for _,row in ipairs(menu.item_table) do if row.text==tr(label) then return row end end
        error('missing notebook control')
    end
    local Query=require('weread.lib.search_query');local Protocol=require('weread.lib.protocol')
    local query=Query.trim(Protocol.utf8_substr(Query.trim(chosen.title),4));assert(query~='')
    local request_count=counters[0]
    menu:onMenuSelect(item('Search notebooks'));local input_dialog=assert(menu._shelf_popup)
    input_dialog:setInputText(query);input_dialog.buttons[1][2].callback();tick()
    local found=false
    for _,row in ipairs(menu.item_table) do if row.notebook_id==chosen.bookId then found=true end end
    assert(found and owner.search==query and counters[0]==request_count);UI:forceRePaint()
    if synthetic then
        local combined=chosen.bookId..'　'..query..' 合成作者'
        menu:onMenuSelect(item('Search notebooks'));input_dialog=assert(menu._shelf_popup)
        input_dialog:setInputText(combined);input_dialog.buttons[1][2].callback();tick()
        local matching={};for _,row in ipairs(menu.item_table) do if row.notebook_id then matching[#matching+1]=row.notebook_id end end
        assert(#matching==1 and matching[1]==chosen.bookId and counters[0]==request_count,'notebook multiword search failed')
    end
    if owner_search then
        assert(type(input.search_cases)=='table' and #input.search_cases==3)
        for _,case in ipairs(input.search_cases) do
            assert(type(case.query)=='string' and type(case.expected)=='table')
            menu:onMenuSelect(item('Search notebooks'));input_dialog=assert(menu._shelf_popup)
            input_dialog:setInputText(case.query);input_dialog.buttons[1][2].callback();tick()
            local actual={};for _,row in ipairs(menu.item_table) do if row.notebook_id then actual[#actual+1]=row.notebook_id end end
            assert(same(actual,case.expected) and owner.search==case.query and counters[0]==request_count)
            UI:forceRePaint()
        end
        report.owner_search=true
    end
    menu:onMenuSelect(item('Search notebooks'));input_dialog=assert(menu._shelf_popup)
    input_dialog.buttons[1][1].callback();tick();assert(not owner.search)
    menu:onMenuSelect(item('Sort notebooks'));local sort=assert(menu._shelf_popup)
    sort.buttons[2][1].callback();tick();assert(owner.sort=='count')
    local by_id={};for index,book in ipairs(expected.books) do by_id[book.bookId]={book=book,index=index} end
    local previous_total,previous_index,seen_unknown=nil,nil,false;local count=0
    for _,row in ipairs(menu.item_table) do if row.notebook_id then
        local value=assert(by_id[row.notebook_id]);local book=value.book
        local total=book.noteCount~=nil and book.reviewCount~=nil and book.bookmarkCount~=nil
            and book.noteCount+book.reviewCount+book.bookmarkCount or nil
        if total then
            assert(not seen_unknown and (not previous_total or previous_total>=total))
            if previous_total==total then assert(previous_index<value.index) end
            previous_total,previous_index=total,value.index
        else seen_unknown=true end
        count=count+1
    end end
    assert(count==#expected.books and counters[0]==request_count);UI:forceRePaint()
    menu:onMenuSelect(item('Sort notebooks'));sort=assert(menu._shelf_popup)
    sort.buttons[1][1].callback();tick();assert(owner.sort=='original')
    local original={};for _,row_item in ipairs(menu.item_table) do if row_item.notebook_id then original[#original+1]=row_item.notebook_id end end
    for index,book in ipairs(expected.books) do assert(original[index]==book.bookId) end
    report.search_sort=true
    if synthetic and mode=='live' then
        local Saved=require('weread.lib.my_cloud_marks_store')
        local array=function() return plugin.client:json_decode('[]') end
        local marks={schema=1,book_id='900001',fetched_at=1000,chapters=array(),updated=array()}
        marks.updated[1]={bookmarkId='saved-mark-a',type=1,markText=string.rep('前',100)..' Synthetic needle in first book'}
        for index=1,205 do
            marks.updated[#marks.updated+1]={bookmarkId='page-note-'..index,type=1,markText='Pagination token '..index}
        end
        assert(Saved:new(plugin.library_db,plugin.client):write(marks))
        marks.book_id='900099';marks.updated=array()
        marks.updated[1]={bookmarkId='saved-mark-extra',type=1,markText='Synthetic needle in an extra cached book'}
        assert(Saved:new(plugin.library_db,plugin.client):write(marks))
        local thoughts={schema=1,book_id='900002',fetched_at=1000,reviews=array()}
        thoughts.reviews[1]={reviewId='saved-thought-b',content='😀 Synthetic needle in a thought',isPrivate=1}
        assert(Saved:new(plugin.library_db,plugin.client,'thoughts'):write(thoughts))
    end
    if real_samples and mode=='live' then
        local Saved=require('weread.lib.my_cloud_marks_store')
        assert(type(input.saved_samples)=='table' and #input.saved_samples==2)
        for _,sample in ipairs(input.saved_samples) do
            assert(sample.kind=='marks' or sample.kind=='thoughts')
            assert(Saved:new(plugin.library_db,plugin.client,sample.kind=='thoughts' and 'thoughts' or nil):write(sample.snapshot))
        end
    end
    local before_search=counters[0]
    menu:onMenuSelect(item('Search all saved notes'));input_dialog=assert(menu._shelf_popup)
    input_dialog:setInputText('synthetic needle');input_dialog.buttons[1][2].callback()
    wait(function() return not owner.note_search_job end)
    local results=assert(menu._shelf_popup);local found_notes={}
    for _,row in ipairs(results.item_table) do if row.saved_note_id then found_notes[row.saved_note_id]=row end end
    if synthetic then
        assert(found_notes['saved-mark-a'] and found_notes['saved-mark-extra'] and found_notes['saved-thought-b'])
        assert(found_notes['saved-mark-a'].text:find('Synthetic needle',1,true)
            and found_notes['saved-mark-a'].text:sub(1,3)=='…')
        for index,row in ipairs(results.item_table) do if row.saved_note_id=='saved-mark-a' then
            results:onGotoPage(results:getPageNumber(index));break
        end end
        local preview=assert(FontSmoke.menu_text(results,'Synthetic needle'))
        local chars=require('util').splitToChars(preview.text);local shown={}
        for _,glyph in ipairs(preview._xtext:shapeLine(preview._shape_start,preview._shape_end,preview._shape_idx_to_substitute_with_ellipsis)) do
            if not glyph.no_drawing and glyph.text_index~=preview._shape_idx_to_substitute_with_ellipsis then
                shown[glyph.text_index]=true
            end
        end
        local first
        for index,char in ipairs(chars) do if char=='S' then first=index;break end end
        assert(first and shown[first] and shown[first+1] and shown[first+2], 'matched text not visible in search result')
        local Model=require('weread.lib.notebook_search')
        local note=string.rep('前',100)..' ＨＥＬＬＯ café Straße '..string.rep('后',90)
        local store={list_ids=function() return {'900001'} end,read=function() return {
            chapters={},updated={{bookmarkId='normalized',markText=note}}} end}
        local empty={list_ids=function() return {} end}
        for _,case in ipairs({{'hello','ＨＥＬＬＯ'},{'café','café'},{'STRASSE','Straße'}}) do
            local match=Model.search({{bookId='900001'}},store,empty,case[1]).items[1]
            assert(match and match.preview:find(case[2],1,true) and match.preview:sub(1,3)=='…')
        end
        local combined=string.rep('文',125)..'é'..string.rep('文',94)..'e'..string.rep('文',30)
        local tricky={list_ids=store.list_ids,read=function() return {chapters={},updated={{bookmarkId='tricky',markText=combined}}} end}
        local match=Model.search({{bookId='900001'}},tricky,empty,'e').items[1]
        assert(match and require('weread.lib.shelf_search').contains(match.preview,'e'),
            'preview stopped at a transient combining-character match')
        for index,row in ipairs(results.item_table) do if row.saved_note_id=='saved-thought-b' then
            results:onGotoPage(results:getPageNumber(index));break
        end end
        FontSmoke.menu_emoji(results,'😀')
        results:onMenuSelect(found_notes['saved-thought-b'])
        local child=assert(plugin._my_marks_owner);local child_menu=assert(plugin._my_marks_menu)
        assert(child.id=='900002' and child.thoughts and child_menu._shelf_popup)
        assert(child_menu._shelf_popup.text:find('Synthetic needle in a thought',1,true))
        local note_viewer=child_menu._shelf_popup;UI:forceRePaint()
        assert(note_viewer.button_table:getButtonById('excerpt_card')):onTapSelectButton()
        wait(function() return plugin._excerpt_card_editor~=nil end)
        local card=assert(plugin._excerpt_card_editor)
        assert(card.context.book_title=='合成书籍 2' and card.context.book_author=='合成作者🙂',
            'notebook excerpt lost its own book metadata')
        assert(card.context.text=='😀 Synthetic needle in a thought' and child_menu._shelf_popup==card)
        local transfer=require('weread.lib.excerpt_transfer');local transfer_start=transfer.start
        transfer.start=function(png,options)
            options.address='127.0.0.1';options.allow_loopback=true
            return transfer_start(png,options)
        end
        assert(card.export_buttons:getButtonById('share_excerpt')):onTapSelectButton()
        local share=assert(plugin._excerpt_share,'notebook phone transfer did not open')
        assert(child_menu._shelf_popup==card,'sharing displaced notebook card')
        plugin:cancelMyCloudMarks();assert(not plugin._my_marks_owner)
        assert(not plugin._excerpt_card_editor and not plugin._excerpt_share and share.server.stopped,
            'closing notebook left its phone transfer open')
        transfer.start=transfer_start
        menu:onMenuSelect(item('Search all saved notes'));input_dialog=assert(menu._shelf_popup)
        input_dialog:setInputText('Pagination token');input_dialog.buttons[1][2].callback()
        wait(function() return not owner.note_search_job end);results=assert(menu._shelf_popup)
        local function result_row(label)
            for _,row in ipairs(results.item_table) do if row.text==tr(label) then return row end end
        end
        local more=assert(result_row('More results'));assert(not result_row('Previous results'))
        results:onMenuSelect(more);wait(function() return not owner.note_search_job end);results=assert(menu._shelf_popup)
        assert(result_row('Previous results') and not result_row('More results'))
        local ids={};for _,row in ipairs(results.item_table) do if row.saved_note_id then ids[#ids+1]=row.saved_note_id end end
        assert(#ids==5 and ids[1]=='page-note-201' and ids[5]=='page-note-205')
        results:onMenuSelect(result_row('Previous results'));wait(function() return not owner.note_search_job end)
        results=assert(menu._shelf_popup);assert(result_row('More results'))
        UI:close(results);tick();assert(not menu._shelf_popup and counters[0]==before_search)
    elseif real_samples then
        UI:close(results);tick()
        local Search=require('weread.lib.shelf_search')
        for _,sample in ipairs(input.saved_samples) do
            local rows=sample.kind=='thoughts' and sample.snapshot.reviews or sample.snapshot.updated
            local target_note,search_text,target_text
            for _,row in ipairs(rows) do
                for _,value in ipairs({row.content or '',row.markText or '',row.abstract or ''}) do
                    local candidate=Query.trim(Protocol.utf8_substr(Query.trim(value),4))
                    if Search.prepare(candidate) and Search.contains(value,Search.prepare(candidate)) then target_note,search_text,target_text=row,candidate,value;break end
                end
                if target_note then break end
            end
            assert(target_note and search_text)
            menu:onMenuSelect(item('Search all saved notes'));input_dialog=assert(menu._shelf_popup)
            input_dialog:setInputText(search_text);input_dialog.buttons[1][2].callback()
            wait(function() return not owner.note_search_job end);results=assert(menu._shelf_popup)
            local id=sample.kind=='thoughts' and target_note.reviewId or target_note.bookmarkId;local chosen_result
            for _,row in ipairs(results.item_table) do if row.saved_note_id==id and row.saved_book_id==sample.snapshot.book_id then chosen_result=row end end
            assert(chosen_result and counters[0]==before_search)
            results:onMenuSelect(chosen_result)
            local child=assert(plugin._my_marks_owner);local child_menu=assert(plugin._my_marks_menu)
            assert(child.id==sample.snapshot.book_id and child_menu._shelf_popup)
            assert(child_menu._shelf_popup.text:find(target_text,1,true))
            if sample.kind=='thoughts' then assert(child.thoughts) else assert(not child.thoughts) end
            plugin:cancelMyCloudMarks();assert(not plugin._my_marks_owner)
        end
    else
        if not bulk_notes then
        assert(not next(found_notes),'fresh private profile unexpectedly contained saved notes')
        end
        UI:close(results);tick()
    end
    assert(not menu._shelf_popup and counters[0]==before_search)
    report.saved_note_search=true
    local Store=require('weread.lib.notebook_catalog_store')
    assert(same(Store:new(plugin.library_db,plugin.client,plugin.library_db:accountKey()):read(),expected))
    local db=assert(plugin.library_db:open());local _,name,path=db:rowexec('PRAGMA database_list')
    assert(name=='main' and path==plugin.library_db:databasePath())
    local payload=db:rowexec("SELECT payload FROM profile_state WHERE name='notebook_catalog'");db:close()
    for _,field in ipairs({'accessToken','refreshToken','deviceId','synckey','userVid'}) do assert(not payload:find('"'..field..'"',1,true)) end
    report.file_sqlite,report.cache_session_free=true,true
    local other=require('weread.lib.library_db'):new{data_dir=plugin.settings.data_dir,get=function(_self,key,default)
        return key=='account' and {user_vid=grant.vid=='900099' and '900098' or '900099'} or default
    end}
    assert(other:databasePath()~=plugin.library_db:databasePath()
        and not Store:new(other,plugin.client,other:accountKey()):read());report.account_isolation=true
    local stale=menu.item_table[1].callback;plugin:closeWeReadUI();assert(not plugin._notebook_menu and not plugin._notebook_owner)
    stale();assert(not plugin._notebook_menu and not plugin.busy_message)
    plugin.settings:flush();G_reader_settings:flush()
    for _,worker in ipairs(workers) do wait(function() return worker.runner.done(worker.pid) end) end
    report.workers_reaped=true;report.phase='audit'
    local lfs=require('libs/libkoreader-lfs')
    local function audit(directory)
        for filename_part in lfs.dir(directory) do
            if filename_part~='.' and filename_part~='..' and not (directory==home and filename_part=='plugins') then
                local filename=directory..'/'..filename_part;local info=assert(lfs.symlinkattributes(filename))
                if info.mode=='directory' then audit(filename) else
                    assert(info.mode=='file' and info.size<=16*1024*1024)
                    local f=assert(io.open(filename,'rb'));local bytes=f:read('*a');f:close()
                    for _,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(not bytes:find(grant[key],1,true)) end
                end
            end
        end
    end
    audit(home);report.credential_audit=true
    assert(counters[0]==(mode=='live' and 1 or 0) and counters[1]==0)
    report.phase,report.result='complete','PASS';output={model=expected,native=owner.value,requests=tonumber(counters[0]),ui=report}
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then report.requests,report.forbidden=tonumber(counters[0]),tonumber(counters[1]);ffi.C.munmap(memory,4096) end
for _,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('notebook_catalog_probe%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_NOTEBOOK_RESULT='..json.encode(output or {ui=report})..'\n')
os.exit(ok and 0 or 1)
