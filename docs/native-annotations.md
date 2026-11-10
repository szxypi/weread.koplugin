# 墨水屏授权的章节划线与想法读取

正常微信书籍阅读中的「划线和想法管理」现在可复用已保存的墨水屏授权，
不再强制要求额外的 WeRead Skill 密钥。正文仍由 KOReader 原生引擎排版，
划线使用现有覆盖层，点击后显示原生想法弹窗。
入口为阅读器微信读书菜单 → 划线和想法管理 → 选择章节匹配／继续匹配。

本项读取章节的划线热度及所选划线范围下的想法，不是创建个人笔记或上传本机批注。
云端新增／修改／删除批注仍未接入。

## 协议先验证，随后接入

参考迁移来源 `miuread/eink_client.lua` 的 `underlines()`／`readreviews()`，
固定提交为 `c1893562aa25a870b8dd076d7be062a3348f823e`，
Copyright (C) 2026 MiuRead contributors，AGPL-3.0-only。
先新增默认离线的 `scripts/verify_native_annotations.py`，真实响应通过后才实现 Lua。

本人账号的一本普通书籍／一章返回 124 处划线；首批 30 个范围返回 96 条想法。
Python 与 Lua 对同一响应的投影一致，插件实际 HTTPS 独立读取也一致。
使用 stock LuaJSON 传输比对结果时，显示热度 `score` 经 LuaJIT `tostring` 舍入为 14 位有效数字；
验收工具仅允许该字段的这一精确舍入，编号、范围、计数、引文与想法正文仍逐项严格比较。
其他浮点差异、布尔值／数值混淆及超出整数精度的编号不会因此通过。

两个读取合同为：

- `GET /book/underlines`：固定同书、同章、`synckey=0`。
- `POST /book/readreviews`：固定同书、同章、`cht2sMode=""`，每批最多 30 个已核对范围，
  每个范围 `maxIdx=0`、`count=30`、`synckey=0`。

本轮明确遇到一次墨水屏授权 HTTP 401，随后独立运行既有续期工具，
只发一次续期 POST，同账号 139 本书架及原钥匙串条目回读通过。
后续划线／想法读取本身没有登录续期 POST，也没有账号数据写入。
真实编号、引文、想法与凭据只经捕获的内存管道处理；公开报告不含这些值。
开发授权继续保留在原有两个项目钥匙串条目，直到整体目标完成。

## 下载、恢复与通道隔离

已核对的墨水屏授权优先读取普通书籍；没有墨水屏授权时保留已有 Skill 通道。
首次划线读取尚未产生有效数据时，401／403、临时服务或连接错误可使用已配置的 Skill 密钥，
随后整个任务固定到该通道。受限、业务拒绝、错误身份和损坏数据不能触发回退。
已经选择墨水屏通道的任务不会在后续想法批次中切换为 Skill。

任务固定账号、Web 授权代次、墨水屏授权修订及密钥状态，发送前与接收后均检查。
子进程结果返回父进程后再次核对，再允许 SQLite 检查点推进。
授权变化丢弃旧结果，HTTP 401／429 或明确拒绝立即暂停，不消耗原有三次临时错误重试。
当前 401 提示用户从微信读书设置续期后继续；任务内的父进程自动续期仍待接入。

新检查点记录 `native`／`gateway` 通道。暂停后只请求剩余批次，已保存的 Skill 批次在密钥可用时
继续使用 Skill；没有原通道时保留检查点并提示重新获取所选章节，不混合来源。
完整章节、想法弹窗数据和已有定位继续复用现有共享数据库；离线匹配不发请求。
自动预下载也使用该读取通道，仍要求两个预下载开关同时开启并在子进程执行。

## 真实 KOReader 验收范围

官方 KOReader v2026.07.1 Linux ARM64／Xvfb，600×800／167 DPI 和
KO2 1264×1680／300 DPI，安装后的候选插件通过：

- 无额外密钥，从实际章节选择窗口获取数据，子进程 HTTP、原生正文匹配、SQLite 提交及划线显示。
- 点击实际划线区域打开中文想法弹窗，长文本正常分页。
- 延迟的真实本地 HTTP 请求可暂停，检查点保留，迟到结果不提交，继续时只读剩余想法批次。
- 401／429 各只读一次，提示可读且无内部错误标识；授权文件在请求期间变化时不提交旧结果。
- 完整缓存离线匹配不发 HTTP；本场景没有 Gateway 请求、阅读进度写入或续期 POST。

这些界面场景全部使用合成账号与正文，截图已目视核对：
[600 划线](validation-assets/2026-11-10/native-annotations-overlay-600.png)、
[KO2 想法](validation-assets/2026-11-10/native-annotations-thought-ko2.png)、
[600 授权失效提示](validation-assets/2026-11-10/native-annotations-expired-600.png)、
[KO2 受限提示](validation-assets/2026-11-10/native-annotations-limited-ko2.png)。

两个完整核心回归同时通过下载、书架／书城／资料／统计、原文位置及打包阅读。
两份候选各 187 个生产文件与当前源码及安装目录逐字节一致，ZIP CRC 通过，零重绘错误。
159 组 Lua、477 项 Python、420 个静态文件零警告／错误，422 个 Lua 语法文件、
命名空间、四时区及 Python 编译通过。协议、运行范围和独立续期见[固定字段结果](validation-assets/2026-11-10/native-annotations.json)。

真实账号目前只核对一章划线和首批想法的模型／HTTPS；整章全部批次的真实原文匹配、
更多格式、任务内自动续期、云端批注写入及实体 KO2 仍待验收。集中性能优化未开始。

```sh
python3 scripts/verify_native_annotations.py
python3 scripts/test_native_annotations.py
python3 scripts/verify_native_annotations.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/native_annotations_probe.lua /source
```
