# 原生“我的”与阅读统计

“我的”、月历、阅读目标及周／月／年／总计统计使用 KOReader Lua 原生控件。
有同账号墨水屏授权即可读取，不再要求 Skill 密钥；正文仍由原生 EPUB 引擎渲染。
没有加载网页界面或执行网页 JavaScript。

## 真实协议与字段核对

参考 MiuRead 的 `miuread/eink_client.lua` 中 `reading_stats`（AGPL-3.0-only，见 NOTICE），
先以 `scripts/verify_native_statistics.py` 验证真实返回，再实现 Lua。
请求固定为墨水屏域名的 `GET /readdata/detail`，仅允许 `mode` 与 `baseTime`：

| 参数 | 规则 |
| --- | --- |
| `mode` | `weekly`、`monthly`、`annually`、`overall` |
| `baseTime` | `0` 表示当前周期；历史周期使用北京时间自然周／月／年起点的整数秒 |
| 授权 | 当前 Web 登录账号绑定的墨水屏授权头；不附加 Web Cookie 或 Skill 密钥 |

[真实去敏报告](validation-assets/2026-11-09/native-statistics-owner-readonly.json)覆盖四种当前周期及上月，
先用 Python 发出五个只读 GET，再比较相同响应的 Lua 投影，最后由 KOReader HTTPS 独立发出五个 GET。
投影字段、数组及数值全部一致；JSON 浮点序列化仅接受绝对误差 `1e-9`，不放宽整秒差异。
周空数据、月逐日、年逐月、总计逐年的返回均已核对，历史月份也通过周期检查。

真实结果中，`overall.totalReadTime` 与逐年柱状图合计不同，历史月的 `readDays` 也与正时长桶的个数不同。
因此保留服务端汇总时长／阅读天数，图表使用对应桶，不用图表重新计算并覆盖汇总。
连续阅读则根据已取得的逐日桶计算；缺少前月时最多回溯 24 个月，并明确保留下界含义。
年度响应另带 `dailyReadTimes`，当前年度图表不使用它，故不缓存该冗余字段。

`statistics_data.lua` 只保留有界展示字段：周期、秒数、天数、趋势、读书排行和阅读偏好。
必须存在合法汇总时长／整数天数；逐日／月／年桶检查秒与毫秒、对齐、范围和冲突，
拒绝跨周期响应、非有限值、过大集合或业务拒绝，不把错误响应显示为零阅读。
丢弃账号、书籍 ID、会话、凭据及不用于展示的原始字段。

## 后台读取、离线与取消

- “我的”与详细统计分别使用可取消的内存管道工作进程，网络和响应投影不阻塞界面。
  详细统计响应／结果限制为 4 MiB，“我的”只返回月快照和时间等必要字段。
  多月快照首个成功来源绑定后，其余月份必须使用相同通道；失败不会提交半份快照。
- 优先墨水屏授权；未授权时可使用已有 Skill 密钥。已登录但两者都没有时打开授权入口，
  手动操作遇到无效登录时引导扫码；自动刷新不主动弹出扫码。
- 原生 HTTP 401 最多复用一次持久化续期；成功后重新读取完整快照或原统计周期。
  续期失败且存在 Skill 密钥时重新取得整个快照，不能拼接不同来源的月份。
  后续 401 不循环；429、业务拒绝和无效响应不触发续期或其他通道请求。
- 仅父进程检查账号、登录代次、授权修订、页面与请求身份后显示／保存。
  关闭、取消、账号变化、重新授权、关书与休眠会终止自有工作进程和自有续期任务。
  旧回调不能关闭新等待窗、重新打开页面或写入缓存。
- 统计缓存在当前账号 SQLite 内，详细统计按 `reading-statistics:<mode>:<北京时间周期起点>` 隔离。
  离线或读取失败时只打开该周期的合法缓存，并标注“已缓存”；没有缓存时保留当前页面。
  当前月缓存不能冒充上月、周或年度数据。保存失败时可显示刚读取的统计，并提示无法离线保存。
- 每日目标为本插件当前账号的本地设置，不修改微信读书目标、书架、阅读进度或阅读时长。

## 真实账号页面与文件缓存验收（2026-11-10）

在官方 KOReader v2026.07.1 Linux ARM64／Xvfb 中，通过实际 FileManager 的 PluginLoader
加载候选插件，分别验证 600×800／167 DPI 与 1264×1680／300 DPI。后者只是 KO2 分辨率模拟。
每种尺寸先由 Python 独立读取六份周期响应并投影，再由插件正常后台子进程发出七次统计 GET。
实际打开“我的”、月历、月统计、上月、返回当月、周、年及总计；每个进程核对七个视图的展示字段、
原生根容器尺寸和实际重绘。时长汇总、阅读天数、逐日桶、连续阅读、排名、偏好及导航与独立模型一致。
账号昵称使用空值，不属于真实昵称显示验收；没有截取私人统计页面或进行人工视觉检查。

