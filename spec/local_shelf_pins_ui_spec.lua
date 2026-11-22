package.path='./?.lua;'..package.path
package.preload['weread.lib.plugin_util']=function() return {tr=function(text)return text end} end
local Model=require('weread.lib.local_shelf_pins')
local Pins=require('weread.ui.local_shelf_pins')
local n=0
local function expect(value,label) n=n+1;assert(value,label) end
local function fixture()
    local account='a';local state;local calls=0;local current=true
    local db={accountKey=function()return account end}
    function db:compareProfileState(key,expected,value)
        calls=calls+1;assert(key==Model.KEY)
        if expected~=state then return false end
        state=value;return true
    end
    local host={library_db=db,shelf_pins_owner='a',shelf_pins_state=Model.empty(),shelf_regular={{bookId='101'},{bookId='102'}}}
    function host:showInfo(message) self.message=message end
    local function changed()host.changed=(host.changed or 0)+1 end
    return host,function()return current end,changed,function(value)account=value end,function()current=false end,
        function()return calls end,function(value)state=value end
end
local host,current,changed,account,revoke,calls,external=fixture();local book=host.shelf_regular[2]
expect(Pins.available(host,book),'valid shelf book unavailable')
expect(not Pins.available(host,{bookId='999'}) and not Pins.available(host,{bookId='101',book_id='102'}),'foreign book available')
expect(Pins.toggle(host,book,current,changed) and calls()==1 and host.changed==1,'pin failed')
expect(Model.contains(host.shelf_pins_state,book),'pin did not reach host')
expect(Pins.toggle(host,book,current,changed) and calls()==2 and not Model.contains(host.shelf_pins_state,book),'unpin failed')
account('b');expect(not Pins.toggle(host,book,current,changed) and calls()==2,'cross-account write sent')
account('a');external(Model.empty());expect(not Pins.toggle(host,book,current,changed) and calls()==3 and host.message,'stale snapshot accepted')
revoke();expect(not Pins.toggle(host,book,current,changed) and calls()==3,'closed page wrote')
local broken=fixture();broken.shelf_pins_state={version=9,books={}}
expect(not Pins.available(broken,book),'corrupt state accepted')
print('PASS: local shelf pin controller ('..n..' checks)')
