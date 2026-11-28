-- Private snapshot and metadata cross captured memory pipes only.
require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1] .. '/?.lua;' .. package.path
local json=require('json')
local Contract=require('weread.lib.shelf_flag_change_contract')
local value=json.decode(io.read(4*1024*1024))
local first=Contract.make(value.shelf,value.progress,value.book_id,true)
for _i,row in ipairs(value.shelf.books) do if tostring(row.bookId)==value.book_id then row.secret=1 end end
local second=Contract.make(value.shelf,value.progress,value.book_id,false)
print('\nWEREAD_SHELF_FLAG_MODEL=' .. json.encode({first.metadata,second.metadata}))
