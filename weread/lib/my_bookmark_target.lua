-- Type-0 point navigation shares the verified archive/file handoff only;
-- it never feeds a point range into the text-highlight range conversion.
local Point=require('weread.lib.bookmark_point')
local Mark=require('weread.lib.my_mark_target')
local M={can_locate=Point.can_locate,project=Point.from_mark}
function M.bind_file(file,book,row,request_id,read)
    return Mark.bind_file(file,book,row,request_id,read,Point.from_mark)
end
function M.resolve(book,current_file,row,request_id,read)
    return Mark.resolve(book,current_file,row,request_id,read,Point.from_mark)
end
return M
