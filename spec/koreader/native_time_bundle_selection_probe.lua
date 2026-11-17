-- Synthetic-only parity for selection and its native queue hashes; no network.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local input=json.decode(assert(io.stdin:read('*a')))
assert(input.owner=='900000' and input.book_id=='900001')
assert(type(arg[1])=='string');package.path=arg[1]..'/?.lua;'..package.path
local selection=assert(require('weread.lib.readtime_transfer_contract').select(input.rows,{parts=input.parts},input.now,input.book_id))
print(json.encode({result='PASS',selection=selection}))
