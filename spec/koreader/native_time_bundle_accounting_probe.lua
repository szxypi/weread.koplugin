-- Synthetic-only parity for native time accounting; no transport or accounts.
require('setupkoenv')
local json=require('json');assert(type(arg[1])=='string');package.path=arg[1]..'/?.lua;'..package.path
local input=json.decode(assert(io.stdin:read('*a')))
assert(input.synthetic==true and type(input.metadata)=='table' and type(input.counts)=='table' and type(input.months)=='table')
local result=require('weread.lib.readtime_accounting').check(input.metadata,input.counts,input.months)
io.stdout:write('\nWEREAD_BUNDLE_ACCOUNTING='..json.encode({result=result or false})..'\n');io.stdout:flush()
