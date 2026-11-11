-- Complete own annotation sets, checked together before/after a mark change.
local Marks=require('weread.lib.my_cloud_marks')
local Thoughts=require('weread.lib.my_cloud_thoughts')
local M={}
function M.validate(client,value,book)
    if type(value)~='table' or value.book_id~=book then error('mark_edit/snapshot',0) end
    return {book_id=book,marks=Marks.validate(client,value.marks,book),thoughts=Thoughts.validate(client,value.thoughts,book)}
end
return M
