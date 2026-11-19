-- Packaged KOReader widget, synthetic source, real SQLite and fresh processes.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local mode=assert(os.getenv('WEREAD_REVIEW_CACHE_MODE'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');local socket=require('socket');local json=require('json');local ffi=require('ffi')
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
local calls=ffi.cast('int *',memory);calls[0]=0
local account='900000'
local settings={data_dir=home,get=function(_self,key,default)
    if key=='account' then return {user_vid=account} end
    return default
end,is_api_configured=function() return false end}
local client={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
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
            author={name='合成读者'},content='合成书评 '..i,star=100}}
    end
    return require('weread.lib.native_book_reviews').project(c,raw,id,limit,previous)
end
local host={settings=settings,client=client,library_db=library,_book_detail_view={},discovery_epoch=1,
    _reader_session_gen=1,ui={document={}}}
function host:isNetworkOnline() return mode~='offline' end
function host:showBusy(_text,cancel) self.busy_message={};self.cancel_busy=cancel end
function host:closeBusy() self.busy_message=nil end
function host:showInfo() error('unexpected_info') end
function host:runOnlineTask(_label,fn) UI:scheduleIn(.01,fn);return true end
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
    view._review_buttons[#view._review_buttons].callback()
    wait(function() return host._native_reviews_owner.view~=view end)
    view=host._native_reviews_owner.view
    assert(#view.result.items==40 and calls[0]==2)
else
    assert(view.tab_text=='Saved latest reviews' and view.incomplete_text:find('书评可能不完整',1,true))
    assert(#view.result.items==40 and not view.result.has_more and #view._review_buttons==40)
    assert(calls[0]==(mode=='failure' and 1 or 0))
    view._review_buttons[1].callback()
    local detail=assert(host._native_reviews_owner.detail)
    assert(detail.text:find('合成书评 1',1,true) and not detail.buttons_table)
    detail:onClose()
end
UI:forceRePaint();view:onClose();assert(not host._native_reviews_owner and not host.busy_message)
local Store=require('weread.lib.native_book_reviews_cache')
local original=Store:new(library,client,library:accountKey());assert(original:read('42'))
account='900001';local other=Store:new(library,client,library:accountKey())
assert(not original:read('42') and not other:read('42'))
print('\nWEREAD_REVIEW_CACHE_UI='..json.encode({result='PASS',mode=mode,items=40,requests=tonumber(calls[0])}))
