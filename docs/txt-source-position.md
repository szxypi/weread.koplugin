# TXT 原文位置与原生阅读

TXT 现在可复用插件已有的本地「检查阅读位置」、后台来源核验、原文目标准备及原生跳转链路。
它使用独立的 `raw_txt_utf16` 本地坐标，XHTML 继续使用 `filtered_xhtml_utf16`。
两者均为 `upload_verified=false`；TXT 云端偏移语义尚未确认，云端原文适配仍只接受 XHTML。

## 坐标和来源

TXT 原始字节在下载时已保留于来源凭据中。本次增加纯文本坐标模型：标签和实体字样按原文字符处理，
不经过 HTML 解析；BOM、原始 CRLF、空白行和尾空格保留 UTF-16 长度，匹配时仅忽略显示空白。
中文、非 BMP 字符、字面标签、实体字母及其边界均需精确对应，不允许把代理项中间当作位置。
重复的短上下文、无效 UTF-8、XML 控制字符、超限章节和不能往返核对的位置均拒绝猜测。

来源格式由已核验的 EPUB 来源记录决定。工作进程、当前页面结果、反向锚点、原生跳转和目标保留
都检查坐标类型与来源格式一致；即使书／章／哈希相同，也不允许互换 TXT 和 XHTML 坐标。
归档核验继续使用独立文件描述符，原生文档调用仍留在阅读器进程；账号、文件或页面变化会取消旧任务。
现有同步进度保留原有单位，精确位置作为独立本地信息附带；本地跳转不会批准云端写入。

## 验证入口

Python 的纯文本模型位于 `scripts/txt_coordinates.py`，先在真实 TXT 响应核对，随后才接入 Lua。
同一真实正文的 Python／Lua 正向查询、九个标量点和反向锚点已比对一致，原文只经过捕获的内存管道。
默认不联网的读取工具可显式执行只读比对：

```sh
python3 scripts/verify_txt_reading.py --saved-session --coordinates --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation \
  ./luajit /source/spec/koreader/source_coordinate_probe.lua /source
```

真实账号验收沿插件书架、详情「阅读」、实际下载和原生阅读执行。
Python 原文哈希和唯一样本偏移必须与打包插件解码后的来源及实际 CRE 字符位置一致，
再验证正文页后台采集、位置提示、原生往返跳转和现有同步单位未变。
关闭并以全新离线进程从插件重开后，重复这些检查；凭据、书名、原文和位置不进入公开报告。
运行方式见[正常阅读验收](owner-native-reading.md)，TXT 使用 `--book-format txt`。

合成原生生命周期检查可使用：

```sh
xvfb-run -a python3 scripts/test_position_runtime.py --probe source-state \
  --source-format web_txt --koreader /absolute/path/to/koreader \
  --run-dir /absolute/path/to/new-txt-source-run
```

该入口使用隔离合成账号与两章正文，包含 BOM、CRLF、空白行、尾空格、字面标签／实体及表情。
它检查正文页、滚动、字号重排、账号变化、休眠回调、低内存延后、旧任务取消、同路径文件替换和切书。
KO2 分辨率增加 `--width 1264 --height 1680 --dpi 300`。表情参与文本坐标核对，现有字体的字形回退不在本次修复范围内。

这些结果不证明 TXT 的服务端进度单位、精确上传入账、多设备协调、全部书籍类型或实体 KO2 行为。
集中性能优化仍待功能及相应环境验收完成后进行。

## 本轮结果

2026-11-10 已完成 TXT／EPUB 各两尺寸的真实插件阅读及全新离线重开，共八个串行原生进程；
另完成两格式各两尺寸的合成生命周期验收。前者每种格式为一本／一章，关闭账号写入，
前后云端位置一致；后者覆盖两章长正文与上述取消／重排／替换边界。
所有四份合成运行无重绘错误，五份候选各 184 个生产文件与源码逐字节一致，ZIP CRC 通过。

156 组 Lua、432 项 Python、411 个文件静态检查零警告／错误、413 个 Lua 语法及四时区检查通过。
见[固定字段结果](validation-assets/2026-11-10/txt-source-position.json)，
以及合成数据的[普通尺寸提示](validation-assets/2026-11-10/txt-source-position-600.png)、
[KO2 分辨率提示](validation-assets/2026-11-10/txt-source-position-ko2.png)。两张提示截图已目视核对。
当前未发现已连接的 Kindle USB 设备或挂载目录，实体 KO2 尚不可验收。

2026-11-12 新增[云端位置只读预检](txt-cloud-position-preflight.md)：真实当前点与规范化摘要起点一致，但原摘要为 30 个标量，
当前 20 标量编码器不能保证完整恢复，上传门槛保持关闭；未进行位置写入，完整摘要协议和实际往返仍待验证。
