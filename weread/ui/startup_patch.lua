local Model=require('weread.lib.startup_patch')
local Util=require('weread.lib.plugin_util')
local M={}
local function service(host)
    local root=host.path or debug.getinfo(1,'S').source:match('^@(.+)/weread/ui/[^/]+$')
    root=root and require('ffi/util').realpath(root)
    return root and Model.new(root)
end
function M.entry(host)
    local _=Util.tr
    return {text=_('Protect old article records at startup'),checked_func=function()
        local store=service(host);return store and store:status()=='installed' or false
    end,callback=function()
        local store=service(host)
        if not store then host:showInfo(_('Could not change startup protection. Existing files were kept.'));return end
        local state=store:status()
        if state~='absent' and state~='installed' then host:showInfo(_('Could not change startup protection. Existing files were kept.'));return end
        local enable=state=='absent'
        local patches=require('userpatch')
        if enable and (type(patches.arePatchesDisabled)~='function' or patches.arePatchesDisabled()) then
            host:showInfo(_('KOReader has disabled startup extensions. Startup protection is unavailable.'));return
        end
        local dialog=require('ui/widget/confirmbox'):new{
            text=enable and _('Enable startup protection for old article reading records?\n\nWhen needed, choose saved records before the article opens. Restart KOReader to apply.')
                or _('Disable startup reading-record protection? Restart KOReader to apply.'),
            ok_text=enable and _('Enable') or _('Disable'),cancel_text=_('Cancel'),
            ok_callback=function()
                if store:status()~=state then host:showInfo(_('Could not change startup protection. Existing files were kept.'));return end
                local ok=enable and store:enable() or not enable and store:disable()
                host:showInfo(ok and _('Saved. Restart KOReader to apply startup protection.')
                    or _('Could not change startup protection. Existing files were kept.'))
            end}
        require('ui/uimanager'):show(dialog)
    end}
end
return M
