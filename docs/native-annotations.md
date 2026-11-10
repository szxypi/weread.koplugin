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

真实账号后续已核对同章全部 124 个范围：5 批共 340 条想法，Python／Lua 同响应模型与插件 HTTPS 一致。
每个范围均返回明确的无后续页标记，`totalCount` 与实际条数一致；全部范围恰好请求一次。
验证工具新增 `--all-batches`，每批之间间隔一秒，并限制私有响应总量；不自动请求范围内后续页。
该样本没有后续页，不证明存在后续页时已支持完整分页，见[独立结果](validation-assets/2026-11-10/native-annotations-all-ranges.json)。
另有下述真实正文验收，仍存在未匹配范围。更多格式、任务内自动续期、云端批注写入及实体 KO2 仍待验收。
集中性能优化未开始。

```sh
python3 scripts/verify_native_annotations.py
python3 scripts/test_native_annotations.py
python3 scripts/verify_native_annotations.py --saved-session --all-batches --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/native_annotations_probe.lua /source
```

## 真实正文、想法弹窗与离线重开：仍有未匹配范围

新增 `scripts/verify_owner_annotations.py`，从本人当前续读的普通 XHTML 章节准备只读对照，
再沿插件首页／书架、详情「阅读」、章节下载与原生阅读进入划线章节选择。
文件管理器只用于创建插件宿主，未直接打开测试文件。
测试阶段的墨水屏授权由只读内存后端提供，正文及 SQLite 仅在已核对的临时内存文件系统中处理，
完整 Web 主流程仍使用生产 HTTP；没有账号数据写入或授权 POST。

该章 76 个划线范围、3 批共 180 条想法与 Python 对照的编号／引文／正文摘要一致。
73 处成功匹配，3 处未匹配；全部已定位记录均逐项核对实际 DOM 选中文字，没有部分截断匹配。
点击真实覆盖区域打开的想法弹窗与 SQLite 内容一致。新进程从插件书架重开，
缓存来源与匹配数量相同，弹窗仍可用，Web 与墨水屏 HTTP 均为零。
恢复进入验收前的本机原文位置、关闭保存、子进程回收、凭据文件审计及临时目录删除均已核对，
前后云端位置不变，未生成私人截图，也没有人工目视私人正文。

未匹配诊断保留在固定字段中：两处使用的云端引文与原始范围文本不同，而原始范围文本可被原生搜索找到；
另有一处现用引文也能被原生搜索找到，但现有顺序／章节匹配未接纳。这里只记录现象，未放宽位置核验以制造通过。
工具将整体验收明确标为 `OWNER_NATIVE_ANNOTATIONS_PARTIAL`，返回非零状态，整章完整匹配仍待修复。
两种模拟尺寸的结果与代码摘要见[固定字段证据](validation-assets/2026-11-10/owner-native-annotations.json)。

默认运行不读取授权、不联网：

```sh
python3 scripts/verify_owner_annotations.py
python3 scripts/test_owner_annotations.py
```

明确复用本人开发授权时：

```sh
python3 scripts/verify_owner_annotations.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  python3 /source/scripts/run_owner_reading_probe.py \
  --koreader /validation/runtime/lib/koreader --candidate /validation/owner-annotations-candidate.zip \
  --annotations
```

该入口固定当前书籍与章节，只允许一次划线 GET 和恰好覆盖已预览范围的想法批次，
拒绝重复、异书／异章、授权混用、登录／续期及写入路径。11 项离线 Python 检查与 21 项 Lua 传输边界检查
覆盖默认离线、严格公开字段、真实文本的私有摘要、缺页拒绝、离线零请求、未匹配不通过及错误诊断脱敏。
