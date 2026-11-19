-- Actual thought popup and reply widgets with persisted synthetic source.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));local mode=assert(os.getenv('WEREAD_REVIEW_CACHE_MODE'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI,socket,json,ffi=require('ui/uimanager'),require('socket'),require('json'),require('ffi')
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
local calls=ffi.cast('int *',memory);calls[0]=0
local account='900000'
local settings={data_dir=home,get=function(_self,key,default)
    if key=='account' then return {user_vid=account} end
    if key=='thought_popup' then return {position='center',height_ratio=.7,width_ratio=.8} end
    if key=='cache' then return {ignore_edge_thought_taps=false} end
    return default
end}
local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local library=require('weread.lib.library_db'):new(settings)
local selected={native={scope={vid=account}}};local Source=require('weread.lib.native_book_reviews_source')
Source.capture=function() if mode=='offline' then return nil end;return selected end
Source.matches=function(_settings,value) return value==selected end
Source.fetch_replies=function(c,book,review,limit,previous,_access,_recover,kind)
    calls[0]=calls[0]+1;assert(mode~='offline' and book=='42' and review=='thought-2' and kind==1)
    if mode=='failure' then error('synthetic_unavailable') end
    local comments=c:json_decode('[]')
    for i=1,limit+1 do comments[i]={reviewId=review,commentId='reply-'..i,author={name='合成读者'},
        content='合成想法回复 '..i,createTime=1700000000+i} end
    return require('weread.lib.native_review_replies').project(c,
        {reviewId=review,review={reviewId=review,bookId=book,type=1},comments=comments},book,review,limit,previous,1)
end
local row={range='10-20',pageReviews={
    {reviewId='thought-1',likesCount=1,review={reviewId='thought-1',bookId='42',chapterUid=7,type=1,
        author={name='甲'},content='想法甲'}},
    {reviewId='thought-2',likesCount=2,review={reviewId='thought-2',bookId='42',chapterUid=7,type=1,
        author={name='乙'},content='想法乙'}},}}
local items=require('weread.lib.annotations').buildThoughtPopupItems(row)
local source={book_id='42',chapter_uid='7',reviews={row}}
local store=require('weread.lib.annotation_store'):new(settings)
if mode=='online' then store:put('42','source','7',source,'7');store:put('42','thought','7:10-20',items,'7') end
assert(store:get('42','source','7'))
local document={configurable={font_size=18},getPageMargins=function() return {left=20,right=20,top=10,bottom=10} end}
local record={book_id='42',chapter_uid='7',range='10-20'}
local host={settings=settings,client=codec,library_db=library,_annotation_context={book_id='42',store=store},
    _reader_session_gen=1,discovery_epoch=1,ui={document=document,doc_props={title='合成书籍'}},
    _xpointer_overlay={enabled=true,hitTest=function() return record end}}
function host:isNetworkOnline() return mode~='offline' end
function host:showBusy(_text,cancel) self.busy_message={};self.cancel_busy=cancel end
function host:closeBusy() self.busy_message=nil end
function host:showInfo() error('unexpected_info') end
function host:runOnlineTask(_label,fn) assert(mode~='offline');UI:scheduleIn(.01,fn);return true end
local function wait(test)
    local deadline=socket.gettime()+35
    while not test() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'thought_cache/timeout') end
end
UI:setRunForeverMode();UI:setInputTimeout(0)
assert(require('weread.ui.xpointer_overlay_controller')._onXPointerOverlayTap(host,
    {pos={x=math.floor(Device.screen:getWidth()/2),y=200}}))
local popup=assert(UI:getTopmostVisibleWidget());local shown=popup.items
assert(#shown==2 and popup.on_replies);popup:_showThoughtActionMenu(shown[2])
local menu=assert(UI:getTopmostVisibleWidget());menu.buttons[2][1].callback()
wait(function() return host._native_review_replies_owner and host._native_review_replies_owner.view end)
local view=host._native_review_replies_owner.view
if mode=='online' then
    assert(#view.result.items==20 and view.result.has_more)
    view._review_buttons[#view._review_buttons].callback()
    wait(function() return host._native_review_replies_owner.view~=view end)
    view=host._native_review_replies_owner.view;assert(#view.result.items==40 and calls[0]==2)
else
    assert(#view.result.items==40 and not view.result.has_more and view.tab_text=='Saved replies')
    assert(view.incomplete_text:find('回复可能不完整',1,true) and calls[0]==(mode=='failure' and 1 or 0))
end
view._review_buttons[1].callback()
local viewer=assert(host._native_review_replies_owner.viewer)
assert(viewer.text:find('合成想法回复 1',1,true));viewer:onClose()
view:onClose();popup:onClose();assert(not host._thought_reply_owner and not host._native_review_replies_owner)
assert(not host.busy_message)
local cache=require('weread.lib.native_review_replies_cache'):new(library,codec,library:accountKey())
assert(cache:read('42','thought-2',1) and not cache:read('42','thought-2',4))
account='900001';assert(not cache:read('42','thought-2',1))
print('\nWEREAD_REVIEW_CACHE_UI='..json.encode({result='PASS',mode=mode,items=40,
    requests=0,reply_requests=tonumber(calls[0])}))
