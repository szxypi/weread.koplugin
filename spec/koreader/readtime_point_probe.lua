-- Private pipe-only projections; this probe has no credentials or transport.
require('setupkoenv')
local root=assert(arg[1]);package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local Json=require('json');local Point=require('weread.lib.readtime_point')
local raw=assert(io.stdin:read(262145));assert(#raw<=262144)
local input=Json.decode(raw)
local value={native=Point.project(input.native,input.book_id,'native'),web=Point.project(input.web,input.book_id,'web')}
io.stdout:write('\nWEREAD_PRIVATE_TIME_POINTS='..Json.encode(value)..'\n')
