package.path='./?.lua;'..package.path
package.preload['ui/widget/confirmbox']=function() return {new=function(_,value) return value end} end
package.preload['ui/widget/infomessage']=function() return {new=function(_,value) return value end} end
local shown
package.preload['ui/uimanager']=function() return {show=function(_,value) shown=value end} end
package.preload['ffi/util']=function() return {template=function(value) return value end} end
package.loaded.gettext={current_lang='zh_CN'}

local dialog=require('weread.ui.progress_sync_dialog')
dialog.notify('upload_failed',{error='source_initial_time_unverified'})
assert(shown and shown.text=='微信读书已记录本书的阅读、听书或录制时长，但尚无章节位置，暂不支持此状态下的首次同步。本机阅读位置已保留，未上传任何进度。',
    'first-sync restriction was not explained in Chinese')
dialog.notify('local_unavailable',{error='partial_combined_book'})
assert(shown.text=='无法确认此合并文件与完整书籍一致，本次阅读暂不进行进度同步，原有位置已保留。',
    'partial combined-book synchronization restriction was not explained')
package.loaded.gettext.current_lang='en'
dialog.notify('upload_failed',{error='source_initial_time_unverified'})
assert(shown.text:find('no chapter position',1,true) and shown.text:find('nothing was uploaded',1,true),
    'first-sync restriction was not explained in English')
print('progress_sync_dialog_spec: initial-time restriction displayed in Chinese and English')
