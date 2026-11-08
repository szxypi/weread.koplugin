# 墨水屏授权续期：验证前置

`scripts/verify_eink_renewal.py` 根据 MiuRead `shelf_client.lua` 的续期流程准备。
它尚未验证真实续期响应，因此不据此添加 Lua 自动续期。

默认不联网、不生成二维码、不读取旧凭据：

```sh
python3 scripts/verify_eink_renewal.py --output /path/to/new-renewal-report.json
python3 scripts/test_eink_renewal.py
```

默认报告为 `PENDING_OWNER_SCAN`，不能视为续期通过。本人方便扫码时，使用已有的
外层 `.validation/eink-auth-tools/` 环境或安装了 `qrcode` 的独立 Python 环境：

```sh
/path/to/python scripts/verify_eink_renewal.py --interactive \
  --output /path/to/new-renewal-report.json
```

执行新二维码登录和书架读取，再复用同一设备标识尝试一次续期，最后以新访问凭据回读书架。
仅允许已知的授权／书架 GET 和 `/login` POST，不修改书架、读完状态或阅读时长。
不导入浏览器 Cookie，不将凭据写入文件；二维码随临时目录清理。上次只读验证的内存进程已退出，
因此本次需要重新扫码，不从旧文件或浏览器恢复凭据。

续期响应必须返回同一账号和完整访问／刷新凭据。缺失账号字段、缺失刷新凭据和字段格式异常均停止，
不照抄参考实现中尚未验证的字段回退。超时或回执未知不重试续期，避免重用可能已经轮换的刷新凭据。
报告只保存阶段、字段名、数量、归属一致性和凭据是否变化的布尔值。

工具也检查书架显示契约：ID 唯一性、标题边界、分组成员和可选字段存在数量；不保存书名、ID 或位置。
原生 `version` 的含义仍标为未验证，不推断它等于 Web `bookVersion`。

7 组离线检查覆盖签名／设备复用、轮换链条、回执丢失、不完整字段／错误账号拒绝、
无效输入不发请求、书架契约和请求范围限制。这些合成结果不能替代本人扫码后的真实验证。
