-- Private text in/out only through pipes. No UI, files, credentials or API.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('rapidjson')
local Coordinates=require('weread.lib.source_coordinates')
local function run()
    local raw=assert(io.stdin:read(3*1024*1024+1))
    assert(#raw<=3*1024*1024)
    local input=json.decode(raw)
    assert(type(input)=='table' and type(input.queries)=='table' and #input.queries<=64)
    local map=assert(Coordinates.build(input.raw,{format='web_txt'}))
    local excerpts=json.array{}
    for index,query in ipairs(input.queries) do
        excerpts[index]=assert(map:literal_excerpt(query.co,query.limit))
    end
    io.stdout:write(json.encode({result='PASS',excerpts=excerpts}))
end
if not pcall(run) then os.exit(1) end
