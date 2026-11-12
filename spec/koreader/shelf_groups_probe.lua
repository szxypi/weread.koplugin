-- Pure projection; account values are returned only through the captured pipe.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local ok,result=pcall(function()
    local raw=io.stdin:read(4*1024*1024+1);assert(#raw<=4*1024*1024)
    local input=json.decode(raw)
    local output={}
    for _kind_index,kind in ipairs({'native','web'}) do
        local source=assert(input[kind]);local books={}
        for _book_index,book in ipairs(source.books) do if book.bookId:sub(1,7)~='MP_WXS_' then books[#books+1]=book end end
        local rows=json.decode('[]')
        for _group_index,group in ipairs(require('weread.lib.shelf_groups').list(source.archive,books,'Unnamed group','Uncategorized')) do
            local members=json.decode('[]')
            for _book_index,book in ipairs(group.books) do members[#members+1]=book.bookId end
            rows[#rows+1]={key=group.key,label=group.label,members=members}
        end
        output[kind]=rows
    end
    return output
end)
io.write('\nWEREAD_GROUPS_RESULT='..json.encode(ok and result or {error='projection_failed'}))
os.exit(ok and 0 or 1)
