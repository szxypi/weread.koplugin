-- Share the tested worker/cancellation lifecycle with thought changes; use
-- a distinct contract, SQLite intent row, and complete annotation snapshots.
local Store=require('weread.lib.my_cloud_marks_store')
local M={}
function M.new_journal(library,client,options)
    options=options or {};options.variant='marks';options.contract=require('weread.lib.mark_edit_contract')
    return require('weread.lib.thought_edit_store'):new(library,client,options)
end
function M:new(options)
    options.contract=require('weread.lib.mark_edit_contract');options.data=require('weread.lib.mark_edit_data')
    options.task=require('weread.lib.mark_edit_task')
    return require('weread.lib.thought_edit_service'):new(options)
end
function M.new_cache(library,client)
    local marks,thoughts=Store:new(library,client),Store:new(library,client,'thoughts')
    return {write=function(_self,value) return marks:write(value.marks) and thoughts:write(value.thoughts) end,
        read=function(_self,book) return marks:read(book) end}
end
return M