实际按钮将临时本地目标设为 45 分钟，账号 SQLite 回读通过，不修改微信读书的目标。
缓存是私有 tmpfs 上的普通 SQLite 文件，另一个账号读不到当前月快照或目标。
关闭后用独立的新进程以离线状态重新打开上述页面，读取最后保存的对应周期快照，网络请求为零。
在线进程采用 America/New_York，离线进程采用 Pacific/Apia，周期仍按北京时间核对。
自有工作进程全部回收；凭据通过匿名内存文件交接，文件审计未发现访问／刷新凭据或设备标识。
归档候选的 201 个生产文件与源码逐字节一致，ZIP CRC 通过；临时目录删除后没有再测安装目录字节。
此前六份其他原生场景的安装字节证据独立保留，不将它借作本场景的安装后测量。

最终两尺寸合计 26 次只读 GET，28 个已校验视图；此前六视图版两尺寸另有 24 次 GET。
本项累计 50 次统计 GET，数据及授权 POST 均为零。私有统计投影仅短暂存在于进程和 tmpfs，
报告不含日期、时长、书名、账号或凭据，结束时临时资料目录全部删除，原钥匙串登录条目继续保留。
真实账号只需回溯一个月；24 个月上限、重叠查询 30 次上限和返回当月的缓存替换另由合成服务验证，
没有把这些边界称为真实账号已覆盖。新增 16 项离线边界检查加入 CI。

去敏元数据、请求数量和代码哈希见[页面与离线证据](validation-assets/2026-11-10/owner-statistics-file-ui.json)。
完整真实账号 UI 的失效续期组合、更多连续阅读边界及实体 KO2 仍待验收。

## 开发授权失效与保存续期

本轮先在 KOReader 原生 HTTPS 中观察到真实统计 GET 返回 **HTTP 401**。
随后 `scripts/renew_saved_native_session.py` 将待确认标记保存到原开发钥匙串条目并回读，
仅发送一次 Python `/login` 续期 POST，同账号 139 本书架回读后提交新授权，再完成上述统计复核。
服务端访问凭据发生变化，未返回刷新凭据，保留旧刷新凭据。
[去敏续期报告](validation-assets/2026-11-09/native-saved-renewal-after-401.json)只有固定断言、字段名与数量。
HTTP 401 证明该授权失效；没有证据区分自然到期与其他服务端失效原因。

开发助手对原钥匙串条目写入持久待确认标记，不新增凭据文件或第三个钥匙串条目。
空的本机锁文件序列化项目写入，防止两个进程重复发出续期。
可能发出而回执未知时保留待确认状态，后续加载拒绝重放；只有明确未发送才释放标记。
外部替换、账号不符或未完成书架验证均不能提交。明确重新扫码可保存新授权。

真实授权失效 GET 使用 Lua，真实续期 POST 使用 Python，续期后的统计 GET 再使用 Lua。
不把此组合验证写成真实账号在完整 Lua UI 中的自动续期验收；续期 UI 流程仍使用合成账号。
上节真实页面验收使用有效授权，没有触发授权续期。
其他真实过期业务码、限频及实体 KO2 的休眠／存储仍待验收。

## 复验

默认完全离线，不访问钥匙串或服务：

```sh
python3 scripts/verify_native_statistics.py
python3 scripts/renew_saved_native_session.py
python3 scripts/test_native_statistics.py
python3 scripts/test_owner_statistics.py
python3 scripts/verify_owner_statistics.py
python3 scripts/test_saved_native_renewal.py
```

仅显式复用用户已授权保存的项目会话：

```sh
python3 scripts/verify_native_statistics.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/statistics_probe.lua /source

# 实际插件页面及新进程离线缓存；候选文件需先打包：
python3 scripts/verify_owner_statistics.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  python3 /source/scripts/run_owner_statistics.py --koreader /validation/runtime/lib/koreader \
  --candidate /validation/owner-statistics-candidate.zip

# 单独读取书架，不发送续期：
python3 scripts/renew_saved_native_session.py --saved-session
# 明确的一次续期；不作为读取失败后的循环重试：
python3 scripts/renew_saved_native_session.py --saved-session --renew
```

早期协议复核的真实凭据、私有字段与原始响应只留在比较进程内存；
新增页面验收的私有统计缓存使用上述临时内存文件系统，不写普通持久磁盘或公开报告。
Web 与墨水屏授权继续保留在两个独立 macOS 钥匙串项目条目，直到整体目标验收收尾。
原生控件／工作进程／SQLite 在 600×800 与 KO2 1264×1680／300 DPI 完成合成 HTTP 验证，
包括四个周期、历史月、离线重开、取消、一次恢复、429、实际阅读器休眠和迟到结果保护。
截图全部为合成数据，不代表实体 KO2 的按键、残影、耗电或性能验收。
