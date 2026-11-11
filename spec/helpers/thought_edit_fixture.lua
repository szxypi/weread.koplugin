local M={}
function M.clone(value)
    if type(value)~='table' then return value end
    local result={};for k,v in pairs(value) do result[k]=M.clone(v) end
    return setmetatable(result,getmetatable(value))
end
function M.codec()
    local mt,null,values={},{},{}
    return {json_encode=function(_self,value) values[#values+1]=M.clone(value);return tostring(#values) end,
        json_decode=function(_self,value)
            if value=='null' then return null elseif value=='[]' then return setmetatable({},mt) end
            return M.clone(assert(values[tonumber(value)]))
        end}
end
function M.row()
    return {reviewId='synthetic-note',content='原想法 😀',abstract='合成引用',chapterName='第一章',range='12-25',
        chapterUid=7,chapterIdx=1,type=1,createTime=1000,isPrivate=1}
end
function M.snapshot(codec)
    local rows=codec:json_decode('[]');rows[1]=M.row()
    return {schema=1,book_id='900001',fetched_at=1000,reviews=rows}
end
function M.mark() return {bookmarkId='synthetic-mark',type=1,chapterUid=7,chapterIdx=1,range='12-25',markText='合成引用'} end
function M.marks(codec)
    local rows=codec:json_decode('[]');rows[1]=M.mark()
    return {bookId='900001',updated=rows,chapters=codec:json_decode('[]')}
end
function M.access()
    local state={valid=true,revision=1}
    local scope={vid='900000',epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return state.valid end}
    local credentials={vid='900000',accessToken='synthetic-access'}
    local store={read=function() return credentials,state.revision,nil,state.pending end}
    return settings,store,state
end
return M
