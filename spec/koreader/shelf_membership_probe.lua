-- Private IDs only in captured memory pipes; no files, credentials or HTTP.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local ok,result=pcall(function()
    local bytes=assert(io.stdin:read(1024*1024+1));assert(#bytes<=1024*1024)
    local input=json.decode(bytes)
    local Model=require('weread.lib.shelf_snapshot')
    local metadata=assert(Model.metadata(input.books,1000))
    local members={};for _i,book in ipairs(input.books) do members[Model.id(book)]=true end
    local values={}
    for _i,id in ipairs(input.selected) do
        assert(type(id)=='string' and Model.id({bookId=id})==id)
        local present=Model.state(metadata,#input.books,members[id] and 1 or nil,members[id] and 1000 or nil,false)
        assert(type(present)=='boolean');values[#values+1]=present
    end
    return values
end)
io.write('\nWEREAD_MEMBERSHIP_RESULT='..json.encode(ok and result or {}))
os.exit(ok and 0 or 1)
