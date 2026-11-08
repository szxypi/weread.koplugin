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
它只选择指定书籍、同一版本及同一文件来源的最多 100 行／600 秒，拒绝时间重叠、未来时间和无效元数据，
并单独列出不确定状态、文件绑定和来源未确认的秒数。旧账本只读兼容，不在验证工具中升级结构。
版本非零不表示已验证 E-Ink 服务端的版本语义；历史账本仍可能来自可变的书库记录。

报告不包含凭据、账号／书籍标识、当前位置值、数据库路径或完整响应。
工具没有 `--upload` 选项，传输层也拒绝 `/login` 之外的 POST；扫码授权本身仍使用原有登录 POST。
`time_uploads_attempted` 始终为零，即使只读前置检查成功，完整结果仍为 `PARTIAL`。

## 正式补传前仍需完成

1. 本人扫码后实际验证 config、feature、当前位置及账号账本绑定。
2. 实际验证下载时观察到的 `bookVersion` 是否符合 E-Ink 补传接口的版本语义。
   本机已把下载快照写入 EPUB 的 `OEBPS/weread-source.txt`，由打开的 CREngine 文档读取并固定到当前会话；
   后台替换同一路径不会改写旧会话的来源。旧文件、混合／缺失版本的断点缓存保持版本 0，
   原有账本保留旧值并标记 `legacy_unverified`。来源摘要标识下载来源，不是整个 ZIP 的内容哈希或服务端认证。
   上述本机绑定已验证，但不能据此把未知或旧账本的版本作为已确认的补传参数。
3. 协调在线上报和离线片段的覆盖区间。原有 `ReadReport:_send` 缺省上报固定 30／60 秒，
   断网恢复后的这段时间可能与本机离线片段交叉，当前没有持久的在线覆盖明细。
   正式补传须先避免重计，不能将所有 pending 秒数直接累加到云端。
4. 准备只含时长的实际请求，独立验证签名与服务响应，并检查写后时长入账及章节／偏移保持不变。
   本只读工具不执行此步骤；应先提供具体书籍、已捕获时间段及预期变化，完成授权后再验证。
5. 验证中断、超时、限流、凭据变化和确认持久化失败；结果不确定的请求不得自动重放。

10 组离线测试覆盖只读传输限制、凭据去敏、书架选择、位置字段、真实 SQLite 只读预览、
账号隔离、版本／文件来源分组、旧结构兼容、重复时间／未来时间拒绝及命令行入口。
它们不代替线上写入和 KO2 真机验收。
