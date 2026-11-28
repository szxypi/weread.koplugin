-- Private catalog input/output; caller prints only counts and comparison status.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local input=json.decode(assert(io.stdin:read('*a')))
local value=require('weread.lib.native_book_catalog').project(input.raw,input.book_id,input.info)
assert(value.reading_chapters)
io.write('\nWEREAD_NATIVE_BOOK_CATALOG='..json.encode({version=value.version,chapters=value.reading_chapters})..'\n')
