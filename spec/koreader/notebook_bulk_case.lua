-- Synthetic HTTP responses, actual native menu, worker pipe and SQLite.
return function(plugin,owner,mode,counters,wait,tick)
    local json=require('json');local ffi=require('ffi')
    local socket=require('socket')
    local client=require('weread.lib.client');local request=client.request
    local cache=require('weread.lib.my_cloud_marks_store')
    local all=owner.value.books;assert(#all>=4)
    local a,b=all[3].bookId,all[4].bookId
    assert(a=='900003' and b=='900004')
    local c,d=assert(all[5]).bookId,assert(all[6]).bookId
    assert(c=='900005' and d=='900006')
    local large,permitted={}, {[a]=true,[b]=true,[c]=true,[d]=true}
    for i=1,65 do
        local id=tostring(910000+i);large[#large+1]={bookId=id,title='Synthetic large '..i}
        permitted[id]=true
    end
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
        local image_url='https://weread-picture-1258476243.file.myqcloud.com/notebook-fixture.png'
        function client:request(options)
            local h=options.headers or {};local id=options.url and options.url:match('bookId=(%d+)')
            if options.url==image_url and options.method=='GET' and options.skip_cookie and options.sensitive
                and not options.persist_response_cookies and not h.Cookie and not h.Authorization
                and tonumber(ffi.C.getpid())~=parent then
                counters[12]=counters[12]+1;assert(options.sink(require('weread.lib.native_missing_image')))
                options.sink(nil);return nil,200
            end
            local marks=options.url=='https://i.weread.qq.com/book/bookmarklist?bookId='..tostring(id)..'&synckey=0'
            local thoughts=options.url=='https://i.weread.qq.com/review/list?bookId='..tostring(id)
                ..'&listType=11&listMode=0&mine=1&synckey=0&count=20'
            if permitted[id] and (marks or thoughts) and options.method=='GET' and options.body==nil
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
        -- Cancel one new book after its first set, then resume only the three
        -- missing sets; repeat once to verify the all-cached no-request path.
        owner.value.books={all[5],all[6]}
        owner.menu:onMenuSelect(item('Save all notebook notes for offline use'))
        wait(function() return owner.bulk_context~=nil end);job=owner.bulk_context
        wait(function() return job.done==1 end);job.dialog.buttons[1][1].callback();tick()
        assert(not owner.bulk_context and counters[10]==6)
        owner.menu:onMenuSelect(item('Save only missing notebook notes'))
        wait(function() return owner.bulk_context~=nil end);job=owner.bulk_context
        wait(function() return not owner.bulk_context end)
        assert(job.done==3 and job.saved==3 and job.already==1 and counters[10]==9 and counters[11]==0)
        owner.menu:onMenuSelect(item('Save only missing notebook notes'))
        wait(function() return owner.bulk_context~=nil end);job=owner.bulk_context
        wait(function() return not owner.bulk_context end)
        assert(job.done==0 and job.saved==0 and job.already==4 and counters[10]==9)
        assert(read(c,'marks').updated[1].bookmarkId=='bulk-mark-'..c)
        assert(read(c,'thoughts').reviews[1].reviewId=='bulk-thought-'..c)
        assert(read(d,'marks').updated[1].bookmarkId=='bulk-mark-'..d)
        assert(read(d,'thoughts').reviews[1].reviewId=='bulk-thought-'..d)
        owner.value.books=large
        owner.menu:onMenuSelect(item('Save all notebook notes for offline use'))
        wait(function() return owner.bulk_context~=nil end);job=owner.bulk_context
        assert(#job.ids==65 and job.skipped==0 and job.dialog.progress_max==130)
        local deadline=socket.gettime()+150
        while owner.bulk_context do assert(socket.gettime()<deadline,'large notebook update deadline');tick() end
        assert(job.done==130 and counters[10]==139 and counters[11]==0)
        for _,book in ipairs(large) do
            assert(read(book.bookId,'marks').updated[1].bookmarkId=='bulk-mark-'..book.bookId)
            assert(read(book.bookId,'thoughts').reviews[1].reviewId=='bulk-thought-'..book.bookId)
        end
        local source={reviews={{reviewId='bulk-thought-'..a,review={reviewId='bulk-thought-'..a,bookId=a,userVid='900000',
            content='bulk saved thought',pictures={{url=image_url}}}}},totalCount=1,hasMore=false}
        local thought=require('weread.lib.my_cloud_thoughts').project(plugin.client,source,a,'900000',1000)
        assert(cache:new(plugin.library_db,plugin.client,'thoughts'):write(thought))
        owner.value.books={all[3],all[4]}
        owner.menu:onMenuSelect(item('Save images from saved thoughts'))
        wait(function() return owner.image_bulk_context~=nil end);local image_job=owner.image_bulk_context
        wait(function() return not owner.image_bulk_context end)
        assert(image_job.saved==1 and image_job.cached==0 and image_job.done==2 and counters[12]==1 and counters[11]==0)
        local images=require('weread.lib.thought_image_store');local image_key=assert(images.key(a,'bulk-thought-'..a,image_url))
        local image_store=images:new(plugin.library_db);local account=plugin.library_db:accountKey()
        assert(image_store:read(account,image_key)==require('weread.lib.native_missing_image'))
        owner.menu:onMenuSelect(item('Save images from saved thoughts'))
        wait(function() return owner.image_bulk_context~=nil end);image_job=owner.image_bulk_context
        wait(function() return not owner.image_bulk_context end)
        assert(image_job.saved==0 and image_job.cached==1 and counters[12]==1)
        owner.menu:onMenuSelect(item('Clear saved thought and review images'))
        local confirm=assert(owner.menu._shelf_popup);confirm.ok_callback()
        wait(function() return owner.image_bulk_context~=nil end);wait(function() return not owner.image_bulk_context end)
        assert(not image_store:read(account,image_key) and read(a,'thoughts').reviews[1].reviewId=='bulk-thought-'..a)
        owner.value.books=all;client.request=request;plugin.showTransientInfo=transient
    else
        assert(read(a,'marks').updated[1].bookmarkId=='bulk-mark-'..a)
        assert(read(a,'thoughts').reviews[1].reviewId=='bulk-thought-'..a)
        assert(read(b,'marks').updated[1].bookmarkId=='bulk-mark-'..b)
        assert(read(b,'thoughts').reviews[1].reviewId=='bulk-thought-'..b)
        assert(read(c,'marks').updated[1].bookmarkId=='bulk-mark-'..c)
        assert(read(c,'thoughts').reviews[1].reviewId=='bulk-thought-'..c)
        assert(read(d,'marks').updated[1].bookmarkId=='bulk-mark-'..d)
        assert(read(d,'thoughts').reviews[1].reviewId=='bulk-thought-'..d)
        for _,book in ipairs(large) do
            assert(read(book.bookId,'marks').updated[1].bookmarkId=='bulk-mark-'..book.bookId)
            assert(read(book.bookId,'thoughts').reviews[1].reviewId=='bulk-thought-'..book.bookId)
        end
        assert(counters[10]==0 and counters[11]==0)
    end
    print('PASS: notebook bulk native worker, SQLite, cancellation and offline cache')
end
