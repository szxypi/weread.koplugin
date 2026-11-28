-- Read-only private snapshots over pipes; emit no logs or network requests.
require('ffi').log=function() end
require('setupkoenv');package.path='/source/?.lua;'..package.path
local Json=require('json');local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
local input=Json.decode(raw);local C=require('weread.lib.mark_edit_contract')
local codec={json_encode=function(_self,v) return Json.encode(v) end,json_decode=function(_self,v) return Json.decode(v) end}
local plan=C.make(codec,input.created,'delete',input.target)
local snapshot=require('weread.lib.mark_edit_data').validate(codec,input.deleted,input.created.book_id)
io.write('\nWEREAD_MARK_LIFECYCLE_RESULT='..Json.encode{metadata=plan.metadata,confirmed=C.check(snapshot,plan.metadata)}..'\n')
