-- Inject a single 401 into the normal selected-book reading path.
return function(plugin, kind)
    local Json, HTTP, LTN=require('json'),require('socket.http'),require('ltn12')
    local function request(path,data)
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local paths={reader='/web/reader/',repeat401='/web/reader/',forbidden='/web/reader/',limited='/web/reader/',catalog='/web/book/chapterInfos',chapter='/web/book/chapter/e_0'}
    local path=assert(paths[kind])
    local before=request('/__state').totals
    local function count(rows,wanted)
        local total=0;for _,row in ipairs(rows) do if row.path==wanted then total=total+row.count end end;return total
    end
    local prior=count(before,'/web/login/renewal')
    local expected=(kind=='forbidden' or kind=='limited') and 0 or 1
    local status=kind=='forbidden' and 403 or kind=='limited' and 429 or 401
    request('/__control',{match=path,times=kind=='repeat401' and -1 or 1,status=status,web_renewal_mode='rotate'})
    local old_open,credentials_saved=plugin.openFile,false
    local old_info,notice=plugin.showInfo,nil
    plugin.showInfo=function(self,text,...)
        notice=text;return old_info(self,text,...)
    end
    plugin.openFile=function(self,...)
        self.showInfo=old_info
        self.openFile=old_open
        local scope=assert(self.settings:get_auth_scope())
        local auth=assert(require('weread.lib.web_authorization').capture(self.settings))
        assert(auth.scope.vid==scope.vid and auth.scope.epoch==scope.epoch)
        assert(self.settings:get('cookies',{}).wr_skey == (expected==1 and 'XXXrenewed-native' or 'mock-only'))
        credentials_saved=true
        return old_open(self,...)
    end
    local function reset()
        local text=kind=='repeat401' and 'WeRead login expired. Please sign in again and retry.'
            or kind=='limited' and 'WeRead is limiting requests. Download stopped. Please try again later.'
            or 'Could not prepare this book for reading. Check your connection and login, then try again.'
        assert(notice==require('weread.lib.i18n').tr(text),'failure did not show the appropriate notice')
        request('/__control',{match='',times=0})
    end
    return function(reader)
        local rows=request('/__state').totals
        assert(count(rows,'/web/login/renewal')==prior+expected,'reading did not perform exactly one renewal')
        assert(credentials_saved and reader.weread.settings:get_auth_scope())
        assert(reader.weread:detectWeReadBook()=='900001')
        local f=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/reading-auth-recovery.json','wb'))
        f:write(Json.encode{result='PASS',stage=kind,renewals=expected,same_account=true,credentials_saved_before_handoff=true,native_reader=true});f:close()
    end,reset
end
