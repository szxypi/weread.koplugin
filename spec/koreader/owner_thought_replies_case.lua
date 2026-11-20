-- One independently identified, public reply list in an actual ReaderUI.
-- The parent case owns the private tmpfs profile and all other HTTP guards.
return function(input, mode, counters)
    local directory = assert(debug.getinfo(1, 'S').source:match('^@(.*/)'))
    local parent = dofile(directory .. 'owner_annotations_case.lua')(input, mode, counters)
    local check = assert(input.annotations.reply_check)
    local reply = {compared = false, parent_closed = false, position_unchanged = false, requests = 0, denied_progress = 0}
    parent.report.reply_check = reply
    local Protocol = require('weread.lib.protocol')
    local expected_url = 'https://i.weread.qq.com/review/single?reviewId=' .. Protocol.urlencode(check.review_id)
        .. '&commentsCount=21&commentsDirection=0&likesCount=0&synckey=0'
    local original_request = parent.request
    function parent:request(client, options, dispatch)
        if options.url ~= expected_url then return original_request(self, client, options, dispatch) end
        local headers = options.headers or {}
        local credentials = input.annotations.credentials
        assert(mode == 'live' and self.enabled and tonumber(counters[26]) == 0 and options.method == 'GET'
            and not options.body and options.sensitive == true and options.skip_cookie == true
            and options.persist_response_cookies == false and headers.vid == input.vid
            and headers.accessToken == credentials.accessToken and not headers.Cookie and not headers.cookie
            and not headers.Authorization and not headers.authorization, 'reply request scope rejected')
        counters[26] = counters[26] + 1
        return dispatch(client, options)
    end
    function parent:check_replies(plugin, reader, popup, pump, tick, source)
        if mode ~= 'live' then return end
        local UI = require('ui/uimanager')
        local current = reader.document:getXPointer()
        local page = reader:getCurrentPage()
        local old_source = plugin.client:json_encode(source)
        assert(type(check.index) == 'number' and popup.items[check.index])
        assert(popup._viewport and popup._page_starts)
        local hold_y
        for index = 1, #popup._page_starts do
            popup:changePage(index - popup.page_index); tick(); UI:forceRePaint()
            local area = popup._viewport.dimen
            local offset = popup._pages:getPageContentStart(popup.page_index, popup._page_starts)
            local ending = popup._page_starts[popup.page_index + 1] or popup._pages.content_h
            for _, piece in ipairs(popup._pages.layout.pieces) do
                if piece.y and piece.piece_h and piece.piece_h > 1 then
                    local y = piece.y + 1
                    local screen_y = area.y + y - offset
                    if y < ending and screen_y >= area.y and screen_y < area.y + area.h
                        and popup:_findItemAtContentY(y) == popup.items[check.index] then hold_y = screen_y; break end
                end
            end
            if hold_y then break end
        end
        assert(hold_y, 'selected thought is not visible')
        local area = popup._viewport.dimen
        local point = require('ui/geometry'):new{x = area.x + math.floor(area.w/2), y = hold_y, w = 1, h = 1}
        popup:onHoldThought(nil, {pos = point})
        local menu = assert(UI:getTopmostVisibleWidget())
        assert(menu.buttons and menu.buttons[2] and menu.buttons[2][1])
        menu.buttons[2][1].callback()
        pump(function() return plugin._native_review_replies_owner and plugin._native_review_replies_owner.view end)
        local owner = plugin._native_review_replies_owner
        local actual = owner.view.result
        local expected = require('weread.lib.native_review_replies').project(plugin.client, check.expected,
            input.book_id, check.review_id, 20, nil, 1)
        assert(#expected.items > 0 and #actual.items == #expected.items and actual.has_more == expected.has_more)
        for index, item in ipairs(actual.items) do
            local other = expected.items[index]
            for _, field in ipairs({'review_id', 'author', 'content', 'rating', 'create_time', 'is_finish'}) do
                assert(item[field] == other[field])
            end
        end
        reply.compared = true
        popup:onClose(); tick()
        assert(not plugin._thought_reply_owner and not plugin._native_review_replies_owner and not UI:isWidgetShown(popup))
        reply.parent_closed = true
        local store = assert(plugin._annotation_context).store
        assert(reader:getCurrentPage() == page and reader.document:getXPointer() == current
            and plugin.client:json_encode(store:get(input.book_id, 'source', input.chapter_uid)) == old_source)
        reply.position_unchanged = true
    end
    local original_finish = parent.finish
    function parent:finish(reason)
        original_finish(self, reason)
        reply.requests = tonumber(counters[26])
        reply.denied_progress = tonumber(counters[27])
    end
    return parent
end
