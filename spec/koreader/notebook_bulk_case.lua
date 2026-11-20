-- Synthetic HTTP responses, actual native menu, worker pipe and SQLite.
return function(plugin,owner,mode,counters,wait,tick)
    local json=require('json');local ffi=require('ffi')
    local client=require('weread.lib.client');local request=client.request
    local cache=require('weread.lib.my_cloud_marks_store')
    local all=owner.value.books;assert(#all>=4)
    local a,b=all[3].bookId,all[4].bookId
    assert(a=='900003' and b=='900004')
    local function item(label)
        for _,row in ipairs(owner.menu.item_table) do
            if row.text==require('weread.lib.i18n').tr(label) then return row end
        end
        error('bulk notebook menu missing')
    end
    local function read(id,kind)
        return assert(cache:new(plugin.library_db,plugin.client,kind=='thoughts' and 'thoughts' or nil):read(id))
    end
    if mode=='live' then
        local parent=tonumber(ffi.C.getpid());local transient=plugin.showTransientInfo
        plugin.showTransientInfo=function() end
        function client:request(options)
            local h=options.headers or {};local id=options.url and options.url:match('bookId=(%d+)')
            local marks=options.url=='https://i.weread.qq.com/book/bookmarklist?bookId='..tostring(id)..'&synckey=0'
            local thoughts=options.url=='https://i.weread.qq.com/review/list?bookId='..tostring(id)
                ..'&listType=11&listMode=0&mine=1&synckey=0&count=20'
            if (id==a or id==b) and (marks or thoughts) and options.method=='GET' and options.body==nil
                and options.skip_cookie and options.persist_response_cookies==false and options.sensitive
                and h.vid=='900000' and h.accessToken=='synthetic-notebook-access' and not h.Cookie
                and tonumber(ffi.C.getpid())~=parent then
                counters[10]=counters[10]+1
                if marks then return json.encode({updated={{bookmarkId='bulk-mark-'..id,type=1,markText='bulk saved mark'}},chapters=json.decode('[]')}),200 end
                return json.encode({reviews={{review={reviewId='bulk-thought-'..id,bookId=id,userVid='900000',content='bulk saved thought'}}},
                    totalCount=1,hasMore=false}),200
            end
            counters[11]=counters[11]+1;error('synthetic notebook bulk scope rejected',0)
        end
        owner.value.books={all[3],all[4]}
        owner.menu:onMenuSelect(item('Save all notebook notes for offline use'))
        wait(function() return owner.bulk_context~=nil end)
        local job=owner.bulk_context;assert(job.dialog and job.dialog.progress_max==4)
        wait(function() return not owner.bulk_context end)
        assert(job.done==4 and counters[10]==4 and counters[11]==0)
        assert(read(a,'marks').updated[1].bookmarkId=='bulk-mark-'..a)
        assert(read(a,'thoughts').reviews[1].reviewId=='bulk-thought-'..a)
        assert(read(b,'marks').updated[1].bookmarkId=='bulk-mark-'..b)
        assert(read(b,'thoughts').reviews[1].reviewId=='bulk-thought-'..b)
        owner.menu:onMenuSelect(item('Save all notebook notes for offline use'))
        wait(function() return owner.bulk_context~=nil end);job=owner.bulk_context
        wait(function() return job.done==1 end)
        job.dialog.buttons[1][1].callback();tick()
        assert(not owner.bulk_context and job.done==1 and counters[10]==5 and counters[11]==0)
        owner.value.books=all;client.request=request;plugin.showTransientInfo=transient
    else
        assert(read(a,'marks').updated[1].bookmarkId=='bulk-mark-'..a)
        assert(read(a,'thoughts').reviews[1].reviewId=='bulk-thought-'..a)
        assert(read(b,'marks').updated[1].bookmarkId=='bulk-mark-'..b)
        assert(read(b,'thoughts').reviews[1].reviewId=='bulk-thought-'..b)
        assert(counters[10]==0 and counters[11]==0)
    end
    print('PASS: notebook bulk native worker, SQLite, cancellation and offline cache')
end
