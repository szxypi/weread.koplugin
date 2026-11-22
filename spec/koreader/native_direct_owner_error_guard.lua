-- Expose only a fixed probe line number; never forward account content or logs.
local ok,value=pcall(dofile,assert(arg[2]))
if not ok then
    local line=type(value)=='string' and (value:match('native_direct_owner_ui_probe%.lua:(%d+)')
        or value:match('native_direct_owner_position_probe%.lua:(%d+)'))
    print('WEREAD_DIRECT_OWNER_ERROR='..(line or '0'))
    os.exit(1)
end
