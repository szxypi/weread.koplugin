-- Native personal notes; parent owns persistence and popup lifetimes.
local Data=require('weread.lib.my_cloud_marks')
local Store=require('weread.lib.my_cloud_marks_store')
local Recovery=require('weread.lib.native_read_recovery')
local Popup=require('weread.ui.shelf_popup')
local Protocol=require('weread.lib.protocol')
local Search=require('weread.lib.shelf_search')
local SearchQuery=require('weread.lib.search_query')
local Order=require('weread.lib.personal_notes_order')
local NetworkLink=require('weread.lib.network_link')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local function current(host,owner)
    return host._my_marks_owner==owner and host._my_marks_menu==owner.menu and not owner.menu._shelf_closed
        and owner.account==host.library_db:accountKey() and owner.account~=nil
        and owner.epoch==(host.discovery_epoch or 0) and owner.session==host._reader_session_gen
        and owner.document==(host.ui and host.ui.document) and owner.parent==host._book_detail_view
        and host.settings:auth_scope_matches(owner.scope)
end
local function stop(host,owner)
    require('weread.ui.thought_images').cancel(host,owner)
    local card=package.loaded['weread.ui.excerpt_card']
    if card then card.close_owner(host,owner) end
    require('weread.ui.cloud_notes_export').cancel(host,owner)
    require('weread.ui.my_mark_navigation').cancel(host,owner)
    require('weread.ui.thought_editor').cancel(host,owner)
    require('weread.ui.mark_editor').cancel(host,owner)
    local context=owner.context;owner.context=nil
    if not context then return end
    if owner.worker then owner.worker:cancel() end
    Recovery.cancel(host,context)
    if context.busy and host.busy_message==context.busy then host:closeBusy() end
end
function M.cancel(host)
    local owner=host._my_marks_owner;host._my_marks_owner=nil
    local menu=host._my_marks_menu;host._my_marks_menu=nil
    if owner then stop(host,owner) end
    if menu then menu._shelf_closed=true;Popup.close(menu);UI:close(menu) end
end
local function kind(row,owner)
    if owner.thoughts then return row.isPrivate==1 and _('Private thought') or _('Thought') end
    return row.type==1 and _('Highlight') or row.type==0 and _('Bookmark') or _('Cloud mark')
end
local function chapter_title(owner,row)
    if owner.thoughts and row.chapterName and row.chapterName~='' then return row.chapterName end
    return owner.chapter_titles and owner.chapter_titles[row.chapterUid]
        or owner.catalog_titles and owner.catalog_titles[row.chapterUid]
end
local function chapter(owner,row)
    return chapter_title(owner,row) or _('Chapter unavailable')
end
local function preview(value)
    return (Protocol.utf8_substr(value,80):gsub('[%z%c]',' '))
end
local function search_summary(value)
    local text=preview(value);local short=Protocol.utf8_substr(text,16)
    return #short<#text and short..'…' or short
end
local render,refresh
local function search_dialog(host,owner)
    local InputDialog=require('ui/widget/inputdialog')
    local dialog
    local function valid() return current(host,owner) and Popup.current(owner.menu,dialog) end
    local function apply(value)
        if not valid() then return end
        local query=SearchQuery.trim(value)
        if #query>1024 then host:showInfo(_('Search text is too long.'));return end
        owner.search=query~='' and query or nil
        owner.needle=Search.prepare(owner.search)
        Popup.close(owner.menu);render(host,owner)
    end
    dialog=InputDialog:new{title=_('Search saved notes'),input=owner.search or '',input_type='text',buttons={{
        {text=_('Clear'),callback=function() apply('') end},
        {text=_('Search'),is_enter_default=true,callback=function() apply(dialog:getInputText()) end},
    }}}
    Popup.show(owner.menu,dialog,function(widget) host:showInputDialog(widget) end)
end

local function matches(owner,row)
    if not owner.needle then return true end
    return Search.contains(row.content,owner.needle) or Search.contains(row.markText,owner.needle)
        or Search.contains(row.abstract,owner.needle) or Search.contains(chapter_title(owner,row),owner.needle)
