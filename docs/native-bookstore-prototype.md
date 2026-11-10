# 原生书城：墨水屏授权读取

首页、书城、搜索框、相似书籍列表继续使用 KOReader Lua 控件，正文使用原生 EPUB 引擎。
本次扩展数据通道，不加载网页界面、不执行网页 JavaScript。集中性能优化仍安排在全部功能验收后。

## 真实协议先行

参考 MiuRead 的 `miuread/eink_client.lua`（AGPL-3.0-only，来源见 NOTICE），
先用 `scripts/verify_native_discovery.py` 验证真实响应，才接入 Lua：

| 用途 | 固定 GET | 已核对的参数／响应 |
| --- | --- | --- |
| 搜索 | `/store/search` | `keyword`、`scope=10`、`count=20`、`maxIdx`；根 `books` |
| 为你推荐 | `/book/recommend` | `count=20`、`maxIdx`；根 `books` |
| 相似书籍 | `/book/detailinfo` | `bookId`、`listtypes=2`、`synckey=0`、`count=20`、`maxIdx`；`booksimilar.books` 和 `sessionId` |

调用仅使用墨水屏授权头，隔离 Web Cookie 和 Skill 密钥；HTTPS 使用插件的 CA／SAN 校验。
仅投影有界的书籍展示字段、分页游标和推荐会话，不把原生 `version` 当成 EPUB `bookVersion`。

[真实去敏报告](validation-assets/2026-11-09/native-discovery-owner-readonly.json)：
同一账号的书架回读为 139 本；搜索两页 20＋2 本，相似书籍两页 20＋3 本，游标前进、两页无重复、
相似推荐会话保持一致。Python 与 Lua 对同一真实响应的展示投影一致；KOReader 原生 HTTPS
另行发送 5 个固定只读 GET，独立重复搜索／相似分页检查。没有写入书架、阅读进度或时长。

**真实个性化推荐返回空列表**。只证明空结果契约，不证明真实推荐有内容时的显示或分页；
推荐 20＋6 本的展示／分页使用合成账号验证，不拿最近阅读替代推荐。

## 插件行为

- 搜索、推荐、相似书籍自动优先当前账号的墨水屏授权；无授权时使用已配置的 Skill 密钥。
  两者都缺少时打开授权入口。原有“书架读取方式”仍只影响书架，不作为书城的全局开关。
- 首批读取遇到原生 HTTP 401／403／50x、传输错误或超时时，有 Skill 密钥才可回退一次；401 优先尝试下述一次续期。
  HTTP 429、API 拒绝和无效响应不触发回退。后续页和上一批绑定原通道及授权修订号，不能拼接不同来源。
  刷新列表会从首批重新读取，清除旧游标和推荐会话。授权变化后需刷新或重开列表。
- 网络读取、解析及投影使用独立后台进程和最多 512 KiB 的内存管道；原始 HTTP 响应最多 4 MiB。
  退出页面、取消等待时终止后台请求；关闭种子书详情也立即停止相似书籍请求。
  账号／登录代次／授权变化时丢弃旧结果，旧回调不能关闭新请求的等待窗。
  失败保留当前列表；尚无当前列表时可打开对应的已保存批次。浏览结果按账号写入独立 SQLite，不写入全局设置。
- 分类书单同样在后台读取；分类层级目录也已迁入独立后台进程，并保存公开 SQLite 缓存供未登录离线重开，
  详见[公开分类目录说明](public-category-catalog.md)。
