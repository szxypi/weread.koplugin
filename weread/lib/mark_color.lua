-- Official public reader palette; create/update values independently proved
-- with fresh test marks before native integration. Default follows style.
local Style=require('weread.lib.mark_style')
local M={values={0,1,2,3,4,5},labels={[0]='Default color',[1]='Pink',[2]='Purple',[3]='Blue',[4]='Green',[5]='Yellow'}}
function M.valid(color) return type(color)=='number' and color%1==0 and color>=0 and color<=5 end
function M.default(settings)
    local color=settings:get('cloud_highlight_color',0)
    return M.valid(color) and color or 0
end
function M.editable(row)
    return type(row)=='table' and row.type==1 and Style.valid(row.style) and M.valid(row.colorStyle)
end
return M