end

local sort_labels={original='Original order',newest='Newest first',oldest='Oldest first',chapter='Chapter order'}
local function sort_dialog(host,owner)
    local dialog
    local function choice(mode)
        return {text=_(sort_labels[mode])..(owner.sort==mode and ' ✓' or ''),callback=function()
            if not current(host,owner) or not Popup.current(owner.menu,dialog) then return end
            owner.sort=mode;Popup.close(owner.menu);render(host,owner)
        end}
    end
    dialog=require('ui/widget/buttondialog'):new{title=_('Sort saved notes'),buttons={
        {choice('original')},{choice('newest')},{choice('oldest')},{choice('chapter')},
    }}
    Popup.show(owner.menu,dialog)
end

render=function(host,owner)
    if not current(host,owner) then return end
    Popup.redraw(owner.menu,function()
        if not current(host,owner) then return end
        owner.generation=(owner.generation or 0)+1
        local generation=owner.generation
        owner.chapter_titles={}
        for _i,item in ipairs(owner.value and owner.value.chapters or {}) do owner.chapter_titles[item.chapterUid]=item.title end
        local items={{text=_(owner.labels.refresh),callback=function() if current(host,owner) then refresh(host,owner) end end}}
        if not owner.writable then
            local notice=owner.bookmarks and 'Imported book bookmarks can be saved and deleted; locating requires a unique verified preview.'
                or owner.thoughts and 'Imported book private thoughts can be edited and deleted after verification.'
                or 'Imported book highlights support private thoughts, saving, deletion, style and color changes after verification.'
            items[#items+1]={text=_(notice),select_enabled=false}
        end
        local filters=owner.bookmarks and {} or owner.thoughts and {{'All my thoughts',nil},{'Thoughts with quoted text',1},{'Other thoughts',0}}
            or {{'All cloud marks',nil},{'Highlights only',1},{'Bookmarks only',0}}
        for _i,filter in ipairs(filters) do
            local selected=filter[2]
            items[#items+1]={text=_(filter[1]),mandatory=owner.filter==selected and '✓' or '',callback=function()
                if current(host,owner) then owner.filter=selected;render(host,owner) end
            end}
        end
        if owner.value then items[#items+1]={text=_('Search saved notes'),
            mandatory=owner.search and search_summary(owner.search) or '',callback=function()
                if current(host,owner) then search_dialog(host,owner) end
            end} end
        if owner.value then items[#items+1]={text=_('Sort saved notes'),mandatory=_(sort_labels[owner.sort]),callback=function()
            if current(host,owner) and owner.generation==generation then sort_dialog(host,owner) end
        end} end
        if owner.value then items[#items+1]={text=_('Export saved cloud notes'),callback=function()
            if current(host,owner) then require('weread.ui.cloud_notes_export').show(host,owner,current) end
        end} end
        if owner.mark_writable and not owner.bookmarks then items[#items+1]={text=_('Local thought drafts'),callback=function()
            if current(host,owner) then stop(host,owner);require('weread.ui.thought_editor').drafts(host,owner,current,render) end
        end}
        items[#items+1]={text=_('Check last thought change'),callback=function()
            if current(host,owner) then stop(host,owner);require('weread.ui.thought_editor').check(host,owner,current,render) end
        end} end
        if owner.mark_writable and not owner.thoughts then
            items[#items+1]={text=_('Check last cloud mark change'),callback=function()
                if current(host,owner) then stop(host,owner);require('weread.ui.mark_editor').check(host,owner,current,render) end
            end}
        end
        if owner.value then
            local stamp=owner.value.fetched_at
            local date=stamp<=4102444800 and os.date('%Y-%m-%d %H:%M',stamp) or _('Time unavailable')
            items[#items+1]={text=_(owner.labels.saved),mandatory=date,select_enabled=false}
            local count=0
            for _i,row in ipairs(Order.rows(owner.thoughts and owner.value.reviews or owner.value.updated,owner.sort)) do
                local has_quote=row.abstract~=nil and row.abstract~=''
                local row_type=owner.thoughts and (has_quote and 1 or 0) or row.type
                if (owner.filter==nil or row_type==owner.filter) and matches(owner,row) then
                    count=count+1
                    local content=owner.thoughts and row.content or row.markText
                    if not content or content=='' then content=row.abstract end
                    if not content or content=='' then content=chapter(owner,row) end
                    local label
                    items[#items+1]={text_func=function()
                        if label==nil then label=preview(content) end
                        return label
                    end,mandatory=kind(row,owner),
                        my_note_id=owner.thoughts and row.reviewId or row.bookmarkId,callback=function()
                        if not current(host,owner) or owner.generation~=generation then return end
                        local parts={chapter(owner,row)}
                        if owner.thoughts then
                            if has_quote then parts[#parts+1]=_('Quoted text')..'\n'..row.abstract end
                            if row.content~='' then parts[#parts+1]=_('Thought')..'\n'..row.content
                            else parts[#parts+1]=_('No thought text was returned.') end
                            if row.attachment_state=='partial' then parts[#parts+1]=_('Some thought attachments could not be displayed.') end
                            if row.attachment_state then parts[#parts+1]=_('Editing thoughts with attachments is not available yet.') end
                            if row.attachment_state and not row.attachment_digest then
                                parts[#parts+1]=_('Cannot safely delete this thought because its attachments could not be verified. Refresh the thought list and try again.')
                            end
                        else
                            if row.markText and row.markText~='' then parts[#parts+1]=row.markText end
                            if row.abstract and row.abstract~='' and row.abstract~=row.markText then parts[#parts+1]=row.abstract end
                        end
                        if #parts==1 then parts[#parts+1]=_(owner.thoughts and 'No thought text was returned.' or 'No saved quote text.') end
                        local viewer
                        local buttons
                        if owner.thoughts and row.attachment_state then
                            local urls=require('weread.lib.thought_attachments').decode(row.attachment_urls) or {}
                            for index in ipairs(urls) do
                                local selected=index
                                buttons=buttons or {};buttons[#buttons+1]={{id='thought_image_'..index,
                                    text=require('weread.lib.plugin_util').T(_('View thought image %1'),tostring(index)),callback=function()
                                    require('weread.ui.thought_images').open(host,owner,row,selected,viewer,current,generation)
                                end}}
                            end
                        end
                        local target=require(owner.thoughts and 'weread.lib.my_thought_target' or row.type==0 and 'weread.lib.my_bookmark_target' or 'weread.lib.my_mark_target')
                        if target.can_locate(row,not owner.writable and row.type==0) then
                            buttons=buttons or {};buttons[#buttons+1]={{id=owner.thoughts and 'open_thought_quote' or row.type==0 and 'open_bookmark' or 'open_highlight',
                                text=_(owner.thoughts and 'Open thought quoted text' or row.type==0 and 'Open bookmark position' or 'Open highlighted text'),callback=function()
                                if not current(host,owner) or not Popup.current(owner.menu,viewer) then return end
                                stop(host,owner)
                                require('weread.ui.my_mark_navigation').start(host,owner,row,current)
                            end}}
                        end
                        local editor=require('weread.ui.thought_editor')
                        if owner.mark_writable and not owner.thoughts and row.type==0 and target.can_locate(row) then
                            buttons=buttons or {};buttons[#buttons+1]={{id='delete_bookmark',text=_('Delete cloud bookmark'),callback=function()
                                if not current(host,owner) or not Popup.current(owner.menu,viewer) then return end
                                stop(host,owner);require('weread.ui.mark_editor').start(host,owner,'bookmark_delete',row,current,render)
                            end}}
                        end
                        if owner.mark_writable and not owner.thoughts and row.type==1 then
                            buttons=buttons or {};buttons[#buttons+1]={{id='delete_highlight',text=_('Delete highlight'),callback=function()
                                if not current(host,owner) or not Popup.current(owner.menu,viewer) then return end
                                stop(host,owner);require('weread.ui.mark_editor').start(host,owner,'delete',row,current,render)
                            end}}
                            local styles=require('weread.lib.mark_style')
                            if styles.editable(row) then
                                buttons[#buttons+1]={{id='change_highlight_style',text=_('Change highlight style'),callback=function()
                                    if not current(host,owner) or not Popup.current(owner.menu,viewer) then return end
                                    local choices={};local dialog
                                    for _j,style in ipairs(styles.values) do
                                        choices[#choices+1]={{id='highlight_style_'..style,text=_(styles.labels[style])..(row.style==style and ' ✓' or ''),
                                            enabled=row.style~=style,callback=function()
                                            if not current(host,owner) or not Popup.current(owner.menu,dialog) then return end
                                            stop(host,owner);require('weread.ui.mark_editor').start(host,owner,'style',row,current,render,style)
                                        end}}
                                    end
                                    dialog=require('ui/widget/buttondialog'):new{title=_('Change highlight style'),buttons=choices}
                                    Popup.show(owner.menu,dialog)
                                end}}
                            end
                            local colors=require('weread.lib.mark_color')
                            if colors.editable(row) then
                                buttons[#buttons+1]={{id='change_highlight_color',text=_('Change highlight color'),callback=function()
                                    if not current(host,owner) or not Popup.current(owner.menu,viewer) then return end
                                    local choices,dialog={}
                                    for _j,color in ipairs(colors.values) do
                                        choices[#choices+1]={{id='highlight_color_'..color,text=_(colors.labels[color])..(row.colorStyle==color and ' ✓' or ''),
                                            enabled=row.colorStyle~=color,callback=function()
                                            if not current(host,owner) or not Popup.current(owner.menu,dialog) then return end
                                            stop(host,owner);require('weread.ui.mark_editor').start(host,owner,'color',row,current,render,nil,color)
                                        end}}
                                    end
                                    dialog=require('ui/widget/buttondialog'):new{title=_('Change highlight color'),buttons=choices}
                                    Popup.show(owner.menu,dialog)
                                end}}
                            end
                        end
                        local operations=owner.mark_writable and (owner.thoughts and editor.can_edit(row) and (owner.writable or row.isPrivate==1)
                            and (row.attachment_state and (row.attachment_digest and {'delete'} or {}) or {'edit','delete'})
                            or not owner.thoughts and editor.can_create(row) and {'create'}) or {}
                        for _j,operation in ipairs(operations) do
                            buttons=buttons or {};buttons[#buttons+1]={{id='thought_'..operation,
                                text=_(operation=='create' and 'Write private thought' or operation=='edit' and 'Edit this thought' or 'Delete this thought'),callback=function()
                                    if not current(host,owner) or not Popup.current(owner.menu,viewer) then return end
                                    stop(host,owner);editor.start(host,owner,operation,row,current,render)
                                end}}
                        end
                        if require('weread.ui.excerpt_notes').text(owner,row) then
                            buttons=buttons or {};buttons[#buttons+1]={{id='excerpt_card',text=_('Excerpt card'),callback=function()
                                require('weread.ui.excerpt_notes').open(host,owner,row,viewer,current,generation)
                            end}}
                        end
                        viewer=require('weread.ui.thought_text').viewer{title=kind(row,owner),text=table.concat(parts,'\n\n'),
                            buttons_table=buttons,add_default_buttons=true}
                        Popup.show(owner.menu,viewer)
                    end}
                end
            end
            if count==0 then items[#items+1]={text=_(owner.needle and 'No matching notes in this view.' or owner.labels.empty),select_enabled=false} end
        else items[#items+1]={text=_(owner.labels.missing),select_enabled=false} end
        owner.menu:switchItemTable(nil,items)
    end)
end
refresh=function(host,owner,resume_draft,automatic)
    if not current(host,owner) or owner.context or owner.editor then return false end
    if not NetworkLink.available(host) then
        if resume_draft then
            host:showInfo(_('The original thought or highlight is unavailable. Refresh its notes and try again.'))
        elseif not automatic then
            host:showOffline(_(owner.labels.title))
        end
        return false
    end
    local access=owner.data.capture(host.settings)
    if not access then host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'));return false end
    local context={resume_draft=resume_draft,generation=owner.generation};owner.context=context
    local function valid()
        return current(host,owner) and owner.context==context
            and (context.renewing and Recovery.current(host.settings,access,owner.data.capture) or owner.data.matches(host.settings,access))
    end
    local function failed()
        if current(host,owner) then host:showInfo(_(owner.labels.failed)) end
    end
    host:showBusy(_(owner.labels.loading),function() if owner.context==context then stop(host,owner) end end)
    context.busy=host.busy_message
    if not owner.worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=Store.MAX_PAYLOAD} end)
        if not ok then stop(host,owner);failed();return false end
        owner.worker=worker
    end
    local launch
    local function complete(result)
        if not valid() then if owner.context==context then stop(host,owner) end;return end
        if type(result)=='table' and result.native_expired then
            local recovering=Recovery.start(host,context,access,{capture=owner.data.capture,
                is_current=function() return current(host,owner) and owner.context==context end,
                stale=function() if owner.context==context then stop(host,owner) end end,complete=function(success,renewed)
                    access=renewed
                    if success then launch() else stop(host,owner);failed() end
                end})
            if recovering then return end
        end
        stop(host,owner)
        local ok,value=pcall(owner.data.validate,host.client,result,owner.id)
        if not ok then failed();return end
        -- Persist before replacing the visible snapshot. A failed save leaves
        -- both the previous menu and its offline copy intact.
        local saved,success=pcall(owner.store.write,owner.store,value)
        if not current(host,owner) then return end
        if not saved or not success then host:showInfo(_(owner.labels.save_failed));return end
        local display=package.loaded['weread.ui.personal_marks']
        if display then
            local changed
            if owner.thoughts then changed=display.thoughts_changed else changed=display.changed end
            if type(changed)=='function' then changed(host,value) end
        end
        local resume=context.resume_draft and owner.generation==context.generation and not owner.menu._shelf_popup
        owner.value=value;render(host,owner)
        if resume and current(host,owner) and not owner.menu._shelf_popup then
            require('weread.ui.thought_editor').resume(host,owner,context.resume_draft.key,context.resume_draft.token,current,render)
        end
    end
    launch=function()
        if not valid() then stop(host,owner);return false end
        local ok,started=pcall(owner.worker.start,owner.worker,function()
            local success,value=pcall(owner.data.fetch,host.client,owner.id,access,{recover_auth=host.native_renewal~=nil and not context.recovery_attempted})
            return success and value or {native_expired=value==(owner.data.EXPIRED or 'my_marks/native_expired')}
        end,complete)
        if not ok or not started then stop(host,owner);failed();return false end
        return true
    end
    return launch()
