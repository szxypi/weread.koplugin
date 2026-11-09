# 书架状态查看、刷新与标记

书籍详情新增「书架状态」，显示当前账号最近保存的云端在架、置顶、私密阅读、读完标记和缓存时间。
可从这里刷新整个书架并回到该书状态；读取继续使用现有通道策略、后台进程、取消和续期保护。
此阶段是状态读取与展示，云端加入／移除、置顶／私密／读完修改仍未接入 Lua。

## 字段以官方合同与真实响应为准

参考 [Tencent 官方书架文档](https://github.com/Tencent/WeChatReading/blob/d98e66ee60a8c7bcd35da549d0643c4470439643/skills/shelf.md)：
`finishReading` 表示读完，`secret` 表示私密阅读，`isTop` 表示置顶。
不把 `finished`、100% 进度、分组成员、排列位置或阅读时间推定为上述标记。

[真实只读报告](validation-assets/2026-11-09/shelf-flags-owner-readonly.json)：
同一账号的 Web 与墨水屏书架各 139 个 `books[]` 条目，成员及三项状态投影一致。
其中 `finishReading` 与 `finished` 有 117 条不同；按指定字段得到读完 20、未读完 119。
私密／公开标记为 136／3。两个通道的图书和 5 个分组均未返回 `isTop`，因此保留未知，
不能用这些样本宣称真实置顶正例已验收。已知置顶的展示与排序以官方字段说明和合成样本验证。

Python 先验证真实响应，随后 Lua 对同一响应投影，并通过插件 HTTPS 独立发送两个书架 GET 再核对。
没有账号数据写入，真实书名、ID、标记明细和凭据仅经内存／私有管道处理；报告只含数量、状态与布尔值。
最初墨水屏读取为 HTTP 401，使用既有授权完成一次续期、同账号书架和钥匙串回读；
省略刷新令牌时保留旧值。[续期记录](validation-assets/2026-11-09/shelf-flags-native-renewal.json)不包含凭据。
Web 会话曾更新，经同账号核对后写回钥匙串。两个开发条目继续保留到整体目标完成。

## 插件行为

- 新 Web／墨水屏投影保留二进制整数及布尔值，显式 false 不丢失；缺失或异常字段保持未知。
  旧本地快照的精确 `"0"`／`"1"` 字符串保留显示兼容，任意字符串不作真假转换。
- 状态窗口用同一条 SQLite 查询取得当前账号的在架证据与逐书字段。
  完整书单成功保存后，存在的书显示「是」，缺失的书显示「否」及最近快照时间；
  没有完整快照、读取失败或快照标记不一致时显示「未知」。逐书标记仍只读取 `on_shelf=1` 的同书载荷。
  详情载荷、本机进度、待上传意图和下载版本不会覆盖这些状态。
  在架结果描述最近保存的书架；刷新后才取得新的服务端状态。
- 刷新关闭原来的微信读书页面，成功保存后回到该书的新快照。
  取消、休眠、关页、账号／文档／阅读代次变化及旧菜单不能重新打开它；完成回调只接收一次。
  保存失败明确提示快照未更新，不将旧值作为本次刷新结果显示。
- 封面保留私密面具与读完标记，并增加置顶角标；列表同步显示置顶／私密文字。
  明确置顶的书在书架当前排序和组内排序中稳定优先，其他书保持所选排序；不改写云端数组或分组成员。
  首页「最近阅读」继续按阅读时间排列。未知置顶不触发重新排序。
- 已读完／未读完筛选只接受明确状态，未知不会被归入未读完。
  状态窗口和显示规则不改变读书进度、待上传意图、文件或上报权限。

`verify_eink_shelf_write.py` 的读完预览也已修正：只读取 `finishReading`，不再把 `finished` 当作别名或要求两者一致。
对两个真实快照逐条核对了这一读取判定；写入、回执和写后回读仍未实测，原有具体写入确认继续待回复。

## 验证

实际安装包、PluginLoader、ReaderUI、原生菜单／封面／列表、HTTP 与 SQLite，
在 600×800 和 KO2 1264×1680／300 DPI 下通过上述行为，另覆盖详情旧值隔离、
缓存账号隔离、损坏／缺失状态、刷新心跳、SQL 提交失败、关窗旧回调、
正常网格中置顶／私密／读完／进度角标并存、本机阅读记录及零状态写入。
测试中的自动进度发送关闭；没有因此改变生产环境的自动同步配置。

[原生去敏记录](validation-assets/2026-11-09/shelf-flags-runtime.json)、
[600 状态窗口](validation-assets/2026-11-09/shelf-state-known-600.png)、
[KO2 封面标记](validation-assets/2026-11-09/shelf-state-cover-ko2.png)、
[600 列表标记](validation-assets/2026-11-09/shelf-state-list-600.png)全为合成数据。
同轮回归完整下载／资料／书架／书城／原文导航／离线时长、KO2 发现界面与原生译文阅读。
实体 KO2、真实置顶正例和云端状态修改仍待验证，集中性能优化仍安排在完整功能验收之后。

```sh
python3 scripts/verify_shelf_flags.py
python3 scripts/test_shelf_flags.py
python3 scripts/verify_shelf_flags.py --saved-session --native-http --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/shelf_flags_probe.lua /source
```


## 在架、已知不在架与未知

`weread/lib/shelf_snapshot.lua` 校验书单为不超过 5,000 项的连续数组，编号有效且不重复，
双编号字段一致。SQLite 将整份书单、分组和一个小型完整快照标记放在同一事务中保存。
任一条目编码失败、分组／标记写入失败都会回滚，旧书单和旧标记保留。
保存空书单同样建立有效标记，表示当次书架为空。

状态读取在同一 SQL 语句中核对标记、在架总数及该书记录。
只有完整标记匹配，缺失的书才显示「否」；旧缓存缺失标记时，已有在架记录可显示「是」，
缺失记录保持「未知」，由显式刷新补齐。损坏标记或数量不一致保持未知。
在架记录的展示字段不可读时保留已知在架结果，提示字段不可用，不把损坏载荷当作不在架。
查询和菜单均按账号隔离，离线重开保留已知结果，详情资料更新不改变成员身份。

Python 先复用既有 Web 账号／书架 GET 验证，真实书架为 139 本；
8 个在架编号和 1 个不在列表中的合成阴性编号由 Python／Lua 纯模型核对一致。
阴性编号只验证集合查询，不表示某本真实书籍已经移出书架，也未作写后回读。
最终一次共 2 个真实 GET，本项含原型共 6 个 GET，未发送授权维护 POST 或账号数据写入。
首轮会话 Cookie 轮换经归属及现有会话核对后保存回原钥匙串；授权继续保留到整体目标完成。
真实编号只经捕获内存管道处理，Lua 不接收 Cookie 或账号凭据。
[真实只读报告](validation-assets/2026-11-09/shelf-membership-owner-readonly.json)只含计数和状态。

新增 48 项模型／实际 SQLite 检查及 8 个 Python 检查，状态菜单协调增至 37 项。
官方 KOReader v2026.07.1 Linux ARM64／Xvfb 的两尺寸原生场景覆盖 12 项条件，
包括无快照、仅详情、在架／不在架、空书架、旧缓存、字段／标记损坏、非法书单、
编码失败及事务回滚、数量不一致和账号切换；真实 SQLite、原生菜单及离线数据库重开通过。
这些数据库和截图全部使用合成数据，真实账号持久界面另待验收。
[原生报告](validation-assets/2026-11-09/shelf-membership-runtime.json)、
[600 已知不在架](validation-assets/2026-11-09/shelf-membership-absent-600.png)、
[600 未知](validation-assets/2026-11-09/shelf-membership-unknown-600.png)及
[KO2 尺寸在架](validation-assets/2026-11-09/shelf-membership-present-ko2.png)。

```sh
python3 scripts/verify_shelf_membership.py
python3 scripts/test_shelf_membership.py
python3 scripts/verify_shelf_membership.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation \
  ./luajit /source/spec/koreader/shelf_membership_probe.lua /source
```

后续加入／移除或读完修改仍须真实协议验证、实时预检及写后回读，当前保存结果仅供状态展示。
入口：书籍详情 → 书架状态。实体 KO2 的输入、网络和文件系统仍待验收。
