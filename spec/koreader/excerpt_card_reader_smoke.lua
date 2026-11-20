-- Synthetic selection in actual ReaderUI; no account or network mutations.
return function(reader,plugin,pump,shot,clean_popups,reopen)
    local UI=require('ui/uimanager');local Device=require('device');local lfs=require('libs/libkoreader-lfs')
    local Selection=require('weread.ui.excerpt_selection')
    local matches=assert(reader.document:findAllText('我们沿着小路慢慢前行',false,0,10,false,0))
    assert(matches[1]);local first,last=matches[1].start,matches[1]['end']
    local text=assert(reader.document:getTextFromXPointers(first,last))
    assert(text~='');reader.rolling:onGotoXPointer(first);UI:forceRePaint()
    local original_online=plugin.isNetworkOnline
    plugin.isNetworkOnline=function() return false end
    local function select()
        clean_popups(reader)
        reader.highlight.selected_text={pos0=first,pos1=last,text=text}
        reader.highlight:onShowHighlightMenu();UI:forceRePaint()
        assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_excerpt_card')):onTapSelectButton()
    end
    local function open()
        select();pump(function() return plugin._excerpt_card_editor~=nil end)
        local editor=assert(plugin._excerpt_card_editor)
        assert(editor.context.text==text and not reader.highlight.selected_text)
        return editor
    end
    local previous_clipboard=Device.input.setClipboardText;local copied
    Device.input.setClipboardText=function(value) copied=value end
    local editor=open();UI:forceRePaint()
    if reopen then
        assert(editor.selection.template_idx==4 and editor.selection.background_idx==2,'offline reopen lost card style')
        local directory=plugin.settings.data_dir..'/exports/cards';local files=0
        for name in lfs.dir(directory) do if name:match('%.png$') then files=files+1 end end
        assert(files==1,'offline reopen lost saved card')
        shot('excerpt-offline-reopen');assert(editor:onBack());plugin.isNetworkOnline=original_online
        Device.input.setClipboardText=previous_clipboard
        return
    end
    assert(editor.frame:getSize().w<=Device.screen:getWidth() and editor.frame:getSize().h<=Device.screen:getHeight(),
        'excerpt editor exceeds the screen')
    shot('excerpt-editor')
    local transfer=require('weread.lib.excerpt_transfer');local start=transfer.start
    transfer.start=function(png,options)
        options.address='127.0.0.1';options.allow_loopback=true
        return start(png,options)
    end
    assert(editor.export_buttons:getButtonById('share_excerpt')):onTapSelectButton()
    local share=assert(plugin._excerpt_share,'phone transfer did not open')
    UI:forceRePaint();shot('excerpt-phone-qr')
    assert(share.dialog:getContentSize().h<=Device.screen:getHeight(),'phone QR dialog exceeds the screen')
    local socket=require('socket');local connection=assert(socket.tcp());connection:settimeout(1)
    local port=tonumber(share.server.url:match(':(%d+)/'));assert(connection:connect('127.0.0.1',port))
    connection:settimeout(0);local path=assert(share.server.url:match('^http://[^/]+(/.+)$'))
    assert(connection:send('GET '..path..'card.png HTTP/1.1\r\nHost: local\r\n\r\n'))
    local answer=''
    for _=1,1000 do
        share.server:poll()
        local data,err,partial=connection:receive(65536);answer=answer..(data or partial or '')
        if err=='closed' then break end
    end
    assert(answer:find('200 OK',1,true) and answer:find('\137PNG\r\n\26\n',1,true),'phone did not receive PNG')
    connection:close();share.dialog:onClose();assert(not plugin._excerpt_share and share.server.stopped)
    assert(plugin._excerpt_card_editor==editor,'closing phone transfer closed editor')
    transfer.start=start
    assert(editor.export_buttons:getButtonById('copy_excerpt_text')):onTapSelectButton()
    assert(copied==text,'clipboard did not receive the selected text')
    local copied_message=UI:getTopmostVisibleWidget();assert(copied_message~=editor);UI:close(copied_message)
    for index=1,6 do
        assert(editor.template_strip:getButtonById('btn_tpl_'..index)):onTapSelectButton()
        assert(editor.selection.template_idx==index)
    end
    local card=require('weread.lib.excerpt_card.init');local render=card.renderBB
    local previous=editor.selection.template_idx
    card.renderBB=function() return nil,'synthetic_failure' end
    editor:_on_select_template(1)
    assert(editor.selection.template_idx==previous and editor.preview_image,'failed preview changed selected template')
    local failed=UI:getTopmostVisibleWidget();assert(failed~=editor);UI:close(failed)
    card.renderBB=render
    assert(editor.template_strip:getButtonById('btn_tpl_4')):onTapSelectButton()
    editor.color_strip[1][3]:onTapSelect();UI:forceRePaint()
    assert(editor.selection.template_idx==4 and editor.selection.background_idx==2)
    assert(editor:onScreenResize() and editor:onRotation());UI:forceRePaint()
    assert(editor.selection.template_idx==4 and editor.selection.background_idx==2 and editor.preview_image)
    shot('excerpt-background')
    editor:_save_png()
    local directory=plugin.settings.data_dir..'/exports/cards';local output={}
    for name in lfs.dir(directory) do if name:match('%.png$') then output[#output+1]=directory..'/'..name end end
    assert(#output==1,'excerpt save did not create exactly one file')
    local f=assert(io.open(output[1],'rb'));assert(f:read(8)=='\137PNG\r\n\26\n');f:close()
    local info=UI:getTopmostVisibleWidget();assert(info~=editor);UI:close(info)
    assert(editor:onBack());assert(not plugin._excerpt_card_editor)
    editor=open();assert(editor.selection.template_idx==4 and editor.selection.background_idx==2,'card style was not kept')
    local identity=plugin.library_db.accountKey;plugin.library_db.accountKey=function() return 'foreign-account' end
    editor:_save_png()
    plugin.library_db.accountKey=identity
    local files=0;for name in lfs.dir(directory) do if name:match('%.png$') then files=files+1 end end
    assert(files==1,'stale account editor saved a card')
    transfer.start=function(png,options)
        options.address='127.0.0.1';options.allow_loopback=true
        return start(png,options)
    end
    assert(editor.export_buttons:getButtonById('share_excerpt')):onTapSelectButton()
    local suspended_share=assert(plugin._excerpt_share)
    plugin:onSuspend();assert(not plugin._excerpt_card_editor and not plugin._excerpt_share and suspended_share.server.stopped,
        'suspend left excerpt transfer open')
    transfer.start=start
    plugin:onResume();clean_popups(reader)
    select();Selection.cancel(plugin)
    UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
    assert(not plugin._excerpt_card_editor,'canceled selection reopened card editor')
    local after={};for name in lfs.dir(directory) do if name:match('%.png$') then after[#after+1]=name end end
    assert(#after==1,'closing card caused an extra save')
    plugin.isNetworkOnline=original_online
    Device.input.setClipboardText=previous_clipboard
end
