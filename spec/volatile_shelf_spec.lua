package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local source={mode='auto',native_revision='native-a',web_revision='web-a'}
package.preload['weread.lib.shelf_source']=function() return {
    mode=function() return source.mode end,
    selection=function() return {credentials=true,revision=source.native_revision} end,
    web_revision=function() return source.web_revision end,
} end
package.preload['weread.lib.crypto']=function() return {sha256_hex=function(value) return 'hash:'..value end} end
local Shelf=require('weread.lib.volatile_shelf')
local account='account-a';local auth={vid='1',epoch=1};local valid=true;local api_key='key-a'
local host={library_db={accountKey=function() return account end},settings={
    get_auth_scope=function() return auth end,
    auth_scope_matches=function(_self,scope) return valid and scope.vid==auth.vid and scope.epoch==auth.epoch end,
    get=function(_self,key,default) if key=='api_key' then return api_key end return default end,
}}
local snapshot={books={{bookId='fixture'}},archives={}}
local info={_shelf_source='gateway',_native_revision='native-a',_web_revision='web-a'}
local function remember() expect(Shelf.remember(host,snapshot,info),'eligible shelf not retained') end
remember();expect(Shelf.get(host)==snapshot,'same session lost unsaved snapshot')
account='account-b';expect(not Shelf.get(host),'snapshot crossed accounts');account='account-a'
remember();auth={vid='1',epoch=2};expect(not Shelf.get(host),'snapshot crossed login epoch');auth={vid='1',epoch=1}
remember();valid=false;expect(not Shelf.get(host),'snapshot used stale disk authorization');valid=true
remember();source.mode='native';expect(not Shelf.get(host),'snapshot crossed shelf source');source.mode='auto'
remember();source.native_revision='native-b';expect(not Shelf.get(host),'snapshot crossed native credential revision');source.native_revision='native-a'
remember();source.web_revision='web-b';expect(not Shelf.get(host),'snapshot crossed web credential revision');source.web_revision='web-a'
remember();api_key='key-b';expect(not Shelf.get(host),'snapshot crossed gateway key change');api_key='key-a'
remember();Shelf.clear(host);expect(not Shelf.get(host),'explicit invalidation retained snapshot')
remember();local reopened={library_db=host.library_db,settings=host.settings}
expect(not Shelf.get(reopened),'unsaved snapshot survived a new host instance');Shelf.clear(host)
account=nil;expect(not Shelf.remember(host,snapshot,info) and not Shelf.get(host),'unidentified account retained snapshot');account='account-a'
auth=nil;expect(not Shelf.remember(host,snapshot,info) and not Shelf.get(host),'unidentified login retained snapshot')
print('volatile_shelf_spec: '..checks..' checks')
