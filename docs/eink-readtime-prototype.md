# 离线时长补传：只读前置验证

当前工具 `scripts/verify_eink_readtime.py` 只验证补传所需的读取条件，不构造上传签名或发送时长。
它参考 MiuRead `c1893562aa25a870b8dd076d7be062a3348f823e` 的 `eink_readtime.lua` 与
`readtime_protocol.lua`，复用本仓库已有的 E-Ink 扫码原型。未将未验证的补传接口接入 Lua。

2026-11-08 实际匿名检查：

| 读取 | 结果 |
| --- | --- |
| `GET /config?token=1` | HTTP 401，必须完成 E-Ink 授权 |
| `GET /feature?synckey=0` | HTTP 200，包含 feature 与 synckey；未提供 guest_token |

仅保存状态和结构的 [实际检查报告](validation-assets/2026-11-08/eink-readtime-preflight.json)
为 `PARTIAL`。匿名 feature 响应不证明客户端默认签名参数、授权后的 config 或上传接口可用。
本轮没有创建二维码、扫码、登录或发起账号数据写入。

## 运行

无需账号的检查：

```sh
python3 scripts/verify_eink_readtime.py --output /path/to/new-report.json
python3 scripts/test_eink_readtime.py
```

本人方便扫码后，可以使用已准备的独立 Python 环境进行只读验证：

```sh
../.validation/eink-auth-tools/bin/python scripts/verify_eink_readtime.py \
  --interactive --output /path/to/new-private-report.json
```

流程依次进行扫码登录、书架读取、授权后的 config／feature 读取，再读取书架中一本普通书籍的当前位置。
可用 `--book-id` 指定书架中的书；不指定时选择第一本普通书。公众号文章不参与。
临时二维码结束后删除，凭据仅在进程内存中使用，不读取或导入浏览器 Cookie。

可追加 `--ledger /path/to/offline-time-<匿名账号标识>.db`，只读检查当前账号的本机账本。
文件名须与本次授权账号的匿名标识一致。工具不修改配置、队列、领取状态或确认记录。
它只选择指定书籍、同一版本的最多 100 行／600 秒，拒绝时间重叠、未来时间和无效元数据，
并单独列出不确定状态的秒数。版本非零只表示字段存在，不表示与实际阅读 EPUB 的版本一致。

报告不包含凭据、账号／书籍标识、当前位置值、数据库路径或完整响应。
工具没有 `--upload` 选项，传输层也拒绝 `/login` 之外的 POST；扫码授权本身仍使用原有登录 POST。
`time_uploads_attempted` 始终为零，即使只读前置检查成功，完整结果仍为 `PARTIAL`。

## 正式补传前仍需完成

1. 本人扫码后实际验证 config、feature、当前位置及账号账本绑定。
2. 验证历史版本属于正在阅读的文件。当前账本中的版本来自书籍记录，
   不能将后来更新的云端目录版本当作旧 EPUB 的版本；未知版本也不能冒充已确认。
3. 协调在线上报和离线片段的覆盖区间。原有 `ReadReport:_send` 缺省上报固定 30／60 秒，
   断网恢复后的这段时间可能与本机离线片段交叉，当前没有持久的在线覆盖明细。
   正式补传须先避免重计，不能将所有 pending 秒数直接累加到云端。
4. 准备只含时长的实际请求，独立验证签名与服务响应，并检查写后时长入账及章节／偏移保持不变。
   本只读工具不执行此步骤；应先提供具体书籍、已捕获时间段及预期变化，完成授权后再验证。
5. 验证中断、超时、限流、凭据变化和确认持久化失败；结果不确定的请求不得自动重放。

9 组离线测试覆盖只读传输限制、凭据去敏、书架选择、位置字段、真实 SQLite 只读预览、
账号隔离、版本分组、重复时间／未来时间拒绝及命令行入口。它们不代替线上写入和 KO2 真机验收。
