# 同步响应的同书校验与重新核对

修复普通书籍同步中一组可复现的数据校验缺口：旧解析会深入标注其他书籍的外层响应，
并接受互相矛盾的 `bookId`／`book_id`；超出范围的百分比会截为 0／100，
无效章内偏移或章节序号可能被当成零。多份候选进度还可能依赖 Lua 遍历顺序选中其中一份。
这些均由合成数据复现，不表示实际服务已返回过这些坏响应。

`scripts/verify_reader_progress.py` 先建立 Python 投影并核对 8 本真实书籍的只读响应，
再实现 `weread/lib/remote_progress.lua` 并由 `PositionMapper.normalize_remote` 统一调用。
Python／Lua 在同一批真实响应与 70 组有效／异常样本上的结果一致，响应只在私有管道内比较。

## 校验规则

- 从响应外层到候选进度节点逐级检查书籍编号。任一层显式属于其他书籍，整条分支不再向下搜索；
  两种编号同时存在时都必须匹配当前请求。其他书籍的独立兄弟分支不会污染唯一的有效结果。
- 必须只有一个有效候选。多个候选不按遍历顺序猜测；上层明确失败的响应不使用附带的旧进度。
- 百分比必须是 0—100 的有限数值；章内偏移、章节序号、更新时间必须是有界的非负整数。
  保留十进制数值字符串兼容，拒绝十六进制、分隔符及其他文字。别名字段同时存在时须一致。
- 章节编号必须是有界标识，摘要必须是有界文字。缺失的可选字段沿用默认值，
  显式提供却损坏的字段不能降级成零。合法零偏移与未提供偏移继续区分。
- 深度最多七层、检查最多 512 个容器；循环、过深或过大的响应拒绝使用。
  只有阅读时长但没有位置的书籍不凭空生成 0% 的云端位置。

本项保持已有目录字数／百分比映射与上传协议，不授予原文坐标上传验证，
也不证明目录版本或所有章节编号／服务器坐标的语义。Web 与 Gateway 仍各自校验：
一个来源损坏而另一个来源有效时，可使用有效来源完成比较；两者都不能核实时保留本机位置。
真实新投影验证覆盖 Web 响应；Gateway 路径本轮使用合成 HTTP 验证。

## 重新核对期间的同步状态

新一轮云端比较会立即撤销当前书籍的旧同步确认，取消尚未发送的同书排队上传及忙碌重试。
本机待同步记录保留，已确认的历史回执不被改写，其他书籍的独立任务不受这项取消影响。
比较失败后，阅读时长上报通过原有位置提供器得到“未核对”状态，不能沿用旧确认继续发送。
已经发出的请求不属于“尚未发送”的取消范围，本项不声称能撤销服务端已处理的写入。

新字段校验错误使用中文原生提示，说明本机位置已保留、可以稍后重新同步。
错误的响应不会自动导航、清除本机待同步位置，或触发一次新的进度写入。

阅读时长上下文的远端合并也复用本校验。可选字段缺失时保留新鲜 Reader 上下文，
明确零值和空摘要仍可合并；校验器的字段提供标记与原有结果对象分开返回。
新增回归与两尺寸实际入口验证见[后续记录](validation-2026-11-10.md)。

## 验证入口

```sh
luajit spec/remote_progress_spec.lua
luajit spec/progress_sync_spec.lua
python3 scripts/test_reader_progress.py
```

默认离线，不读取授权或联网：

```sh
python3 scripts/verify_reader_progress.py
```

已有本人开发授权时可明确复用；私密书籍、响应、摘要和位置不进入报告：

```sh
python3 scripts/verify_reader_progress.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation \
  ./luajit /source/spec/koreader/reader_progress_probe.lua /source
```

原生测试沿插件选书与下载流程进行，在实际阅读器中依次注入六类 HTTP 200 异常响应，
检查原生位置、待同步记录、中文提示、上报门槛和零写入，再恢复正常响应执行原有模拟同步回读。
随后由新进程进行离线恢复、断网移动与重连选择；这些流程没有真实账号写入。

```sh
xvfb-run -a python3 scripts/test_discovery_runtime.py --reading-flow \
  --offline-progress --progress-response --koreader /path/to/runtime \
  --run-dir /path/to/new-profile
```

固定字段证据见[运行报告](validation-assets/2026-11-09/reader-progress-validation.json)。
两种尺寸的中文原生提示已目视核对：[600×800](validation-assets/2026-11-09/reader-progress-rejected-600.png)、
[KO2 尺寸](validation-assets/2026-11-09/reader-progress-rejected-ko2.png)，截图仅含合成书籍与正文。
后续本人授权的一次 Python 同章一字前进实验已通过写后回读与原位置恢复，
Lua 四种真实上下文载荷仅作零 HTTP 的逐字段比较，见[实验说明](position-roundtrip-validation.md)。
实际插件云端写后回读、多设备、更多书籍类型及 KO2 实体按键／休眠／网络仍待验收；
完整功能验收后的性能优化阶段尚未开始。

