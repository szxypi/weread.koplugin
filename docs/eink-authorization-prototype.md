# E-Ink 授权：真实验证前置

`scripts/verify_eink_login.py` 根据 MiuRead 的 `shelf_client.lua` 和 weread-omni 的
`src/auth/qrlogin.ts` 准备原型。未将尚未真实验证的登录、续期或书架写操作接入插件。

2026-11-08 实际验证：E-Ink `/wxticket` 与微信 SDK `/connect/sdk/qrconnect` 均返回 HTTP 200，
票据及二维码会话字段完整。只保存结构统计，见
[原型报告](validation-assets/2026-11-08/eink-auth-probe.json)。报告状态为 `PARTIAL`，
不代表账号授权完成。本人扫码、`/login` 和带 native 凭据的 `/shelf/sync` 尚未执行。

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

后续接入还需验证：与插件当前 Web 账号一致、取消与超时、账号切换、凭据保存失败、续期、
服务端限流和失效状态；书架写入需单独进行写后回读和失败恢复验证。

离线补传另有 [只读前置工具](eink-readtime-prototype.md)，可在同一次本机扫码后检查 config、
feature、书架位置和账号账本。该工具不上传时长，也不替代完整的授权和写后回读验收。
