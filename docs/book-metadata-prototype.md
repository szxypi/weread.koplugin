# 原生书籍详情与后台资料读取

## 界面与数据来源

书籍详情使用 KOReader 的标题栏、文字、滚动容器和按钮绘制；首页、书架和书城也采用原生控件。
正文交给 KOReader 的 EPUB 引擎排版。这里的 Web 指数据来源；插件不加载网页界面，也不执行网页 JavaScript。
简介中的 HTML 标签和实体转换为原生文字，保留段落以及 `2 < 3, 5 > 4` 等普通文本。

已配置密钥时，资料优先使用官方 `/book/info`；没有密钥或查询失败时，
使用已经验证的 Web Reader GET，从 JSON 初始状态提取 `reader.bookInfo`。
后台进程只传回书名、作者／译者、简介、出版社、ISBN、分类、出版时间、封面及可用的字数／评分字段。
响应上限 4 MiB，简介上限 64 KiB，后台返回管道上限 256 KiB。
实际读取通过 `Client` 的证书链和 SAN 域名校验，固定原站与书籍，错误内容不进入诊断。

这条资料读取不应用 ReaderState，不请求云端进度；原始页面中的位置、会话参数和书籍版本不进入资料投影。
在内存中捕获的登录凭据只用于此请求，不保存响应 Cookie。
后台及主进程均检查账号和凭据修订；关闭、取消或过期页面不会覆盖缓存或重新打开详情。
旧页面的刷新回调不会取消新的请求。

## 缓存与本机阅读状态

首次从书架进入缺少资料的书籍会后台获取资料；有缓存时直接显示，仍可点击“获取最新信息”手动刷新。
离线保留已有资料；失败显示缓存；加载提示支持取消，网络与页面解析不在 UI 事件循环运行。

旧逻辑刷新详情时还读取云端进度并覆盖本机位置，本次已移除该行为。
现在完成请求后重新读取最新的本机书籍记录，仅合并经过白名单校验的展示字段。
读取期间发生的翻页、下载、待上传位置、文件路径、EPUB 版本等保留当前值，
资料缓存继续写入账号独立 SQLite 和原有 per-book 存储，不扩大全局设置中的集合数据。

## 只读原型和实际账号

`scripts/verify_book_metadata.py` 默认离线，不访问钥匙串或网络。
显式复用保存的会话后，先核对账号，再最多抽取 4 本现有书架书籍（默认 2 本）。
资料、书籍 ID 和凭据仅在内存中处理；报告只包含数量、字段名和固定状态。
服务端更新的已核对 Cookie 会先保存到用户授权的项目钥匙串，再执行可选对照。
凭证保留至整体目标验收收尾。

```sh
python3 scripts/verify_book_metadata.py
python3 scripts/verify_book_metadata.py --saved-session
# --lua-command 必须最后；路径对应本项目验证容器。
python3 scripts/verify_book_metadata.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/book_metadata_probe.lua /source
```

[真实账号去敏结果](validation-assets/2026-11-09/book-metadata-owner-readonly.json)：
139 本书架中抽取 2 本，简介、出版信息、评分等可用字段的 Python、Lua 模型及原生 HTTPS 投影全部一致；
原生只发送 2 个固定 Reader GET，没有账号数据写入。
这 2 本的 Reader 数据没有返回字数；没有推导或虚构该字段。
Web Reader 资料属于回退入口；直接 E-Ink 资料接口、更多书籍类型、真实过期和实体 KO2 仍待验证。
性能专项测量安排在全部功能开发和测试完成之后，目前不声称已经测得真机性能提升。

## 原生控件验收

打包插件在官方 KOReader v2026.07.1 ARM64／Ubuntu／Xvfb 的 600×800 和 KO2 尺寸 1264×1680／300 DPI 通过：

- 实际后台进程、管道、HTTP、SQLite、原生详情控件和简介文字绘制。
- 网络请求等待期间 UI 心跳继续执行；官方查询失败后一次 Web 回退；资料可离线重开。
- 请求中本机进度从 83 更新为 84 后，完成时保留 84；章号、待上传 83、原文件版本 47 保持不变。
- 403 保留缓存；关闭加载提示终止子进程；Cookie 变化或过期回调不提交资料。
- 全链路没有因详情刷新新增进度查询或写入；同时回归实际下载、单章／整书 EPUB 和阅读器。

截图为合成书籍：[600×800 原生详情](validation-assets/2026-11-09/book-metadata-600.png)、
[KO2 尺寸原生详情](validation-assets/2026-11-09/book-metadata-ko2.png)。
