-- MiuRead-style home and discovery flow on the existing WeRead service layer.
local Data = require("weread.lib.discovery_data")
local PluginUtil = require("weread.lib.plugin_util")
local UIManager = require("ui/uimanager")
local Scope = require("weread.ui.page_scope")
local Popup = require("weread.ui.shelf_popup")
local ReadAccess = require("weread.lib.read_access")
local ShelfSnapshot = require("weread.lib.shelf_snapshot")
local VolatileShelf = require("weread.lib.volatile_shelf")
local BookstoreNavigation = require("weread.ui.bookstore_navigation")
local _ = PluginUtil.tr
local M = {}
local view_position = BookstoreNavigation.position

local function home_recent(host,account,limit)
    local settings=host.settings
    local shelf=host.shelf_regular
    local books=settings.home_recent_books and settings:home_recent_books(account,Data.recent_floor(shelf,limit))
        or settings:get('books',{})
    return Data.recent(shelf,books,account,limit)
end

function M:discoveryNavigation(active, current, on_leave)
    local function switch(callback)
        return function()
            if current and not current() then return end
            if on_leave then on_leave() end
            self:closeWeReadUI()
            callback()
        end
    end
    return {
        { text = _("Home"), active = active == "home",
            callback = switch(function() self:showHome() end) },
        { text = _("Bookshelf"), active = active == "shelf",
            callback = switch(function() self:showBookshelf(true) end) },
        { text = _("Bookstore"), active = active == "store",
            callback = switch(function() self:openBookstore() end) },
        { text = _("My WeRead"), active = active == "profile",
            callback = switch(function() self:showProfile() end) },
    }
end

