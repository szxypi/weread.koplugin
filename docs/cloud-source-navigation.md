# 精确打开云端阅读位置

阅读微信读书 EPUB 时，菜单新增“精确打开云端阅读位置”。
使用当前账号的 Web 登录读取云端位置，在后台核对原文后，由 KOReader 原生引擎跳转。
不要求 Skill 密钥，不打开网页界面；这是读取与本地导航，不改变阅读进度上传协议。

## 协议验证先于接入

`scripts/verify_cloud_source_target.py` 先通过真实账号验证，随后才实现 `source_cloud.lua`：

1. 固定 GET `/web/book/getProgress?bookId=...`，读取章 UID、章内偏移与百分比。
2. 固定 GET 该书／章的 Reader 页面，严格解析 `__INITIAL_STATE__`。
   书 ID、当前章节及内嵌阅读位置必须与第一步一致；不从零散 HTML 字段猜测位置。
3. 复用该 Reader 的 `psvts`，仅 POST 读取 `e_0`、`e_1`、`e_3` 三个内容分片。
   这是既有正文读取接口，不发送进度、阅读时长、书架或笔记写入。
4. 再次 GET 同一进度地址；书／章／偏移／百分比有变化就拒绝结果。
5. 在过滤后的 UTF-16 原文模型中取得唯一上下文并反向核对，
   标签、空白、实体内部、标量内部、短文或歧义位置均不得向邻近文字吸附。

[真实去敏报告](validation-assets/2026-11-09/cloud-source-target-owner-readonly.json)核对同一已读样本：
云端与内嵌位置一致，当前官方解析器的 11,430 个正文节点通过核对，目标节点存在。
Python 与 Lua 对同一响应的投影一致；KOReader HTTPS 独立六次读取后，完整目标投影也一致。
Lua 只发出三 GET 与三个正文读取 POST，凭据、位置、原文、书 ID 和摘要只在内存比较。
报告仅含阶段状态、数量和布尔值，不保存私有正文、坐标或原文摘要。
这证明读取样本及模型一致，不证明服务端原子快照、所有内容类型、精确上传或服务器版本语义。

## 与当前 EPUB 绑定

后台进程独立打开当前路径的归档，核对父进程固定的文件 ID、书 ID、目标章元数据及路径别名。
云端原文的 SHA-256 和字节数必须与该章下载时保存的原文完全一致，格式必须为 `web_xhtml`。
随后按既有原文准备流程重新验证本机原文／渲染章摘要和唯一目标，再返回文件绑定位置及少量元数据。
文件身份、摘要不一致，缺少目标章、原文或回执，均拒绝精确跳转。

这里依靠正文一致性，不猜测原生 `version`、Web `bookVersion` 或本机书库版本是否含义相同。
当前已打开文档保持固定身份；后台路径被同名新文件替换也无法通过独立归档检查。
父进程只读小型身份／章节元数据，不在界面线程读取原文、渲染章或重建原文索引。
工作结果限制为 64 KiB，不含原始正文、Reader 会话或 Cookie；章节原文仍限制为 2 MiB。

现有 `source_navigation` 再按真实文档的章节来源和 DOM 核对，使用原生 XPointer 导航。
分页模式保证目标文字在当前页可见，不声称目标一定是页首。
刚跳转的原文偏移作为本次精确目标保留，复用原有重排／移动失效规则，避免被页首位置覆盖。
目标的 `upload_verified` 保持 false；本次读取不授予上传确认，也不把原文单位混入旧字数协议。
进入操作时撤销该书原有上报确认，并取消尚未发送的旧上传任务；已保存的本地意图仍保留。
只有本次精确目标确实应用并保留后，才移除被云端选择替代的旧意图；失败或取消不删除它，
也不自动重放旧任务。其他书籍的独立上传不受影响。
当前书籍的进度上报等待重新核对，界面会明确提示；已有阅读时长请求进行中时暂不启动此操作。

## 取消与边界

- 请求固定当前文档对象、路径、文件身份、阅读代次、账号、登录代次和捕获的读取凭据。
  另绑定导航代次，新手动同步或其他导航可以替代旧请求。
  翻页、账号切换、关书、重新打开、休眠或新导航会取消旧请求，迟到结果不能再跳转。
- 读取与本地准备均在内存工作进程中运行；原生 DOM 操作仍留在阅读器进程并协作让出执行。
  原生导航取消会通知其上层请求，立即关闭等待窗并解除采集暂停，不留下等待状态。
- 加载提示可直接取消；原生菜单选择后关闭菜单，结果显示在正常阅读器中。
  未登录时引导 Web 扫码；没有 Skill 密钥不触发密钥申请或循环登录。
- 离线不发请求，429 不重试、不改用百分比定位。无法核对时提示失败，
  缺少目标章或原文不符时提示下载目标章节或整本书。
- 整书中包含的其他章节可以精确跳转。当前单章文件不包含目标章时，
  暂不自动下载／切换文件后续接目标；该跨文件协调仍待完成。
- TXT、复杂生成内容、更多真实位置／书籍类型、跨设备及实体 KO2 仍待验收。
  精确写入、独立回读和服务器版本含义保持未验证，不以只读跳转代替完整精确同步验收。

开发验证继续使用两个已获用户授权的 macOS 钥匙串条目，读取前后核对同一账号，
服务器更新的 Web Cookie 经核对后保存／回读；不创建凭据文件或第三个条目。
整体目标未完成，不因单次验证结束清理条目。

## 复验

默认离线，不访问钥匙串、网络或浏览器：

```sh
python3 scripts/verify_cloud_source_target.py
python3 scripts/test_cloud_source_target.py
luajit spec/source_cloud_spec.lua
luajit spec/cloud_source_ui_spec.lua
```

显式复用已保存的当前账号进行真实只读对照；未指定书时最多检查八本现有书架书籍：

```sh
/path/to/python-with-playwright scripts/verify_cloud_source_target.py \
  --saved-session --official-parser --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/cloud_source_probe.lua /source
```

官方解析器先在无账号的新浏览器中加载，随后断开网络和 WebSocket，才将私有正文交给解析器；
不向浏览器导入账号 Cookie，不保存节点或截图。原文不会进入后续去敏报告。

原生运行验证使用合成账号、实际 HTTP、下载的 EPUB、独立归档、原生菜单及 ReaderUI：

```sh
xvfb-run -a python3 scripts/test_position_runtime.py --probe cloud-source \
  --koreader /path/to/koreader --run-dir /path/to/new-evidence-directory \
  --width 1264 --height 1680 --dpi 300
```

600×800 与 KO2 分辨率分别保存隔离日志、候选包摘要、`cloud-source.json` 和目标页截图。
重绘警告会使运行失败；桌面分辨率模拟不作为实体按键、网络、残影、耗电或性能验收。
