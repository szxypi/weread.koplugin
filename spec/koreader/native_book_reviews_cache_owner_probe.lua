-- Private input and tmpfs profile; never emit review contents or credentials.
require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local mode=assert(os.getenv('WEREAD_REVIEW_CACHE_MODE'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):wrap({language='zh_CN'})
require('gettext').changeLang('zh_CN')
local json,ffi=require('json'),require('ffi');local input=json.decode(assert(io.read('*a')))
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);local counter=ffi.cast('int *',memory);counter[0]=0
local phase,painted,heartbeat='setup',false,false
local ok=pcall(function()
    assert(memory~=ffi.cast('void *',-1))
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('screenshots_disabled',0) end
    local UI,socket=require('ui/uimanager'),require('socket')
    local book=assert(input.book_id);local vid=assert(input.vid)
    local scope={vid=vid,epoch=1}
    local settings={data_dir=home,get=function(_self,key,default)
        if key=='account' then return {user_vid=vid} end
        return default
    end,get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    local client=require('weread.lib.client'):new(settings);local original=client.request
    client.request=function(self,options)
        assert(mode=='online')
        local count=counter[0]==0 and 21 or 41
        local url='https://i.weread.qq.com/review/list?bookId='..book
            ..'&listType=3&listMode=1&synckey=0&count='..count..'&maxIdx=0&tips=1'
        assert(counter[0]<2 and options.url==url and options.method=='GET' and not options.body
            and options.sensitive and options.skip_cookie and not options.persist_response_cookies)
        counter[0]=counter[0]+1;return original(self,options)
    end
    local Source=require('weread.lib.native_book_reviews_source');local Model=require('weread.lib.native_book_reviews')
    local selected
    if mode=='online' then
        local grant=assert(input.credentials)
        selected=assert(Source.capture(settings,{read=function() return grant,1,nil,false end}))
    end
    local library=require('weread.lib.library_db'):new(settings)
    local host={settings=settings,client=client,library_db=library,_book_detail_view={},
        discovery_epoch=1,_reader_session_gen=1,ui={document={}}}
    function host:isNetworkOnline() return mode=='online' end
    function host:showBusy(_text,cancel) self.busy_message={};self.cancel_busy=cancel end
    function host:closeBusy() self.busy_message=nil end
    function host:showInfo() error('review_cache/info',0) end
    function host:runOnlineTask(_label,fn) UI:scheduleIn(.01,fn);return true end
    function host:showBookReviewDetail(_book,item,_mode,options)
        assert(not options.on_replies);self.chosen=item.review_id;return {options=options}
    end
    local function wait(predicate)
        local deadline=socket.gettime()+40
        while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline) end
    end
    local function compare(actual,expected)
        assert(#actual.items==#expected.items)
        for index,review in ipairs(actual.items) do
            local other=expected.items[index]
            for _,field in ipairs({'review_id','author','content','rating','create_time','is_finish'}) do
                assert(review[field]==other[field])
            end
        end
    end
    UI:setRunForeverMode();UI:setInputTimeout(0)
    phase='open';assert(require('weread.ui.native_book_reviews').open(host,{book_id=book,title='微信读书'},selected))
    UI:scheduleIn(.05,function() heartbeat=true end)
    wait(function() return host._native_reviews_owner and host._native_reviews_owner.view end)
    local view=host._native_reviews_owner.view
    local first=Model.project(client,input.first,book,20)
    local second=Model.project(client,input.second,book,40,first.ids)
    if mode=='online' then
        phase='first';compare(view.result,first);assert(view.result.has_more)
        view._review_buttons[#view._review_buttons].callback()
        wait(function() return host._native_reviews_owner.view~=view end)
        view=host._native_reviews_owner.view;compare(view.result,second);assert(counter[0]==2)
        local saved=assert(require('weread.lib.native_book_reviews_cache'):new(library,client,library:accountKey()):read(book))
        compare(saved,second)
    else
        phase='offline';compare(view.result,second)
        assert(not view.result.has_more and view.tab_text=='Saved latest reviews' and counter[0]==0)
        assert(#view.result.items>0);view._review_buttons[1].callback()
        assert(host.chosen==second.items[1].review_id)
        host._native_reviews_owner.detail=nil
    end
    UI:forceRePaint();painted=true;view:onClose();assert(not host._native_reviews_owner and not host.busy_message)
    phase='complete'
end)
io.write('\nWEREAD_REVIEW_CACHE_OWNER='..json.encode({result=ok and 'PASS' or 'UNVERIFIED',phase=phase,
    requests=tonumber(counter[0]),painted=painted,heartbeat=heartbeat})..'\n')