end
local function show(host,id,variant,request,saved_note_id)
    if not Data.display_id(id) or not host.library_db then return false end
    local scope=host.settings:get_auth_scope()
    local account=host.library_db:accountKey()
    if not account or not scope or not host.settings:auth_scope_matches(scope) then
        if not saved_note_id then host:showInfo(_('Please scan the QR code to log in first.')) end
        return false
    end
    if not saved_note_id then M.cancel(host) end
    local thoughts=variant=='thoughts'
    local owner={id=id,scope=scope,thoughts=thoughts,writable=Data.id(id)~=nil,mark_writable=Data.display_id(id)~=nil,bookmarks=variant=='bookmarks',filter=variant=='bookmarks' and 0 or nil,sort='original',
        data=thoughts and require('weread.lib.my_cloud_thoughts') or Data,account=account,epoch=host.discovery_epoch or 0,
        session=host._reader_session_gen,document=host.ui and host.ui.document,parent=host._book_detail_view,
        store=Store:new(host.library_db,host.client,thoughts and 'thoughts' or nil)}
    local read_ok,value=pcall(owner.store.read,owner.store,id);owner.value=read_ok and value or nil
    if saved_note_id then
        local found=false
        for _,row in ipairs(owner.value and (thoughts and owner.value.reviews or owner.value.updated) or {}) do
            if (thoughts and row.reviewId or row.bookmarkId)==saved_note_id then found=true;break end
        end
        if not found then return false end
    end
    if owner.account~=host.library_db:accountKey() or not host.settings:auth_scope_matches(scope) then return false end
    if saved_note_id then M.cancel(host) end
    if not thoughts and type(host.library_db.getChapters)=='function' then
        local ok,chapters=pcall(host.library_db.getChapters,host.library_db,id)
        owner.catalog_titles={}
        if ok and type(chapters)=='table' then for _i,row in ipairs(chapters) do
            if type(row)=='table' and Data.id(tostring(row.chapterUid)) and tonumber(row.chapterUid)<=2147483647 and type(row.title)=='string'
                and #row.title>0 and #row.title<=4096 and Protocol.utf8_substr(row.title,#row.title)==row.title
                and not row.title:find('[%z%c]') then owner.catalog_titles[tonumber(row.chapterUid)]=row.title end
        end end
    end
    owner.labels=thoughts and {title='My cloud thoughts',refresh='Refresh my cloud thoughts',saved='Saved cloud thoughts',
        empty='No thoughts in this view.',missing='No saved thoughts. Refresh while online.',failed='Could not update my thoughts. Saved thoughts are kept.',
        loading='Loading my thoughts…\nTap or press a key to cancel.',save_failed='Could not save my thoughts. The previous saved copy is kept.'}
        or {title='My cloud highlights',refresh='Refresh my cloud marks',saved='Saved cloud marks',empty='No cloud marks in this view.',
            missing='No saved cloud marks. Refresh while online.',failed='Could not update my cloud marks. Saved marks are kept.',
            loading='Loading my cloud marks…\nTap or press a key to cancel.',save_failed='Could not save my cloud marks. The previous saved copy is kept.'}
    if owner.bookmarks then owner.labels.title='My cloud bookmarks';owner.labels.empty='No cloud bookmarks in this view.' end
    if owner.account~=host.library_db:accountKey() or not host.settings:auth_scope_matches(scope) then return false end
    local menu=host:showList(_(owner.labels.title),{{text=_(owner.labels.missing),select_enabled=false}},nil,{thought_text=true})
    if not menu then return false end
    owner.menu=menu;host._my_marks_owner=owner;host._my_marks_menu=menu
    local on_close=menu.onCloseWidget
    menu.onCloseWidget=function(instance,...)
        instance._shelf_closed=true;Popup.close(instance);stop(host,owner)
        if host._my_marks_owner==owner then host._my_marks_owner=nil;host._my_marks_menu=nil end
        if on_close then return on_close(instance,...) end
    end
    render(host,owner)
    if saved_note_id then
        for _,item in ipairs(menu.item_table or {}) do
            if item.my_note_id==saved_note_id then
                item.callback()
                if current(host,owner) and menu._shelf_popup then return true end
                break
            end
        end
        if host._my_marks_owner==owner then M.cancel(host) end
        return false
    end
    -- Draft selection remains bound to its token while a missing reference is
    -- loaded; a later user action or popup prevents an unsolicited editor.
    if request and (owner.value or request.selection) then
        require('weread.ui.thought_editor').resume(host,owner,request.key,request.token,current,render)
    elseif not owner.value then
        refresh(host,owner,request,true)
    end
    return true
end

function M.show(host,id,variant,options)
    if variant~=nil and variant~='thoughts' and variant~='bookmarks' then return false end
    local request=type(options)=='table' and options.resume_draft or nil
    if options~=nil and (type(request)~='table' or request.book_id~=id
        or not require('weread.lib.thought_edit_contract').hash(request.key)
        or type(request.token)~='string' or #request.token~=32 or not request.token:match('^[a-f0-9]+$')
        or request.operation~='create' and request.operation~='edit' or type(request.selection)~='boolean'
        or (request.operation=='edit')~=(variant=='thoughts')) then return false end
    return show(host,id,variant,request)
end

function M.open_saved(host,id,note_kind,note_id)
    if note_kind~='marks' and note_kind~='thoughts' then return false end
    if not Data.valid_text(note_id,256) or note_id:find('%s') then return false end
    return show(host,id,note_kind=='thoughts' and 'thoughts' or nil,nil,note_id)
end
return M
