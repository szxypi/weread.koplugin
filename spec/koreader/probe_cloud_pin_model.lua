-- Raw shelf and position are received only through the captured memory pipe.
require('ffi').log=function()end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local json=require('json');local Contract=require('weread.lib.shelf_flag_change_contract')
local value=json.decode(io.read(4*1024*1024))
local first=Contract.make_pin(value.shelf,value.progress,value.book_id,true)
for _,row in ipairs(value.shelf.books) do if tostring(row.bookId)==value.book_id then row.isTop=1 end end
local second=Contract.make_pin(value.shelf,value.progress,value.book_id,false)
print('\nWEREAD_CLOUD_PIN_MODEL='..json.encode({first.metadata,second.metadata}))
