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
真实云端写后回读、多设备、更多书籍类型及 KO2 实体按键／休眠／网络仍待验收；
完整功能验收后的性能优化阶段尚未开始。
