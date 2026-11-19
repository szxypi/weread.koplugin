-- Synthetic, offline native Menu + file-backed SQLite smoke test.
require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
assert(home:match('^/dev/shm/weread%-notebooks%-[%w_]+$'))
local source=assert(os.getenv('WEREAD_SOURCE'))
package.path=source..'/?.lua;'..package.path
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json')
local Store=require('weread.lib.notebook_catalog_store');local Catalog=require('weread.ui.notebook_catalog')
local Library=require('weread.lib.library_db');local Common=require('weread.ui.common')
local account='900000';local scope={vid=account,epoch=1}
local settings={data_dir=home,get=function(_self,key) if key=='account' then return {user_vid=account} end end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
local library=Library:new(settings)
local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
local store=Store:new(library,codec,library:accountKey())
local input={schema=1,fetched_at=1000,books={{bookId='900001',title='合成书籍',author='合成作者',noteCount=2,reviewCount=1,bookmarkCount=3}}}
assert(arg[1]=='live' or arg[1]=='reopen')
if arg[1]=='live' then assert(store:write(input)) end
local loaded=assert(store:read());assert(loaded.books[1].title=='合成书籍')
account='900002';assert(not store:read() and not store:write(input),'stale account accessed cache')
local other=Store:new(library,codec,library:accountKey());assert(not other:read(),'accounts shared cache')
account='900000';assert(store:read().books[1].noteCount==2,'original cache lost')
local host={settings=settings,library_db=library,client=codec,ui={},showList=Common.showList}
host.closeWeReadUI=function(self) Catalog.cancel(self);self.discovery_epoch=(self.discovery_epoch or 0)+1 end
host.isNetworkOnline=function() return false end
host.showInfo=function(_self,message) error(message) end
host.cancelMyCloudMarks=function(self) self._my_marks_owner=nil end
host.showMyCloudThoughts=function(self,id) assert(id=='900001');self._my_marks_owner={} end
assert(Catalog.show(host));local menu=assert(host._notebook_menu)
assert(menu.item_table[5].text=='合成书籍');menu.item_table[5].callback()
local dialog=assert(menu._shelf_popup);assert(#dialog.buttons==3);dialog.buttons[2][1].callback()
assert(host._my_marks_owner and not menu._shelf_popup);Catalog.cancel(host)
assert(not host._notebook_menu and not host._my_marks_owner)
local reopened=Store:new(library,codec,library:accountKey()):read();assert(reopened.books[1].bookId=='900001')
print('PASS: real KOReader native menu and SQLite account isolation: '..arg[1])
