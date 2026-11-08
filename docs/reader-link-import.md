# 原生阅读链接导入

入口：工具 → 微信读书 → 已导入书籍 → 导入阅读链接。
支持微信读书普通书籍的标准 HTTPS `/web/reader/…` 阅读地址，可带章节后缀、分享参数或片段。
导入保存的是本机记录，不改变微信读书云端书架。首次读取需要已有 Web 扫码登录；
已保存的同账号记录可以离线重开。书籍详情中的目录、下载和阅读继续使用原有服务与实际账号权限。

## 导入与本机管理

1. 原生输入框粘贴阅读链接。先在本机校验站点与路径，去除分享参数、章节后缀及片段。
   非 HTTPS、其他站点、带账号或端口的地址、公众号／文章地址、额外路径和不合法编码不发起请求。
2. 独立内存工作进程只 GET 标准书籍阅读地址；不跟随跳转，不重试 429。
   响应限制 4 MiB，严格解析 `__INITIAL_STATE__.reader.bookInfo`，不使用全文正则猜测书籍身份。
3. 返回书 ID 经现有阅读地址编码后必须与输入的标准书籍地址完全相同。
   只返回有界展示字段和标准地址；不返回原始 HTML、签名会话、阅读位置或服务端版本。
4. 父进程再次检查请求、账号、登录修订、界面代次、文档和阅读会话，才保存并打开原生详情。
   书籍读取地址更新为同书标准地址；期间变动的本机进度、待上传记录、缓存路径及文件版本仍保留。
   已验证的展示资料直接打开，不再自动发第二次资料请求。
5. 已导入书籍按账号保存在本机 SQLite 的 `reader_links` 表中，每批最多 20 条，支持上一批／下一批。
   查询时跳过损坏记录，仍按实际行数推进分页；只为当前批读取展示字段。
   同一书籍再次导入更新原记录，保留其他记录。
6. 点击条目可离线打开详情、手动刷新资料或确认移除导入记录。
   移除只删本账号的链接条目，不删除下载文件，也不修改云端书架。
   账号变化后，旧菜单和旧移除确认均不能操作新账号。

关闭插件界面、关书、休眠和账号切换会取消自有读取，并关闭输入框、列表及确认框。
加载提示可直接取消；迟到结果不能重新打开详情或保存记录。
读取修订变化或超过 120 秒时拒绝结果。失败保留已有导入记录。
导入列表与书架快照分别存储，书架刷新不会清掉导入记录，导入也不伪装成加入云端书架。

## 先验证协议再接入

`scripts/verify_reader_link.py` 先通过已有 Web 钥匙串授权核对账号并读取两个真实书架阅读地址，
验证页面书籍身份与地址一致，再实现 Lua。随后 Python／Lua 展示投影一致，
KOReader 原生 HTTPS 独立两个 GET 的结果再次一致。
[真实去敏记录](validation-assets/2026-11-09/reader-link-owner-readonly.json)只包含状态、数量和布尔值。
真实 HTML、地址、书 ID、展示资料与凭据只在内存中比较，没有账号数据写入或新凭据文件。
仍只使用原有两个钥匙串条目，整体目标未完成时继续保留。

默认离线复验：

```sh
python3 scripts/verify_reader_link.py
python3 scripts/test_reader_link.py
luajit spec/reader_link_spec.lua
luajit spec/reader_link_ui_spec.lua
```

显式复用已获授权保存的账号并做模型／原生 HTTPS 对照（`--lua-command` 放在最后）：

```sh
python3 scripts/verify_reader_link.py --saved-session --native-http --lua-command \
  docker exec -i -e XDG_RUNTIME_DIR=/validation/source-binding-xdg \
  -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  ./luajit /source/spec/koreader/reader_link_probe.lua /source
```

完整原生核心用例在 Web 无密钥流程中调用 `spec/koreader/reader_link_smoke.lua`：

```sh
WEREAD_TEST_OFFLINE_TIME=1 xvfb-run -a python3 scripts/mock_weread.py \
  --smoke --port 0 --koreader /path/to/koreader --run-dir /path/to/new-directory \
  --width 1264 --height 1680 --dpi 300
```

600×800 与 KO2 1264×1680／300 DPI 覆盖实际原生输入、后台 HTTP、账号隔离 SQLite、
新设置实例回读、离线重开、分页／损坏记录跳过、本机记录移除、更新期间本机位置保护、
429／取消／授权修订／账号变化／休眠及旧确认清理。
[去敏运行记录](validation-assets/2026-11-09/reader-link-runtime.json)和截图均使用合成数据。

当前范围为普通书籍的标准阅读链接；微信文章链接、公众号订阅、导出、书籍短链接等仍待单独实现和验证。
两种分辨率的原生桌面运行不代表 KO2 实体按键、网络、休眠、残影或耗电验收。
