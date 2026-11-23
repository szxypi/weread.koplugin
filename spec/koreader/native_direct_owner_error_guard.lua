-- Expose only a fixed probe line number; never forward account content or logs.
local ok,value=pcall(dofile,assert(arg[2]))
if not ok then
    local line=type(value)=='string' and (value:match('native_direct_owner_ui_probe%.lua:(%d+)')
        or value:match('native_direct_owner_position_probe%.lua:(%d+)') or value:match('native_direct_ui_trial_probe%.lua:(%d+)')
        or value:match('native_direct_selection_trial_probe%.lua:(%d+)') or value:match('native_direct_highlight_trial_probe%.lua:(%d+)')
        or value:match('native_direct_personal_owner_probe%.lua:(%d+)') or value:match('native_home_resume_probe%.lua:(%d+)')
        or value:match('native_direct_cross_owner_probe%.lua:(%d+)') or value:match('native_direct_home_full_owner_probe%.lua:(%d+)'))
    if type(_G._direct_trial_error_token)=='string' then
        print('WEREAD_NATIVE_THOUGHT_'.._G._direct_trial_error_token..'_RESULT='..
            require('json').encode{result='UNVERIFIED',steps=0,posts=0,blocked=false,failed_line=tonumber(line) or 0,
                outcome=({confirmed=true,unconfirmed=true,unavailable=true,login=true,noop=true})[_G._direct_trial_outcome]
                    and _G._direct_trial_outcome or 'none',readbacks=tonumber(_G._direct_trial_readbacks) or 0})
    end
    print('WEREAD_DIRECT_OWNER_ERROR='..(line or '0'))
    os.exit(1)
end
