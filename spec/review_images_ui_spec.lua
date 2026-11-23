package.path='./?.lua;'..package.path
local pending,worker,freed,shown,fail_show=nil,nil,0,0,false
local ui={show=function(_,widget) shown=shown+1;if fail_show then error('fixture') end;widget.shown=true end,
    close=function(_,widget) widget:onCloseWidget() end}
package.preload['ui/uimanager']=function() return ui end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.memory_worker']=function() return {new=function()
    worker={start=function(_,_,callback) pending=callback;return true end,cancel=function(self) self.cancelled=true end}
    return worker end} end
package.preload['mime']=function() return {unb64=function() return 'synthetic-image' end} end
package.preload['weread.lib.crypto']=function() return {sha256_hex=function() return 'fixture-hash' end} end
package.preload['weread.lib.thought_image_data']=function() return {dimensions=function() return 32,32 end} end
package.preload['weread.lib.thought_image_store']=function() return {key=function() return 'fixture-key' end} end
package.preload['ui/renderimage']=function() return {renderImageData=function()
    return {free=function() freed=freed+1 end} end} end
package.preload['ui/widget/imageviewer']=function() return {new=function(_,value)
    value.onCloseWidget=function(self) self.image:free() end;return value end} end
local Images=require('weread.ui.review_images')
local host={library_db={accountKey=function() return 'account' end},client={},settings={}}
function host:isNetworkOnline() return true end
function host:showBusy(_,cancel) self.busy_message={cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showInfo(value) self.message=value end
local detail={};local owner={account='account',detail=detail};local valid=true
local book={book_id='42'};local row={review_id='fixture',attachment_urls=
    'https://weread-picture-1258476243.file.myqcloud.com/a.png'}
local function current() return valid end
local function open() return Images.open(host,owner,book,row,1,detail,current) end
local result={bytes='encoded',sha256='fixture-hash'}
assert(open() and host.busy_message);pending(result)
assert(not host.busy_message and owner.review_image_owner and owner.review_image_owner.widget and shown==1)
ui:close(owner.review_image_owner.widget);assert(not owner.review_image_owner and freed==1)
assert(open());local stale=pending;host.busy_message.cancel();assert(worker.cancelled and not owner.review_image_owner)
stale(result);assert(shown==1 and not host.busy_message)
assert(open());pending({error='offline'});assert(not owner.review_image_owner and host.message and not host.busy_message)
assert(open());valid=false;pending(result);assert(not owner.review_image_owner and shown==1);valid=true
fail_show=true;assert(open());pending(result);assert(not owner.review_image_owner and freed==2 and not host.busy_message)
fail_show=false;assert(open());pending(result);Images.cancel(host,owner)
assert(not owner.review_image_owner and freed==3 and not host.busy_message)
print('PASS: review image ownership, cancellation, failure and stale callbacks')
