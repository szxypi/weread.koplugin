# E-Ink 授权：真实验证前置

`scripts/verify_eink_login.py` 根据 MiuRead 的 `shelf_client.lua` 和 weread-omni 的
`src/auth/qrlogin.ts` 准备原型。已在 2026-11-08 完成本人扫码、登录及带凭据的只读验证。
随后迁移 `weread/lib/native_authorization.lua` 协议核心，并新增插件内“墨水屏授权”入口及保存／清除流程。
主登录入口仍使用原有 Web 流程；墨水屏授权绑定当前 Web 账号，续期和通道选择继续待接入。

本次真实检查：登录、书架、config、feature 和当前位置均返回 HTTP 200，书架返回 139 条图书记录。
字段结构、类型和数量见 [已授权只读报告](validation-assets/2026-11-08/eink-authenticated-readonly.json)。
其中授权和读取检查通过；报告整体保持 `PARTIAL`，因为时长补传的写入、版本语义和入账回读尚未验证。
二维码已删除，内存验证进程已退出；没有把凭据导入插件设置或保存到磁盘，没有修改书架或上报时长。

2026-11-08 实际验证：E-Ink `/wxticket` 与微信 SDK `/connect/sdk/qrconnect` 均返回 HTTP 200，
票据及二维码会话字段完整。只保存结构统计，见
[原型报告](validation-assets/2026-11-08/eink-auth-probe.json)。报告状态为 `PARTIAL`，
记录的是扫码前的历史状态；本人扫码及后续读取结果见上方已授权报告。

不扫码的原型检查（Python 标准库）：

```sh
python3 scripts/verify_eink_login.py --output /path/to/new-metadata-report.json
python3 scripts/test_eink_login.py
```

本人在场时的只读验证：

```sh
python3 -m venv /path/to/eink-auth-tools
/path/to/eink-auth-tools/bin/python -m pip install 'qrcode[pil]'
/path/to/eink-auth-tools/bin/python scripts/verify_eink_login.py --interactive \
  --output /path/to/new-private-metadata-report.json
```

当前工作区已在外层 `.validation/eink-auth-tools/` 准备这一独立 Python 环境。
脚本显示临时本地二维码，不打印二维码会话、授权码、账号 ID、访问凭据或刷新凭据。
完成或超时后删除二维码文件；凭据只留在进程内存。不导入浏览器 Cookie，不修改账号书架。
请直接在本机扫码，无需将凭据、截图或登录文件发到聊天／仓库。

5 组离线测试覆盖二维码和登录字段、只读书架验证、不完整凭据拒绝、错误信息去敏、
跳转拒绝及轮询超时／拒绝／过期。离线测试不替代真实授权验证。

Lua 协议核心含 109 项检查：账号不匹配、取消和会话变化均停止后续步骤；登录可能已发出后不重用授权码，
仅书架回读失败时可重试读取；发送前的序列化或时钟错误不会把授权码当作已发送。
响应体限制为 4 MiB，拒绝跳转、无效凭据和请求头注入。请求不继承 Web Cookie 或官方 API Key，
返回的凭据只交给调用方，核心不自行持久化。新增敏感诊断模式也用于原有 Web 登录，隐藏错误响应、
查询参数、响应头和底层异常中的凭据，只记录阶段与状态。

插件菜单“微信读书 → 墨水屏授权”提供扫码、重新授权和清除。需要先完成现有 Web 扫码登录，
墨水屏扫码账号必须与之相同；不转换或替换 Web Cookie／官方 API Key。
后台请求通过进程与有界内存管道传递结果，取消、账号切换、休眠和关书时停止待办请求。
登录可能已发出而回执丢失时重新扫码；只有书架验证失败时重试读取，保存失败可单独重试本地写入。

授权保存到插件数据目录的独立、固定容量 `native-authorization.lua`，不会覆盖 Web 登录设置。
保存后重新读取主文件核对；读取失败时不使用 `.old` 中的旧凭据。授权绑定 VID 和登录代次，
同账号在同一秒重新登录也会使旧授权失效，普通 Cookie 续期保持绑定。保存／清除检查授权修订号，
较早的授权窗口不能覆盖较新的结果；退出账号清理主文件及备份。凭据不进入日志或临时工作文件。

新增组件检查覆盖保存失败、主文件回读、过期回执、账号不匹配、二维码取消、超时、
本地保存重试不发请求、书架重试不重复登录和迟到回调不取消新会话。
真实 KOReader 与合成 HTTP 验证菜单、二维码关闭、后台响应、25 KiB 管道、立即取消、保存、
新 Settings 实例回读及清除；600×800 与 KO2 尺寸灰度配置通过。实际运行修复了子进程回调参数适配。
这些界面与磁盘检查仅使用合成凭据；本次本人扫码的真实凭据仍未保存，实体 KO2 完整扫码流程尚待验收。
后续仍需续期、限流／失效处理和通道策略；书架写入另需实际写后回读及失败恢复。

离线补传另有 [只读前置工具](eink-readtime-prototype.md)，可在同一次本机扫码后检查 config、
feature、书架位置和账号账本。该工具不上传时长，也不替代完整的授权和写后回读验收。
