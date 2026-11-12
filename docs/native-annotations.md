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
授权变化丢弃旧结果，HTTP 429 或明确拒绝立即暂停，不消耗原有三次临时错误重试。
原生通道 HTTP 401 现可交由父进程最多续期一次，成功后只继续未保存批次；再次过期或续期未确认则暂停。
自动恢复失败时仍可从墨水屏授权设置检查后继续，未知回执不重放。

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
- 初次版本的 401／429 单次暂停；后续的 401 一次父进程恢复及 429 单次暂停见下节，授权变化不提交旧结果。
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
另有下述真实正文验收，首次发现的三处未匹配已修复，并在两尺寸及离线新进程核对。
更多格式、自动恢复分支的真实过期授权组合、云端批注写入及实体 KO2 仍待验收。
集中性能优化未开始。

```sh
python3 scripts/verify_native_annotations.py
python3 scripts/test_native_annotations.py
python3 scripts/verify_native_annotations.py --saved-session --all-batches --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/native_annotations_probe.lua /source
```

## 真实正文、想法弹窗与离线重开

新增 `scripts/verify_owner_annotations.py`，从本人当前续读的普通 XHTML 章节准备只读对照，
再沿插件首页／书架、详情「阅读」、章节下载与原生阅读进入划线章节选择。
文件管理器只用于创建插件宿主，未直接打开测试文件。
测试阶段的墨水屏授权由只读内存后端提供，正文及 SQLite 仅在已核对的临时内存文件系统中处理，
完整 Web 主流程仍使用生产 HTTP；没有账号数据写入或授权 POST。

首次验收中，该章 76 个划线范围、3 批共 180 条想法与 Python 对照的编号／引文／正文摘要一致。
当时 73 处成功匹配，3 处未匹配；全部已定位记录均逐项核对实际 DOM 选中文字，没有部分截断匹配。
点击真实覆盖区域打开的想法弹窗与 SQLite 内容一致。新进程从插件书架重开，
缓存来源与匹配数量相同，弹窗仍可用，Web 与墨水屏 HTTP 均为零。
恢复进入验收前的本机原文位置、关闭保存、子进程回收、凭据文件审计及临时目录删除均已核对，
前后云端位置不变，未生成私人截图，也没有人工目视私人正文。

未匹配诊断保留在固定字段中：两处使用的云端引文与原始范围文本不同，而原始范围文本可被原生搜索找到；
另有一处现用引文也能被原生搜索找到，但现有顺序／章节匹配未接纳。这里只记录现象，未放宽位置核验以制造通过。
当时工具将整体验收明确标为 `OWNER_NATIVE_ANNOTATIONS_PARTIAL`，返回非零状态。
历史结果及工具摘要保留在[首次证据](validation-assets/2026-11-10/owner-native-annotations.json)。

后续私有原文实验先用独立 Python HTML 解析器提取热度范围文字，再与 Lua 的原始 HTML Unicode 标量范围逐项比对，
这套单位与 Web 进度的过滤后 UTF-16 坐标分开。两处用实际打开文件的对应源文字即可找回，定位从 73 增至 75；
剩余一处的完整引文越过旧的最后一个词边界。用绑定当前章节的真实 DOM 文本末端核对后，76 处全部找回。

正式匹配现优先使用当前打开归档中、已核对书籍／章 UID／文件身份／原文与渲染哈希的源范围文字。
没有有效来源时保留原有引文；原文因脚注等转换不能完整匹配时仍可使用原有完整引文回退，
章节边界与重复文字的顺序规则保持。章末通过可见字符和文本节点末端求得，补齐最后标点，
并与已有原文位置模块共享同一实现。没有对应原生接口的旧运行环境保留原有兼容路径。

匹配器升至内部版本 4，旧版本的定位结果和中间检查点会重新投影；离线时也能完成，
云端原始划线、想法及 SQLite 内容不因重新定位改写。此内部版本不改变插件发布版本。
新增 13 项来源／回退／旧缓存与想法保留检查、8 项章末检查及 5 项独立 Python 原文模型检查。

官方 KOReader v2026.07.1 的 600×800 与 KO2 1264×1680 模拟尺寸均已通过修正后的正常插件流程：
76 处全部定位、零截断、180 条想法与对照一致；每条实际 DOM 选中文字及源范围文字一致，覆盖层点击弹窗通过。
两种尺寸分别排为 39／41 页，全新进程的离线重开、弹窗及位置恢复通过，Web 与墨水屏 HTTP 均为零。
前后云端位置不变，没有账号写入、授权 POST 或私人截图。完整匹配状态为 `OWNER_NATIVE_ANNOTATIONS_VERIFIED`。
见[修复后的证据](validation-assets/2026-11-10/owner-native-annotations-source-fix.json)。

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

## 下载任务内的一次父进程授权恢复

前台匹配与后台预下载均已复用现有 `native_read_recovery`／`native_renewal` 服务。
只有明确的原生 HTTP 401 可以触发一次恢复，正在读取的子进程不会续期。
父进程先保存待确认意图，再发送一次授权请求、读取同账号书架并保存新授权；
只有本次拥有的两次授权修订及相同账号、Web 会话和通道设置仍成立时，才继续下载。
服务忙碌、授权被替换、已有未确认意图、429、业务拒绝或再次过期不会开始第二次续期。