## 上传后的章节坐标回读确认

位置上传现与周期性时长上报的重试流程分开：一个位置任务最多发送一次进度上报，
新阅读会话可先发送一次进入阅读请求；两者都需要 HTTP 200 和明确成功回执。
进入阅读未确认即停止，不继续上报；进度回执为空、矛盾、拒绝或传输结果不明时，
不刷新会话后重新 POST、不续期后重发，也不把同位置保持不变当作写入成功。
单独的 `synckey` 不替代本轮已验证的明确成功字段。
真正尚未取得时长任务执行权的忙碌状态继续使用原来的排队机制，尚未发送的任务不算重发。

收到成功回执后，用 Web 进度 GET 单独读取当前书籍，按章节 UID、章节序号和章内偏移逐项精确比较。
必须显式包含三个字段，缺失字段不能补零；异常数值、外层失败、异书或矛盾别名仍由严格投影拒绝。
服务端百分比单独记录，不以目录字数重算值或百分比容差代替坐标核对，也不声称恢复／统一其元数据口径。
首次立即读取，尚未一致时最多再以一秒间隔调度两次 GET；回执只属于原任务及授权，不能用于其他账号、
替换授权或新的上传。等待期间不能启动同书周期性时长上报，账号变化、休眠、断网、重新比较或新的云端来源导航／文件交接
会使旧确认失效。结果不明只保留位置并显示中文提示，不自动重新发送该位置。

仅明确回执和回读均通过，才保存本次上传记录；清除待上传记录使用精确坐标及绑定的本机来源信息，
不会因原先一字／百分比容差清掉等待期间产生的新位置。未确认原因与本机待上传位置一起保存，
刷新、关书或之后的新移动均不会抹掉这个状态。新进程下一次比较若坐标完全一致，可只读解除待同步状态，
不追认旧任务为上传成功；若仍只在原百分比容差内、坐标相邻或字段缺失，仍要求明确选择，不自动覆盖。
原文 `upload_verified=false` 保持，嵌套的本机原文快照不会进入既有进度载荷；直接上传只读来源坐标会在发送前拒绝。
位置上报和回读的错误诊断仅记录固定阶段／状态，不输出私密正文、位置响应或凭据。

Python 原型先在真实账号进行只读核对，八次有界进度读取中有一份包含完整章节坐标，
该样本与相邻偏移／不同章节序号的三个比较由 Python 和生产 Lua 逐项核对一致。
这没有真实进度 POST，也不把读取成功当作写入验收。

新增 121 项组件检查和 52 项控制器回归，覆盖延迟确认、三次上限、回执不明不重发、
授权替换、私有诊断、等待时翻页、相邻待同步位置保留、休眠／重新核对取消及重开后的未确认状态。
仅原文位置资料在后台准备完成、页面未移动时，不会把只读元数据变化当作新上传意图。
8 项 Python 检查与两项合成 HTTP 合同检查已纳入 CI。
官方 KOReader v2026.07.1 的 600×800 和 KO2 1264×1680 模拟尺寸均从插件首页／书架／书城选书、
实际下载和原生阅读进入同步，再通过原生冲突选择保留本机位置。
合成服务的延迟生效、永久不同、缺失回执三个场景各只发送一次位置上报；分别读取三次、三次、零次，
中文未确认提示、实际 SQLite 状态、显式重新核对、全新进程离线重开及离线移动／重连选择通过。
没有真实账号写入、授权 POST 或自动 POST 重试。两尺寸截图仅含合成正文，已目视检查提示。

结果及候选包核对见[固定字段证据](validation-assets/2026-11-10/progress-upload-confirmation.json)。
合成数据提示：[600×800](validation-assets/2026-11-10/progress-upload-unconfirmed-600.png)、
[KO2 分辨率](validation-assets/2026-11-10/progress-upload-unconfirmed-ko2.png)。
真实插件写后回读仍待新的限定实验；前一次四请求授权已使用，未在本轮重复写入。
本项不证明原文坐标单位、通用精确上传、多设备、时长补传或 KO2 实体设备验收。

```sh
python3 scripts/verify_progress_readback.py
python3 scripts/test_progress_readback.py
luajit spec/progress_confirmation_spec.lua
```

显式使用已保留的本人授权，只读核对 Python／Lua 模型：

```sh
python3 scripts/verify_progress_readback.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation \
  ./luajit /source/spec/koreader/progress_readback_probe.lua /source
```

合成服务的完整原生流程：

```sh
xvfb-run -a python3 scripts/test_discovery_runtime.py --reading-flow --offline-progress \
  --progress-response --progress-confirmation --koreader /path/to/runtime --run-dir /path/to/new-profile
```
