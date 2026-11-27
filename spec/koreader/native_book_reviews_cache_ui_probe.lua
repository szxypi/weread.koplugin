-- Packaged KOReader widget, synthetic source, real SQLite and fresh processes.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local mode=assert(os.getenv('WEREAD_REVIEW_CACHE_MODE'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');local socket=require('socket');local json=require('json');local ffi=require('ffi')
local public=os.getenv('WEREAD_PUBLIC_REVIEW_IMAGE')=='1'
local skill_failure=mode=='skill_failure'
local input=public and assert(json.decode(io.read('*a'))) or nil
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
local calls=ffi.cast('int *',memory);calls[0]=0;calls[1]=0
local account='900000'
local settings={data_dir=home,get=function(_self,key,default)
    if key=='account' then return {user_vid=account} end
    return default
end,is_api_configured=function() return skill_failure end}
local client={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local image_url=public and input.url or 'https://weread-picture-1258476243.file.myqcloud.com/synthetic-review.png'
client.request=function(_self,options)
    assert(mode=='online' and options.url==image_url and options.skip_cookie and options.sensitive
        and not options.persist_response_cookies and not options.headers.Cookie and not options.headers.Authorization)
    calls[2]=calls[2]+1
    if public then return require('weread.lib.client'):new(settings):request(options) end
    assert(options.sink(require('weread.lib.native_missing_image')));options.sink(nil);return nil,200
end
local library=require('weread.lib.library_db'):new(settings)
local Source=require('weread.lib.native_book_reviews_source')
local selected={native={scope={vid=account}}}
Source.capture=function() if mode=='offline' then return nil end;return selected end
Source.matches=function(_settings,value) return value==selected end
Source.fetch=function(c,id,limit,previous)
    calls[0]=calls[0]+1;assert(mode~='offline' and id=='42')
    if mode=='failure' then error('synthetic_unavailable') end
    local raw={reviews=c:json_decode('[]')}
    for i=1,limit+1 do
        local key='synthetic-'..i
        raw.reviews[i]={reviewId=key,review={reviewId=key,bookId=id,type=4,createTime=1700001000-i,
            author={name='合成读者'},content='合成书评 '..i,star=i%2==1 and 100 or 80}}
        if i==1 then raw.reviews[i].review.pictures={{url=image_url,width=32,height=32}} end
        if i==2 then raw.reviews[i].review.pictures={{url='https://untrusted.invalid/image'}} end
    end
    return require('weread.lib.native_book_reviews').project(c,raw,id,limit,previous)
end
Source.fetch_replies=function(c,id,review,limit,previous,_selected,_recover,kind)
    calls[1]=calls[1]+1;assert(mode~='offline' and id=='42' and review=='synthetic-1' and kind==4)
    if mode=='failure' then error('synthetic_unavailable') end
    local comments=c:json_decode('[]')
    for i=1,limit+1 do
        comments[i]={reviewId=review,commentId='reply-'..i,author={name='合成读者'},
            content='合成回复 '..i,createTime=1700000000+i}
    end
    return require('weread.lib.native_review_replies').project(c,
        {reviewId=review,review={reviewId=review,bookId=id,type=kind},comments=comments},id,review,limit,previous,kind)
end
if skill_failure then
    local gateway=require('weread.lib.gateway_book_reviews_source')
    local skill={api_key='synthetic-only'}
    gateway.capture=function() return skill end
    gateway.matches=function(_,access) return access==skill end
    gateway.fetch=function(_,id,tab)
        assert(id=='42' and tab=='recommended');calls[3]=calls[3]+1
        error('gateway_reviews/unavailable',0)
    end
end
local host={settings=settings,client=client,library_db=library,_book_detail_view={},discovery_epoch=1,
    _reader_session_gen=1,ui={document={}}}
local parent=tonumber(ffi.C.getpid())
function host:isNetworkConnected() return mode~='offline' end
function host:isNetworkOnline()
    assert(tonumber(ffi.C.getpid())~=parent,'book reviews used a synchronous Internet check')
    return mode=='online'
end
function host:requireLogin() return skill_failure end
function host:showBusy(_text,cancel) self.busy_message={};self.cancel_busy=cancel end
function host:closeBusy() self.busy_message=nil end
function host:showInfo() error('unexpected_info') end
function host:runOnlineTask(_label,fn,_delay,options)
    assert(options.link_only and options.silent_offline)
    UI:scheduleIn(.01,fn);return true
end
host.showBookReviewDetail=require('weread.ui.library').showBookReviewDetail
local function wait(test)
    local until_time=socket.gettime()+35
    while not test() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<until_time,'review_cache/timeout') end
end
UI:setRunForeverMode();UI:setInputTimeout(0)
assert(require('weread.ui.library').showBookReviews(host,{book_id='42',title='合成书籍'}))
wait(function() return host._native_reviews_owner and host._native_reviews_owner.view end)
local view=host._native_reviews_owner.view
if mode=='online' then
    assert(#view.result.items==20 and view.result.has_more)
else
    assert(view.tab_text=='Saved latest reviews' and view.incomplete_text:find('书评可能不完整',1,true))
    assert(#view.result.items==40 and not view.result.has_more and #view._review_buttons==40)
    assert(calls[0]==(mode=='failure' and 1 or 0))
end
assert(calls[3]==(skill_failure and 1 or 0) and not host._gateway_reviews_owner,
    'Skill fallback retried or retained an old review owner')
view._review_buttons[1].callback()
local detail=assert(host._native_reviews_owner.detail)
assert(detail.text:find('合成书评 1',1,true) and detail.buttons_table)
if mode=='online' and not public then
    detail.buttons_table[2][1].callback();assert(host.busy_message)
    detail:onClose();assert(not host.busy_message and not host._native_reviews_owner.review_image_owner)
    calls[2]=0;view._review_buttons[1].callback();detail=assert(host._native_reviews_owner.detail)
end
assert(detail.buttons_table[2][1].id=='review_image_1');detail.buttons_table[2][1].callback()
wait(function() local own=host._native_reviews_owner.review_image_owner;return own and own.widget end)
local image_owner=host._native_reviews_owner.review_image_owner
assert(image_owner.widget.title_text=='书评图片' and image_owner.widget.image)
assert(calls[2]==(mode=='online' and 1 or 0));UI:forceRePaint();UI:close(image_owner.widget)
if public then
    local Cache=require('weread.lib.thought_image_store');local key=assert(Cache.key('42','synthetic-1',image_url))
    local bytes=assert(Cache:new(library):read(library:accountKey(),key))
    assert(require('weread.lib.crypto').sha256_hex(bytes)==input.sha256)
end
assert(not host._native_reviews_owner.review_image_owner and host._native_reviews_owner.detail==detail)
detail.buttons_table[1][1].callback()
wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
local replies=host._native_review_replies_owner.view
if mode=='online' then
    assert(#replies.result.items==20 and replies.result.has_more)
    replies._review_buttons[#replies._review_buttons].callback()
    wait(function() return host._native_review_replies_owner.view~=replies end)
    replies=host._native_review_replies_owner.view
    assert(#replies.result.items==40 and calls[1]==2)
else
    assert(#replies.result.items==40 and not replies.result.has_more and replies.tab_text=='Saved replies')
    assert(replies.incomplete_text:find('回复可能不完整',1,true) and calls[1]==(mode=='failure' and 1 or 0))
end
replies._review_buttons[1].callback()
local reply_viewer=assert(host._native_review_replies_owner.viewer)
assert(reply_viewer.text:find('合成回复 1',1,true));reply_viewer:onClose()
replies:onClose();detail:onClose()
view._review_buttons[2].callback();detail=assert(host._native_reviews_owner.detail)
assert(detail.text:find('部分书评附件暂无法显示',1,true));detail:onClose()
if mode=='online' then
    view._review_buttons[#view._review_buttons].callback()
    wait(function() return host._native_reviews_owner.view~=view end)
    view=host._native_reviews_owner.view
    assert(#view.result.items==40 and calls[0]==2)
end
-- Both tabs use the same fetched/cached snapshot and retain its pagination.
local prior_calls=calls[0];assert(#view._tab_buttons==2)
assert(view._tab_buttons[1]:getSize().w+view._tab_buttons[2]:getSize().w==Device.screen:getWidth())
view._tab_buttons[2].callback()
local filtered=host._native_reviews_owner.view
assert(filtered~=view and filtered.mode=='five_stars' and #filtered.result.items==20 and calls[0]==prior_calls)
assert(filtered.result.items[1].review_id=='synthetic-1' and filtered.result.items[20].review_id=='synthetic-39')
assert(filtered.incomplete_text:find('仅筛选已加载',1,true),'filtered scope notice missing')
UI:forceRePaint();filtered._review_buttons[1].callback();detail=assert(host._native_reviews_owner.detail)
assert(detail.text:find('合成书评 1',1,true));detail:onClose()
filtered._tab_buttons[1].callback();view=host._native_reviews_owner.view
assert(view.mode=='latest' and #view.result.items==40 and calls[0]==prior_calls)
UI:forceRePaint();view:onClose();assert(not host._native_reviews_owner and not host.busy_message)
local Store=require('weread.lib.native_book_reviews_cache')
local original=Store:new(library,client,library:accountKey());assert(original:read('42'))
account='900001';local other=Store:new(library,client,library:accountKey())
assert(not original:read('42') and not other:read('42'))
print('\nWEREAD_REVIEW_CACHE_UI='..json.encode({result='PASS',mode=mode,items=40,
    requests=tonumber(calls[0]),reply_requests=tonumber(calls[1])}))
