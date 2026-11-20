-- Strict bounded JSON receipts for single-shot translation operations.
-- Unknown/truncated replies must remain unconfirmed.
local M={MAX_BYTES=8192,MAX_DEPTH=32}
local decoder
local function strict_decoder()
    if decoder then return decoder end
    local json=require('json')
    local decode=json and json.decode
    if type(decode)~='table' or type(decode.strict)~='table' or type(decode.getDecoder)~='function' then return nil end
    local function copy(value)
        if type(value)~='table' then return value end
        local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
    end
    local options=copy(decode.strict)
    if type(options.object)~='table' then return nil end
    options.object.setObjectKey=function(object,key,value)
        assert(rawget(object,key)==nil,'duplicate key')
        rawset(object,key,value)
    end
    decoder=decode.getDecoder(options)
    return decoder
end
local function bounded_structure(raw)
    local stack,quoted,escaped={},false,false
    for index=1,#raw do
        local c=raw:sub(index,index)
        if quoted then
            if escaped then escaped=false elseif c=='\\' then escaped=true elseif c=='"' then quoted=false end
        elseif c=='"' then quoted=true
        elseif c=='{' or c=='[' then
            stack[#stack+1]=c;if #stack>M.MAX_DEPTH then return false end
        elseif c=='}' or c==']' then
            if stack[#stack]~=(c=='}' and '{' or '[') then return false end
            stack[#stack]=nil
        end
    end
    return not quoted and #stack==0
end
function M.decode(raw)
    if type(raw)~='string' or #raw<2 or #raw>M.MAX_BYTES or not raw:match('^%s*{')
        or not raw:match('}%s*$') or not bounded_structure(raw) then return nil end
    local ok,result=pcall(function()
        local parse=assert(strict_decoder());return parse(raw)
    end)
    return ok and type(result)=='table' and result or nil
end
return M
