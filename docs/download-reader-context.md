# 下载阅读页的同书核对

下载与切章继续通过 KOReader 原生 EPUB 阅读。读取网页只用于获取正文会话，不显示网页界面。
本轮完善旧缓存地址的处理，防止当前书籍复用另一书的阅读页或非标准地址。

## 行为

- 先核对 `book_id`／`bookId`，两者同时存在时必须表示同一本书；冲突、非法值和公众号 ID 不发送普通书籍请求。
  数字 ID、现有不透明字母数字 ID 与章节 0 的处理有明确边界；此规则不代表个人上传功能已实现。
- 缓存地址只接受 HTTPS 的 `weread.qq.com` 标准阅读路径，书籍编码必须与当前书籍一致。
  同书的合法章节后缀保留，分享查询与片段移除。其他来源、端口、账号、控制字符和额外路径自动改用当前书籍的标准地址。
  显式切章时重新生成目标章节地址，不让旧链接覆盖选择。
- 返回页面必须具有可解析的 `window.__INITIAL_STATE__.reader.bookInfo`，其中书 ID 必须匹配当前书籍。
  若当前位置或进度提供书 ID，也须一致。不从正文中的零散 `bookId`／`psvts` 文本猜测有效会话。
- `psvts` 必须为有界、非空且无控制／空白字符的字符串；可选 token 与 pclts 分别校验。
  真实响应中 `pclts` 可为数字 0，该值保留。响应省略的字段不会沿用旧会话。
  校验前清除旧下载会话；只有整个响应通过后，才合并已验证的资料和位置。
- 返回错书、无效会话或网络失败时停止本次下载，不继续取得章节正文；既有 EPUB、缓存路径、待上传记录和当前本机位置不被错误页面替换。
  页面校验、页面加载和目录加载失败分别给出固定中文提示，不显示原始响应、查询、解析异常或会话字段。
- 目录查询仍使用现有请求正文，引用地址改用同书标准地址。失败保留已有目录，诊断使用敏感读取模式。

实现为 `weread/lib/reader_context.lua` 和 `Content.ensure_reader_state`／`refresh_reader_state`／`fetch_catalog`。
原有 `ReaderState.extract` 的其他调用保持兼容；本轮的严格规则限定于下载会话，不将旧的宽松解析器宣称为全局严格解析器。

## 真实只读验证

先运行 Python 原型，再接入 Lua。两个真实书籍页面与同账号 139 本书架核对通过。
随后 Python／Lua 对相同响应的完整会话投影一致；KOReader HTTPS 独立读取两个页面后，
把各自响应在私有管道中交回 Python 再核对，投影一致。
会话值可能随每次请求变化，因此不会拿上一次会话值要求下一次请求相等。
真实页面、会话值、位置、书 ID 和摘要只留在内存，报告只记录状态、数量与布尔值。
没有账号数据写入，既有开发授权仍按原约定保留。

[真实去敏报告](validation-assets/2026-11-09/reader-context-owner-readonly.json)。默认离线复验：

```sh
python3 scripts/verify_reader_context.py
python3 scripts/test_reader_context.py
luajit spec/reader_context_spec.lua
```

显式复用已经保存的授权，进行模型及原生 HTTPS 对照：

```sh
python3 scripts/verify_reader_context.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/reader_context_probe.lua /source
```

Python 11 项、Lua 模型／下载协调 38 项及客户端 128 项检查覆盖地址、身份、会话、错误与状态保留。
原生 `reader_context_smoke.lua` 进入完整核心流程：使用实际 HTTP、JSON、Content 和已有 EPUB，
在传输边界故意注入另一本合成书的真实 HTTP 页面，确认错误页面不能继续下载，原 EPUB 摘要与待上传状态保持。
另覆盖章节选择、分享参数、同书目录引用、HTTP 403、缓存目录保留、冲突身份不发请求和实际中文提示。

两尺寸流程与云端原文导航回归见[原生去敏记录](validation-assets/2026-11-09/reader-context-runtime.json)。
更多书籍类型、服务端状态变化及实体 KO2 的网络、按键和休眠仍待验收。

## JSON 空字段

2026-11-10 复现 KOReader 的 LuaJSON 将 `null` 保留为特殊标记，而原先的下载校验把标记当作异常值。
相同合成页面在 Python 可通过、在实际 KOReader 解码器中会拒绝可选 token、pclts 和位置记录。
现仅将当前 JSON 解码器明确声明的空值标记按缺失处理；不会把任意函数或其他异常类型当作空值。

- 可选 token／pclts 的 `null` 不保留旧会话。
- 可选 currentChapter／progress 为 `null` 时使用空记录，位置记录中的空字段移除。
- 必需书籍编号和 psvts 的空值仍拒绝；明确的空 book 包装、异书编号和错误类型仍拒绝。
- 合法数值零保持原义，原有缓存和本机待同步位置保护不变。

新增 18 项 Lua 和 3 项 Python 检查；下载上下文累计 56 项 Lua／14 项 Python。
普通与 KO2 分辨率的实际 HTTP／JSON／原生界面回归均通过，覆盖可选会话、位置记录、
必需会话拒绝及已有错书／HTTP 403／缓存和待同步记录保护。
候选包、安装目录与源码逐字节核对见[固定字段记录](validation-assets/2026-11-10/reader-context-null.json)。

该空字段修复与真实整书验收分开判断。真实整书来源预检已有 30 个正文章节和 111 个图片引用，
完整插件运行仍观察到缺少书籍身份的阅读页；同一失败响应交给 Python 也未通过。
不能据上述合成回归宣称整书图片、真实同步或实体 KO2 已全部验收。
