package.path='./?.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local Store=require('weread.lib.mp_link_store')
local files={one=os.tmpname(),two=os.tmpname()}
local current='one'
local library={accountKey=function() return current end,open=function() return helper.connect(files[current]) end}
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
expect(Store.add(library,'one','MP_WXS_42','MP_WXS_42_article_1'),'add failed')
expect(Store.add(library,'one','MP_WXS_42','MP_WXS_42_article_1','A title'),'duplicate failed')
local rows=assert(Store.list(library,'one'));expect(#rows==1 and rows[1].review_id=='MP_WXS_42_article_1' and rows[1].title=='A title','duplicate, title or identity wrong')
expect(Store.add(library,'one','MP_WXS_42','MP_WXS_42_article_1','Other title') and Store.list(library,'one')[1].title=='A title','saved title overwritten')
expect(not Store.add(library,'one','MP_WXS_42','MP_WXS_42_article_1','bad\nvalue'),'unsafe title stored')
expect(not Store.add(library,'one','MP_WXS_43','MP_WXS_42_article_2'),'mismatched account accepted')
expect(not Store.add(library,'two','MP_WXS_42','MP_WXS_42_article_2'),'stale account wrote')
Store.MAX_ROWS=1;expect(not Store.add(library,'one','MP_WXS_42','MP_WXS_42_article_2'),'quota ignored')
expect(#Store.list(library,'one')==1,'failed transaction damaged previous data')
current='two';expect(#Store.list(library,'two')==0 and not Store.list(library,'one'),'account isolation failed')
expect(Store.add(library,'two','MP_WXS_43','MP_WXS_43_article_2'),'second account add failed')
current='one';rows=Store.list(library,'one');expect(#rows==1 and rows[1].book_id=='MP_WXS_42','account switch lost prior records')
for _,path in pairs(files) do os.remove(path);os.remove(path..'-wal');os.remove(path..'-shm') end
print('PASS: imported article store ('..checks..' checks)')