function M:showDiscoveryPage(tab, books, options)
    local LibraryView = require("weread.ui.library_view")
    options = options or {}
    local previous=self.shelf_view
    local carry_dirty
    if previous and previous._finish_dirty and previous._finish_current and previous._finish_current()
        and not require('weread.ui.finish_offline').reconcile_view(self,previous) then carry_dirty=previous._finish_dirty end
    local home = options.home
    local downloads = tab == 'downloads'
    local show_reason=false
    if tab=='store' then for _,book in ipairs(books) do
        if type(book.reason)=='string' and book.reason~='' then show_reason=true;break end
    end end
    local cover_mode = not home or home.view_mode ~= "list"
    if downloads then cover_mode = self.settings:get('shelf').view_mode == 'cover' end
    local extra_height=downloads and options.actions and #options.actions>0 and 162 or 108
    local layout = LibraryView.getLayout(cover_mode, #books, "books", extra_height, {
        home = home, store = tab=='store',
        show_page_bar = options.on_previous_batch ~= nil or options.on_next_batch ~= nil,
    })
    local focus_book_index=options.focus_book_id and LibraryView.bookIndex(books,options.focus_book_id)
    local page_anchor=focus_book_index or options.rotation_anchor
    local page_count = math.max(1, math.ceil(#books / layout.page_size))
    local target_page=options.last_page and page_count
        or page_anchor and math.floor((page_anchor-1)/layout.page_size)+1 or options.page or 1
    options.rotation_anchor,options.focus_book_id,options.last_page=nil,nil,nil
    local page = math.max(1, math.min(target_page, page_count))
    options.page=page
    local cover_paths, visible = {}, {}
    local cache = cover_mode and self:getShelfCoverCache()
    local saved, downloaded = not downloads and ReadAccess.book_lookup(self.settings) or nil, {}
    for index = (page - 1) * layout.page_size + 1, math.min(#books, page * layout.page_size) do
        local book = books[index]
        if cache then cover_paths[book] = cache:pathFor(book) end
        if not downloads then book._cached = self:isBookDownloaded(book, saved, downloaded) end
        visible[#visible + 1] = book
    end
    local snapshots = tab == "home" and self.prepareShelfProgress and self:prepareShelfProgress(visible,saved)
    self:cancelShelfCovers()
    if self.stopHomeStatusTimer then self:stopHomeStatusTimer() end
    if previous then
        if (home and previous._discovery_tab=='home')
            or (downloads and previous._discovery_tab=='downloads')
            or options.bookstore_state and previous._bookstore_state==options.bookstore_state then
            previous._discovery_redrawing=true
        end
        if self.checkpointShelfBrowse then self:checkpointShelfBrowse() end
        UIManager:close(previous)
    end
    local view, scope
    local function current() return scope and scope() end
    local hold = options.on_hold or not downloads and function(book, owner, page_current)
        require('weread.ui.book_quick_actions').open(self, owner, book, page_current)
    end
    local function redraw(next_page)
        if not current() then return end
        options.page = next_page
        Popup.redraw(view, function()
            if not current() or self._book_detail_view then return end
            if (home or options.bookstore_state) and options.page==view.page then
                options.focus_book_id=view:getFocusedBookId()
            end
            self:showDiscoveryPage(tab, books, options)
        end)
    end
    view = LibraryView.show({
        mode = "books", portal = true, title = options.title,
        empty_text = options.empty_text, actions = Scope.entries(current, options.actions),
        home_layout = home,
        store_details = tab=='store', store_reason = show_reason,
        status_text = home and self:homeStatusText(),
        summary_text = home and self:homeReadingSummary(),
        navigation = self:discoveryNavigation(tab, current), books = books,
        finish_pending = require('weread.ui.finish_offline').snapshot(self),
        cover_mode = cover_mode, paged = true, page = page,
        page_size = layout.page_size, focus_book_index = focus_book_index, cover_columns = layout.columns,
        cover_rows = layout.rows, cover_paths = cover_paths,
    }, {
        on_search = Scope.guard(current, function()
            if options.on_search then options.on_search(view, current) else self:showDiscoverySearch() end
        end),
        on_refresh = Scope.guard(current, downloads and function()
            options.on_refresh(view:getBrowsePosition())
        end or options.on_refresh),
        on_settings = Scope.guard(current, downloads and options.on_settings and function()
            options.on_settings(view, current)
        end or home and function() self:showHomeQuickSettings() end),
        on_summary = home and Scope.guard(current, function() self:closeWeReadUI() self:showProfile() end) or nil,
        on_select = Scope.guard(current, function(book)
            if options.on_select then options.on_select(book)
            elseif tab == "home" then
                local id=ShelfSnapshot.persisted_id(book)
                local stored=id and ReadAccess.cached_book(ReadAccess.book_lookup(self.settings),id)
                local resume=stored and stored.native_home_resume and require('weread.ui.native_home_resume')
                if resume then
                    if resume.can_resume(self,stored,id) then resume.open(self,stored,id,view,current)
                    else self:showBookRecord(book) end
                elseif stored and book._cached and self:bookRecordHasDownload(stored) then
                    self:startBookReading(stored,nil,nil,{record=stored})
                else self:showBookRecord(book) end
            else self:showBookRecord(book) end
        end),
        on_hold = hold and Scope.guard(current, function(book) hold(book, view, current) end),
        on_page_changed = redraw,
        on_previous_batch = Scope.guard(current, options.on_previous_batch),
        on_next_batch = Scope.guard(current, options.on_next_batch),
        on_back = Scope.guard(current, options.on_back),
        on_close = function()
            if self.shelf_view == view then
                if view._shelf_checkpoint then view._shelf_checkpoint() end
                self.shelf_view = nil
                self:closeWeReadUI()
            end
        end,
    })
    self.shelf_view = view
    view._finish_dirty=carry_dirty
    view._discovery_tab = tab
    local state=options.bookstore_state
    if home or state or options.remember_position then
        local account=self.library_db and self.library_db:accountKey()
        view._bookstore_state=state
        view._browse_account=account
        local flush=view.onFlushSettings
        local function remember(widget)
            if not widget._shelf_closed and not widget._discovery_redrawing
                and (self.library_db and self.library_db:accountKey())==account
                and (home or options.remember_position or self.discovery_state==state and state.account==account) then
                if home then
                    local position=view_position(widget)
                    position.account=account
                    self._home_browse_position=position
                elseif options.remember_position then
                    options.remember_position(widget:getBrowsePosition())
                else
                    local position=view_position(widget)
                    local prior=state._browse_position
                    if not state._browse_saved or not prior or prior.anchor~=position.anchor or prior.focus~=position.focus then
                        state._browse_position=position
                        state._browse_saved=require('weread.ui.discovery_cache').remember(self,state,position)
                    end
                end
            end
        end
        view.onFlushSettings=function(widget,...)
            remember(widget)
            if flush then return flush(widget,...) end
        end
        if options.remember_position then
            view._shelf_checkpoint=function()
                if self.shelf_view==view then remember(view) end
            end
        end
    end
    scope = Scope.capture(self, view)
    view._rotation_redraw=function()
        if not current() then return end
        local position=view_position(view)
        Popup.redraw(view,function()
            if current() and not self._book_detail_view then
                options.rotation_anchor=position.anchor
                options.focus_book_id=position.focus
                self:showDiscoveryPage(tab,books,options)
            end
        end)
    end
    view._discovery_current = current
    view._finish_current = current
    local function return_to_page(current_books)
        if options.on_return then return options.on_return(view:getBrowsePosition()) end
        local position=view_position(view)
        options.page=view.page
        options.focus_book_id=position.focus
        options.rotation_anchor=position.anchor
        local function render()
            self:showDiscoveryPage(tab,current_books,options)
        end
        if options.focus_book_id then render()
        else
            require('weread.ui.finish_offline').redraw_preserving_focus(self,view,render)
        end
    end
    view._shelf_snapshot_redraw = function()
        local updated=books
        if home then
            local prefs=self:homePreferences()
            updated=home_recent(self,self.library_db and self.library_db:accountKey(),prefs.recent_limit)
        end
        return_to_page(updated)
    end
    view._finish_redraw = function()
        if not current() then return end
        require('weread.ui.finish_offline').redraw_preserving_focus(self,view,function()
            options.page=view.page;self:showDiscoveryPage(tab,books,options)
        end)
    end
    view._prepare_detail_return = function(snapshot_current)
        if not current() then
            if snapshot_current then return function()
                if self.shelf_view==view and not view._shelf_closed then view._shelf_snapshot_redraw() end
            end end
            return
        end
        require('weread.ui.finish_offline').reconcile_view(self,view)
        return function()
            if self.shelf_view == view and not view._shelf_closed then
                return_to_page(books)
            end
        end
    end
    if home and self.startHomeStatusTimer then self:startHomeStatusTimer(view, false) end
    if snapshots then
        local force = options.refresh_progress
        options.refresh_progress = nil
        self:refreshVisibleShelfProgress(view, visible, snapshots, {
            force = force, on_redraw = function()
                if self.repaintShelfProgress then
                    local updated = self:repaintShelfProgress(view, function(current_books)
                        return self:prepareShelfProgress(current_books)
                    end)
                    if updated then snapshots = updated;return end
                end
                Popup.redrawForMetadata(self,view,function() redraw(view.page or page) end)
            end,
        })
    elseif self.cancelShelfProgress then self:cancelShelfProgress() end
    if cover_mode and not downloads then
        self:fetchVisibleShelfCovers(view, books, { on_redraw = redraw },
            { page = page, page_size = layout.page_size, paths = cover_paths })
    end
end

function M:recordRecentReading(book_id)
    -- Keep the legacy field untouched: older local and pending positions may
    -- still depend on it for their account identity.
    return self.settings:patch_reading_state(book_id, {
        home_recent_at = os.time(), home_recent_account = self.library_db:accountKey() or '', native_home_resume=false,
    })
end

function M:showHome(refresh_progress, refreshed_shelf)
    if self._profile_view then self:closeWeReadUI() end
    local account=self.library_db and self.library_db:accountKey()
    local position=self._home_browse_position
    if position and position.account~=account then position=nil end
    local view=self.shelf_view
    if view and view._discovery_tab=='home' and not view._shelf_closed and view._browse_account==account then
        position=view_position(view)
    end
    local cached, archives, shelf_preferences
    local volatile = VolatileShelf.get(self)
    if type(refreshed_shelf) == "table" and type(refreshed_shelf.books) == "table"
        and type(refreshed_shelf.archives) == "table" then
        cached, archives = refreshed_shelf.books, refreshed_shelf.archives
    elseif volatile then
        cached, archives = volatile.books, volatile.archives
    elseif self.library_db then
        cached, archives, shelf_preferences = self.library_db:getShelfSnapshot(true)
    end
    self:applyShelfSnapshot(cached or {}, archives,
        volatile ~= nil and volatile.books == cached and volatile.archives == archives, shelf_preferences)
    local preferences = self:homePreferences()
    local recent = home_recent(self,account,preferences.recent_limit)
    local anchor = position and position.anchor
    if position and position.book_id then
        anchor = require('weread.ui.library_view').bookIndex(recent, position.book_id) or anchor
    end
    self:showDiscoveryPage("home", recent, {
        title = _("WeRead home"),
        home = preferences,
        rotation_anchor=anchor,focus_book_id=position and position.focus,
        refresh_progress = refresh_progress and type(refreshed_shelf) == "table" and refreshed_shelf.refreshed_progress or refresh_progress,
        empty_text = _("No recent reading. Refresh or open your bookshelf."),
        actions = self:homeShortcuts(preferences),
        on_refresh = function() self:refreshHome() end,
    })
end

function M:refreshHome()
    self:refreshBookshelf(self.shelf_view, { on_loaded = function(saved, snapshot, groups_incomplete)
        self:showHome(true, snapshot)
        if groups_incomplete and not saved then
            self:showTransientInfo(_("The bookshelf did not include group information. This temporary list is not saved; refresh again later."), 5)
        elseif not saved then
            self:showTransientInfo(_("Could not save the bookshelf for offline use. The current list is still available."), 4)
        end
    end })
end

function M:showDiscoverySearch(initial_keyword)
    local InputDialog = require("ui/widget/inputdialog")
    local owner = self.shelf_view
    if not owner or owner._shelf_closed then return end
    local current = Scope.capture(self, owner)
    if not current() then return end
    local state=self.discovery_state
    local account=self.library_db and self.library_db:accountKey()
    if initial_keyword==nil and account and owner._discovery_tab=='store' and state and state.kind=='search'
        and state.account==account then initial_keyword=state.keyword end
    if type(initial_keyword)~='string' or #initial_keyword>4096 or initial_keyword:find('[%z%c]')
        or require('weread.lib.protocol').utf8_substr(initial_keyword,#initial_keyword+1)~=initial_keyword then
        initial_keyword=''
    end
    local dialog
    local function valid() return current() and Popup.current(owner, dialog) end
    dialog = InputDialog:new{
        title = _("Search WeRead"), input = initial_keyword, input_type = "text",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() if valid() then Popup.close(owner) end end },
            { text = _("Search"), is_enter_default = true, callback = function()
                if not valid() then return end
                local keyword = require("weread.lib.search_query").trim(dialog:getInputText())
                if keyword == "" then return end
                Popup.close(owner)
                self:loadDiscoveryBatch("search", keyword, 0)
            end },
            { text = _("Saved searches"), callback = function()
                if not valid() then return end
                -- Keep the input owned by the page while the worker runs so
                -- background redraws wait until the replacement menu closes.
                require("weread.ui.saved_searches").open(self, dialog)
            end },
        },{
            { text = _("Search suggestions"), callback = function()
                if valid() then require("weread.ui.search_suggestions").open(self, dialog) end
            end },
            { text = _("Public book search"), callback = function()
                if not valid() then return end
                local keyword=require('weread.lib.search_query').trim(dialog:getInputText())
                if keyword=='' then return end
                Popup.close(owner)
                self:loadDiscoveryBatch('search',keyword,0,false,false,{public_search=true})
            end },
        },{
            { text = _("Recent searches"), callback = function()
                if valid() then require("weread.ui.recent_searches").open(self, dialog) end
            end },
        }},
    }
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        require("weread.ui.search_suggestions").cancel(self)
        if on_close then return on_close(widget,...) end
    end
    Popup.show(owner, dialog, function(widget) self:showInputDialog(widget) end)
end

function M:showSimilarBooks(book)
    local id = book and (book.bookId or book.book_id)
    if not id or tostring(id) == "" then return end
    local view = self.shelf_view
    local origin = self._book_detail_view and view and not view._shelf_closed
        and (view._bookstore_state or view._discovery_tab == 'home' or view._shelf_return_position) and view or nil
    self:loadDiscoveryBatch("similar", nil, 0, false, false, {
        book_id = tostring(id), book_title = book.title or tostring(id),
        return_view = origin,
    })
end

function M:showDiscoveryCategoryPicker(data)
    local menu
    local owner = self.shelf_view
    local scope = Scope.capture(self, owner)
    local function current()
        return self._discovery_menu==menu and scope() and (not owner or Popup.current(owner, menu))
    end
    local function dismiss()
        if self._discovery_menu == menu then self._discovery_menu = nil end
        if owner then Popup.close(owner) elseif menu then UIManager:close(menu) end
    end
    local function browse(entry)
        if not current() then return end
        dismiss()
        self:loadDiscoveryBatch("category", nil, 0, false, false, {
            category_id = entry.id, category_title = entry.title, rank = entry.rank,
        })
    end
    local function rows(entries)
        local items = {}
        for _i, entry in ipairs(entries) do
            local item = { text = entry.title, callback = function() browse(entry) end }
            if #entry.children > 0 then
                item.sub_item_table = rows(entry.children)
                table.insert(item.sub_item_table, 1, {
                    text = PluginUtil.T(_("All in %1"), entry.title), callback = item.callback,
                })
            end
            items[#items + 1] = item
        end
        if #items == 0 then items[1] = { text = _("No available categories."), select_enabled = false } end
        return items
    end
    local function result_rows(keyword)
        local Search = require('weread.lib.shelf_search')
        local needle = Search.prepare(keyword)
        local terms = Search.terms(needle)
        local items = {}
        local function match(entries, path)
            for _, entry in ipairs(entries) do
                if Search.matches({title=entry.title,author=path},needle,terms) then
                    items[#items+1] = {text=entry.title .. '  ·  ' .. path,entry=entry}
                end
                if #entry.children>0 then match(entry.children,path .. ' › ' .. entry.title) end
            end
        end
        match(data.ranks, _('Book rankings'))
        match(data.categories, _('Browse categories'))
        if #items==0 then items[1]={text=_('No matching rankings or categories.'),select_enabled=false} end
        return items
    end
    local prompt
    local function show_results(keyword)
        local results
        results = self:showList(_('Ranking and category results'),result_rows(keyword),nil,{
            left_icon='appbar.search',on_choice=function(item)
                if not current() or not Popup.current(menu,results) or results._shelf_popup or not item.entry then return end
                browse(item.entry)
            end,
        })
        if not results then return end
        results.onLeftButtonTap=function() return prompt(results,keyword) end
        local closed=results.onCloseWidget
        results.onCloseWidget=function(widget,...)
            widget._shelf_closed=true
            Popup.close(widget)
            if closed then return closed(widget,...) end
        end
        Popup.show(menu,results,function() end)
    end
    prompt=function(source,keyword)
        local function active()
            return current() and (source==menu or Popup.current(menu,source))
        end
        if not active() or source._shelf_popup then return true end
        local dialog
        local function submit(value)
            if not active() or not Popup.current(source,dialog) then return end
            local query=require('weread.lib.search_query').trim(value)
            if #query>1024 then self:showInfo(_('Search text is too long.'));return end
            Popup.close(source)
            if query==keyword then return end
            if query=='' then Popup.close(menu) else show_results(query) end
        end
        dialog=require('ui/widget/inputdialog'):new{
            title=_('Find a ranking or category'),input=keyword,input_type='text',
            buttons={{
                {text=_('Clear'),callback=function() submit('') end},
                {text=_('Search'),is_enter_default=true,callback=function() submit(dialog:getInputText()) end},
            }},
        }
        Popup.show(source,dialog,function(widget) self:showInputDialog(widget) end)
        return true
    end
    local old_menu=self._discovery_menu;self._discovery_menu=nil
    if old_menu then UIManager:close(old_menu) end
    local title = _("Rankings and categories")
    local age=os.time()-data.loaded_at
    if age<0 or age>Data.CACHE_TTL then title = _("Cached") .. " · " .. title end
    menu = self:showList(title, {
        { text = _("Book rankings"), sub_item_table = rows(data.ranks) },
        { text = _("Browse categories"), sub_item_table = rows(data.categories) },
        { text = _("Refresh rankings and categories"), callback = function()
            if not current() then return end
            dismiss()
            self:showDiscoveryCategories(true)
        end },
    },nil,{left_icon='appbar.search'})
    if not menu then return end
    menu.onLeftButtonTap=function() return prompt(menu,'') end
    self._discovery_menu = menu
    local function forget()
        if self._discovery_menu == menu then
            self._discovery_menu = nil
            if not owner then self.discovery_epoch = (self.discovery_epoch or 0) + 1 end
        end
    end
    local on_close = menu.onCloseWidget
    menu.onCloseWidget = function(widget, ...)
        widget._shelf_closed=true
        Popup.close(widget)
        forget()
        if on_close then return on_close(widget, ...) end
    end
    menu.close_callback = forget
    if owner then Popup.show(owner, menu, function() end) end
end

function M:showDiscoveryCategories(refresh)
    return require("weread.ui.category_catalog").open(self,refresh)
end

local function initialChart()
    return { category_id = "rising", category_title = _("Rising · Published"), rank = true }
end

-- Load the public chart only on an explicit entry into an otherwise empty
-- store. Redraws and requests that finish later must not restart this work.
function M:openBookstore()
    self:showBookstore()
    local owner = self.shelf_view
    if not owner or self.discovery_state or self.discovery_loading then return end
    local current = owner._discovery_current
    UIManager:nextTick(function()
        if not current or not current() or self.shelf_view ~= owner or self.discovery_state
            or self.discovery_loading or owner._shelf_popup or self.category_catalog_request
            or not require('weread.lib.network_link').available(self) then return end
        self:loadDiscoveryBatch("category", nil, 0, false, false, initialChart())
    end)
end

function M:showBookstore(batch_direction)
    if self._profile_view then self:closeWeReadUI() end
    local state = self.discovery_state
    if state and state.account ~= self.library_db:accountKey() then
        self.discovery_state = nil
        state = nil
    end
    if not state then
        self._bookstore_history = nil
        state=require('weread.ui.discovery_cache').read(self)
        self.discovery_state=state
    end
    local actions = {
        { text = _("For you"), callback = function() self:loadDiscoveryBatch("recommend", nil, 0) end },
        { text = _("Search WeRead"), callback = function() self:showDiscoverySearch() end },
        { text = _("Browse books"), callback = function() self:showDiscoveryCategories() end },
    }
    local function turn_batch(previous, direction)
        local cursor = previous and state.history[#state.history] or state.next_cursor
        self:loadDiscoveryBatch(state.kind, state.keyword, cursor, previous, false, state, direction)
    end
    local has_next = state and state.has_more
    local has_previous = state and #state.history > 0
    if has_next then
        actions[#actions + 1] = { text = _("Next batch"), callback = function()
            turn_batch(false)
        end }
    end
    if has_previous then
        actions[#actions + 1] = { text = _("Previous batch"), callback = function()
            turn_batch(true)
        end }
    end
    local title = _("Bookstore")
    if state then
        title = state.kind == "search" and PluginUtil.T(_("Search: %1"), state.keyword) or _("For you")
        if state.kind=='search' and state.source_kind=='public' then title=PluginUtil.T(_("Public search: %1"),state.keyword) end
        if state.kind == "similar" then title = PluginUtil.T(_("Similar to: %1"), state.book_title) end
        if state.kind == "category" then title = state.category_title end
        if state.cached or os.time() - state.loaded_at > Data.CACHE_TTL then title = _("Cached") .. " · " .. title end
    end
    local position=not batch_direction and state and state._browse_position
    local view=self.shelf_view
    if not batch_direction and state and view and view._bookstore_state==state and not view._shelf_closed then
        position=view_position(view)
    end
    self:showDiscoveryPage("store", state and state.books or {}, {
        title = title, actions = actions,
        bookstore_state=state,rotation_anchor=position and position.anchor,focus_book_id=position and position.focus,
        last_page=batch_direction==-1,
        on_previous_batch=has_previous and function() turn_batch(true,-1) end or nil,
        on_next_batch=has_next and function() turn_batch(false,1) end or nil,
        on_back = state and function() return BookstoreNavigation.back(self, state) end or nil,
        empty_text = state and (state.kind == "similar" and _("No similar books found.")
            or state.kind == "search" and _("No search results.") or _("No books found."))
            or _("Choose For you or search to discover books."),
        on_refresh = function()
            self:loadDiscoveryBatch(state and state.kind or "category", state and state.keyword,
                state and state.cursor or 0, false, true, state or initialChart())
        end,
    })
end

function M:cancelDiscoveryRequest()
    require("weread.ui.category_catalog").cancel(self)
    local suggestions=package.loaded['weread.ui.search_suggestions']
    if suggestions then suggestions.cancel(self) end
    return require("weread.ui.discovery_request").cancel(self)
end

function M:loadDiscoveryBatch(kind, keyword, cursor, previous, refresh, context, batch_direction)
    if kind=='search' and cursor==0 and not previous and not refresh then
        pcall(function()
            require('weread.lib.recent_searches').record(self,keyword,type(context)=='table' and context.public_search==true or false)
        end)
    end
    return require("weread.ui.discovery_request").load(self, kind, keyword, cursor, previous, refresh, context, batch_direction)
end

return M