- 原生授权书城读取的 HTTP 401 可复用既有持久化续期流程最多恢复一次，保留原生分页的游标／推荐会话；
  续期后的再次 401 不循环，已有原生分页不会回退其他来源。取消／休眠保留不明回执的待确认标记，
  后续读取不会重放续期。规则见[续期说明](eink-renewal-prototype.md#插件行为)；书城真实失效／限频待验收。

## 保存浏览批次与离线重开

搜索、为你推荐、相似书籍及分类书单现在保存到当前账号数据库的 `discovery_cache` 表。
书城重开时恢复最后浏览的查询与批次，标题开头标记“已缓存”，长书名不会挤掉状态；离线搜索相同关键词、
打开相同种子书的相似书籍，或者点击已缓存的前／后批次，只读本地数据，不要求有效的墨水屏授权。
没有对应缓存时保留当前列表并提示联网刷新，不把别的查询或账号的数据当成结果。
从详情打开离线相似书籍会关闭详情窗口，避免列表被旧窗口遮住。

缓存只含查询的展示信息、书籍卡片字段和已浏览批次，不保存 Cookie、访问／刷新凭据、
授权修订号或推荐会话 ID。缓存页只能在已保存的链内往返，不根据远端的 `hasMore` 猜测未保存的下一批。
即使网络已恢复，缓存批次的前后切换仍只用本地数据；点击刷新从首批重新取得当前通道／授权／会话，
不会把新授权拼到旧推荐会话上。新首批替换该查询的旧链，旧任务不能继续向已替换的链写入。
实时读取失败时保留当前列表；取消、页面或账号变化后，迟到结果不能保存。

每账号最多 12 个查询，每查询最多 12 批，每份 JSON 最多 2 MiB，总载荷最多 16 MiB。
按最近保存顺序清理较旧的查询；单查询超限或保存失败时继续显示本次在线结果并提示无法离线保存。
所有写入、查询链替换和配额清理在同一 SQLite 事务完成；失败回滚，原有缓存保留。
保存内容经过有界字段投影，损坏缓存不进入网络参数；这些不是服务端原子快照或任意外部进程并发的保证。
封面图片继续走已有封面缓存，正文不进入本表。

## 实际页面与文件缓存验收（2026-11-10）

官方 KOReader v2026.07.1 Linux ARM64／Xvfb，实际 FileManager 通过 PluginLoader 加载候选插件。
600×800／167 DPI 与 1264×1680／300 DPI 各完成在线及全新进程离线重开。
真实搜索两批 20＋2 本、相似书籍两批 20＋6 本，推荐为空；
每尺寸在线五个视图、离线八个视图，含上／下批及最后浏览批次恢复。
真实推荐的非空内容与更多翻批只由合成服务补充，不把空结果当作完整推荐验收。

前置 Python 读取用于选定同账号种子书和请求范围；实时页面则与**各自同一次响应**的独立 Python 投影逐字段比较。
原始响应及页面字段只通过捕获的内存管道返回比较进程，不进入报告。
早期使用另一请求的前置内容做相似推荐比对时停止，未把该失败算作通过；最终同响应比较、
文件 SQLite、账号隔离、不保存远端会话、新进程离线零请求、工作进程回收及凭据文件审计通过。
开发验证的私有缓存只存在于临时内存文件系统，结束时目录删除，两份钥匙串登录条目继续保留。
原生控件尺寸和实际重绘已核对；真实页面没有截图或人工目视检查，封面下载另有独立证据。
该分辨率模拟不证明实体 KO2 的按键、休眠、残影、速度或耗电。

合成实测另覆盖搜索 20＋6、相似 20＋5、非空推荐 20＋6 的两尺寸在线／新进程离线组合，
以及真实 SQLite 的账号隔离、旧链拒绝、提交失败回滚、查询／批次／单份及总容量上限和损坏缓存。
原有授权／书架／书城／资料／统计子场景通过；正常选书、阅读、离线与同步的两尺寸回归在本轮前一候选通过，
随后仅调整缓存标题位置和 SQLite 游标失败清理。最终候选的六份书城／核心界面安装中，
203 个生产文件与源码及各自候选逐字节一致，ZIP CRC 和重绘检查通过。
合成长书名缓存页面已目视核对：[普通尺寸](validation-assets/2026-11-10/bookstore-offline-cached-600.png)、
[KO2 分辨率](validation-assets/2026-11-10/bookstore-offline-cached-ko2.png)。

旧综合冒烟 `weread_mock_smoke.lua` 在两尺寸的后续第 138 行同步断言失败，
观察到 `source_position_unavailable`、没有派发该次上传；完整综合冒烟尚未通过，原因仍待定位。
此前成功的书城子场景及独立正常阅读入口验证单独记录，不把它们扩大为整个旧综合测试通过。
元数据、请求数量、候选字节及代码哈希见[验收证据](validation-assets/2026-11-10/bookstore-offline-batches.json)。

默认离线入口：

```sh
python3 scripts/verify_owner_discovery.py
python3 scripts/test_owner_discovery.py
```

需要已有授权的只读实际页面验收（候选先打包，始终一次只运行一个 KOReader 界面）：

```sh
python3 scripts/verify_owner_discovery.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  python3 /source/scripts/run_owner_discovery.py --koreader /validation/runtime/lib/koreader \
  --candidate /validation/discovery-cache-candidate.zip
```

## 本机开发授权

用户允许保留凭证直到整体目标完成，并在本轮重新扫码。`scripts/secure_native_session.py`
把同账号的墨水屏授权保存至 macOS 系统钥匙串的独立项目条目
`org.codex.weread.goal-native-validation`，账号标签为 `P006_kindle_wxread`；
Web 条目 `org.codex.weread.goal-validation` 保留，二者互不覆盖。
保存须通过登录／书架核验，并回读相同字节；复用时核对 Web 条目的账号和原生凭据归属。
早期协议检查的私有书名、ID、会话、响应与凭据只经本机内存管道比较；新增页面验收的已投影缓存使用上述临时内存文件系统。
原始响应、凭据及私人截图不写普通持久磁盘、公开报告或仓库。
该钥匙串用于开发验证，插件设备端仍使用现有账号绑定的独立授权存储。

默认命令完全离线，不打开钥匙串或网络：

```sh
python3 scripts/verify_native_session.py
python3 scripts/verify_native_discovery.py
# 仅显式复用当前用户已授权的项目条目：
python3 scripts/verify_native_session.py --saved-session
python3 scripts/verify_native_discovery.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/discovery_probe.lua /source
```

整体目标验收收尾或用户撤销授权时清理**两个**开发钥匙串条目；当前目标未完成，不执行清理。
原生条目的显式清理入口为 `verify_native_session.py --clear-saved-session`；
Web 条目沿用 `verify_web_source_progress.py --clear-saved-session`。
读取失败、取消或单次测试结束均不删除已授权保存的条目。

后续已在统计接口观察真实 Lua HTTP 401，并完成一次 Python 续期、书架／钥匙串回读及 Lua 统计恢复，
见[原生统计说明](native-statistics-prototype.md)；不作为书城所有真实失效／限频的验收。
实体 Kindle Oasis 2、其他业务码／限频、非空个性化推荐、其他接口、精确同步写后回读仍待验收。
