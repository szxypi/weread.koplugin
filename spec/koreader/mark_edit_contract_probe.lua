-- Private inputs/outputs use captured pipes. No request or settings writes.
require('ffi').log=function() end
require('setupkoenv');package.path='/source/?.lua;'..package.path
local Json=require('json');local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
local input=Json.decode(raw);local C=require('weread.lib.mark_edit_contract')
local codec={json_encode=function(_self,v) return Json.encode(v) end,json_decode=function(_self,v) return Json.decode(v) end}
local plans={C.make(codec,input.snapshot,'create',input.reference,input.metadata),C.make(codec,input.deletion_snapshot,'delete',input.target)}
io.write('\nWEREAD_HIGHLIGHT_CONTRACT_RESULT='..Json.encode(plans)..'\n')
