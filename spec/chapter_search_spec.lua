package.path = "./?.lua;" .. package.path

package.preload['weread.ui.shelf_popup']=function() return {} end
package.preload['weread.lib.plugin_util']=function()
    return {tr=function(value) return value end,T=function(_,index,label) return index..'. '..label end}
end
local folds=0
package.loaded['ffi/utf8proc']={
    count=function(value) return #value,not value:find('\255',1,true) end,
    lowercase=function(value)
        folds=folds+1
        value=value:gsub('ＦＯＯ','foo'):gsub('É','é'):gsub('\226\128\139','')
        return value:lower()
    end,
}
local ChapterSearch=require('weread.ui.chapter_search')
local Search=require('weread.lib.shelf_search')
local rows={{title='ＦＯＯ ÉLAN %'}, {title='ＦＯＯ ÉLAN %'}, {title='ÉLAN foo'},
    {title=''}, {title='a\0b'}, {title='\255x'}, {title=42,author='foo'}, {}}
local filter=ChapterSearch.title_filter(rows,'Untitled chapter')
assert(filter('')==nil and folds==0,'clearing or opening the unfiltered list normalized titles')
local matches,counts=filter('foo　Élan')
assert(table.concat(matches,',')=='1,2,3' and counts[rows[1].title]==2)
assert(ChapterSearch.label(rows[1].title,2,counts)=='2. '..rows[1].title)
local before=folds
assert(table.concat(filter('chapter untitled'),',')=='4' and folds==before+1,
    'another search did not reuse the title normalization from its catalog')
assert(table.concat(filter('%'),',')=='1,2')
assert(table.concat(filter('A\0B'),',')=='5')
assert(table.concat(filter('\255'),',')=='6')
assert(#filter('\226\128\139')==0,'an ignorable-only query matched everything')
assert(#filter('foo absent')==0 and #filter('42')==0,'search expanded beyond the chapter title')
local copies={{title='First copy',chapter_uid='38'},{title='Second copy',chapterUid='38'},
    {title='Another chapter',chapter_uid='138'},{chapter_uid='38'}}
assert(table.concat(ChapterSearch.title_filter(copies,nil,true)('38'),',')=='1,2',
    'chapter ID search lost an exact copy or matched part of another ID')
assert(#ChapterSearch.title_filter(copies)('38')==0,'title-only search matched a chapter ID')
rows[1].title='Edited'
assert(table.concat(filter('edited'),',')=='1','a changed title kept an obsolete normalization')
local new_filter=ChapterSearch.title_filter({{title='ÉLAN foo'}})
before=folds
assert(#new_filter('foo')==1 and folds==before+2,'another catalog used the old catalog cache')
local limited=Search.cached_fold(2,4)
before=folds
assert(limited('abc')=='abc' and limited('abc')=='abc' and folds==before+2,
    'a value exceeding the byte budget was retained')
assert(limited('a')=='a' and limited('b')=='b')
before=folds
assert(limited('a')=='a' and limited('b')=='b' and folds==before,'budgeted folds were not retained')
print('chapter_search_spec: literal, Unicode, multiword, duplicates and catalog lifetime passed')
