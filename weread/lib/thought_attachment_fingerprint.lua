-- Capture attachment metadata identity without persisting its unknown fields.
-- A bounded canonical form detects additions, removals and nested changes.
local Crypto=require('weread.lib.crypto')
local M={MAX_BYTES=512*1024,MAX_NODES=4096,MAX_DEPTH=16}
function M.compute(row,present,array_mt)
    local ok,result=pcall(function()
        local parts,total,nodes,stack={},0,0,{}
        local function emit(value)
            total=total+#value;assert(total<=M.MAX_BYTES,'attachment_fingerprint/size')
            parts[#parts+1]=value
        end
        local function visit(value,depth)
            nodes=nodes+1;assert(nodes<=M.MAX_NODES and depth<=M.MAX_DEPTH,'attachment_fingerprint/limit')
            if not present(value) then emit('z;');return end
            local kind=type(value)
            if kind=='string' then
                assert(#value<=M.MAX_BYTES-total,'attachment_fingerprint/size')
                emit('s'..#value..':'..value);return
            end
            if kind=='boolean' then emit(value and 't;' or 'f;');return end
            if kind=='number' then
                assert(value==value and math.abs(value)<math.huge,'attachment_fingerprint/number')
                emit('n'..(value==0 and '0' or string.format('%.17g',value))..';');return
            end
            assert(kind=='table' and not stack[value],'attachment_fingerprint/value');stack[value]=true
            local keys,numeric={},nil
            for key in pairs(value) do
                local kt=type(key)
                assert(kt=='string' or kt=='number' and key>=1 and key%1==0,'attachment_fingerprint/key')
                if numeric==nil then numeric=kt=='number' else assert(numeric==(kt=='number'),'attachment_fingerprint/key') end
                keys[#keys+1]=key;assert(#keys<=M.MAX_NODES,'attachment_fingerprint/limit')
            end
            if #keys==0 and not array_mt then error('attachment_fingerprint/ambiguous',0) end
            local is_array=numeric==true or #keys==0 and getmetatable(value)==array_mt
            if numeric then assert(#keys==#value,'attachment_fingerprint/array') end
            table.sort(keys)
            if numeric then for index,key in ipairs(keys) do assert(key==index,'attachment_fingerprint/array') end end
            emit((is_array and 'a' or 'o')..#keys..':')
            for _,key in ipairs(keys) do visit(key,depth+1);visit(value[key],depth+1) end
            stack[value]=nil
        end
        local selected={}
        for _,key in ipairs({'pictures','pencilNote'}) do if row[key]~=nil then selected[key]=row[key] end end
        if type(row.htmlContent)=='string' and row.htmlContent:lower():find('<img',1,true) then
            selected.htmlContent=row.htmlContent
        end
        visit(selected,0)
        return Crypto.sha256_hex('thought-attachment-metadata-v1\0'..table.concat(parts))
    end)
    return ok and result or nil
end
return M