恢复建立新的读取任务，固定原生通道，关闭重复刷新／清空；先前完成的章节和想法批次继续使用。
后台任务仍要求两个预下载开关有效；续期期间关书、切换账号／阅读会话、暂停或关闭预下载会阻止继续。
取消时只终止本任务拥有的续期，不影响其他任务；已经发出的请求可能有结果不明的情况，意图保留，不重放。
保存新授权失败可从既有授权设置仅重试保存，随后再继续批次，不再次登录。
原文准备的进度提示统一为“正在准备划线原文”，离线定位不再显示为下载网络原文。

新增 36 项组件检查覆盖前台／后台、首个请求／中途批次、重复 401、拒绝、未知回执、保存失败、
取消、迟到回调、新任务、账号／会话／授权变化及关闭预下载。
实际 KOReader 的两种模拟尺寸使用隔离合成账号：31 个范围的前 30 个成功保存，第二批真实 HTTP 返回 401，
一次父进程续期后只重取该批次；前台与无界面预下载均通过。
持续 401 最多一次续期及一次再读，429 不续期；延迟授权请求中实际暂停后无迟到提交，后续读取不重放未确认续期。
故意取消所留下的待确认状态由一次新的合成扫码授权解除，不影响后续独立回归。

该轮真实账号复核在原生书架读取时观察到 HTTP 401，只读工具停止，账号数据写入及授权 POST 均为零。
当时保留了原项目钥匙串中的过期授权，尚未验证真实恢复；后续组合验收见下一节。
完整记录见[本轮恢复证据](validation-assets/2026-11-10/annotation-native-recovery.json)。

## 真实过期授权的组合验收

随后在官方 KOReader v2026.07.1 Linux ARM64／Xvfb 中，以同一份自然过期的本人授权，
从正常插件书架、详情「阅读」进入原生阅读器，再由实际标注选择器触发下载。
先运行禁止授权 POST 的检查：划线 GET 返回真实 HTTP 401，父进程尝试创建续期意图，
测试适配器在发送前阻止续期；授权请求为零，云端位置不变。

明确启用单次续期后，宿主先在原 macOS 钥匙串保存并回读待确认意图，
插件收到真实 401 后经生产父进程恢复服务仅发送一次原生 `/login`，
用响应中的新授权读取同账号书架，再恢复划线与三个想法批次。
600×800 下，76 处划线全部定位、零截断，180 条想法一致，实际覆盖层点击及弹窗通过；
全新进程离线重开、位置恢复、弹窗通过，Web／原生 HTTP 均为零。
宿主独立重新读取新授权书架、全部划线和想法，核对账号、范围、数量、内容摘要和来源文字摘要，
并实际将新授权写回原钥匙串、回读一致后解除本次待确认状态。
前后云端阅读位置不变，没有书架、笔记、进度或阅读时长写入，没有私人截图。

该专用入口与原只读入口分开：`--saved-session` 单独使用只做上述发送前检查，
额外的 `--renew-in-parent` 才允许一次授权 POST；只读入口仍拒绝所有登录／续期。
传输范围限定同书同章、固定请求体、无 Cookie／Bearer 混用；授权请求发送前即消耗唯一名额。
原生临时配置使用 RAM 凭据存储适配器，真实持久化及回读发生在原 macOS 钥匙串；
因此本项不替代 Kindle 上凭据文件落盘／休眠恢复验收。
若回执缺失或结果不明，宿主持久意图保留，不自动重新发送。
新授权一经独立确认便保存，即使后续界面或内容核对失败，也不会丢弃已轮换授权后重登。

由于旧授权已失效，在线阶段无法预先取得原生对照模型，两个对照标记保持未核对状态；
只有宿主在真实续期完成后独立读取并比对模型，最终报告才标记通过。
离线阶段严格核对该已独立验证的模型，没有把插件自己的下载结果当作独立对照。

可复现入口（默认不读钥匙串、不联网）：

```sh
python3 scripts/verify_owner_recovery.py
python3 scripts/test_owner_recovery.py
```

已有授权、自然过期样本及候选包时，明确执行一次恢复：

```sh
python3 scripts/verify_owner_recovery.py --saved-session --renew-in-parent --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  python3 /source/scripts/run_owner_reading_probe.py \
  --koreader /validation/runtime/lib/koreader --candidate /validation/owner-parent-recovery-candidate.zip \
  --annotation-recovery
```

移除 `--renew-in-parent` 即为禁止授权 POST 的真实过期检查。
新工具增加 9 项 Python 检查和 20 项 Lua 传输边界检查，覆盖默认离线、显式选择、
私有回执、一次发送上限、未知结果保留、确认零发送才释放、独立模型、同账号保存与离线零请求。
完整结果及共享只读流程的 KO2 分辨率回归见[真实恢复证据](validation-assets/2026-11-10/owner-parent-annotation-recovery.json)。
真实中途想法批次过期、更多书籍类型及 KO2 实体设备仍待验收；中途恢复现有合成服务覆盖。
