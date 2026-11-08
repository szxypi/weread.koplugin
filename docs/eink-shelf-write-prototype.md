# 云端书架写入：预览与回读工具

`scripts/verify_eink_shelf_write.py` 参考 MiuRead `eink_client.lua`，为加入书架、移出书架、
标记读完和取消读完准备 Python 原型。目前没有执行真实写入，也没有把这些接口加入 Lua。

默认模式不联网、不登录、不写入，报告为 `PENDING_TARGET_AND_OWNER`：

```sh
python3 scripts/verify_eink_shelf_write.py --output /path/to/new-shelf-write-report.json
python3 scripts/test_eink_shelf_write.py
```

指定一本普通书籍并在场扫码，可以只读取操作预览：

```sh
/path/to/python scripts/verify_eink_shelf_write.py --interactive \
  --operation add --book-id 'BOOK_ID' \
  --output /path/to/new-preview-report.json
```

`operation` 支持 `add`、`remove`、`finish`、`unfinish`。预览不会提交修改。
实际写入还要求 `--apply`，以及与目标完全相同的 `--confirm-book-id`。
执行前必须获得针对这一本书及这一次操作的明确授权；当前会话只有登录和读取授权，不能据此执行写入。
用户允许任选测试书；所选书籍的具体操作已单独请求确认，未确认前继续保持只读。
读完状态可能影响云端显示，不将其称为无副作用或可自动还原的操作。

工具先读完整书架，绑定当前账号、单本目标、原状态和成员快照；提交前再次读取检查。
已达到目标时只读返回 `NOOP`，书架发生其他成员变化或读完标记不完整／矛盾时停止。
一次预览最多提交一次 POST；计划在可能发送时消耗，超时、拒绝或回执丢失都不重发。

提交后最多三次只读回查。只有识别到成功回执、目标状态匹配且没有额外成员变化时才报告 `PASS`。
仅回读达到目标但回执未知时保留 `PARTIAL`，不把别的设备可能完成的修改当作本次协议验证。
回执成功但回读不匹配同样不能通过；不自动执行反向写入。取消后的报告区分尚未发送与可能已经提交。

另有明确选择的 `--roundtrip --operation add`，用于一次“加入、回读、移除、回读”测试。
它也默认只读；执行这两次写入必须先获得针对两步的授权，再加 `--apply --confirm-book-id`。
目标原已在架或被其他设备加入时不移除；只有本次加入有成功回执且成员回读匹配才准备第二步。
每步均重新检查成员，回执未知或有额外成员变化即停止，不自动重发或擅自还原。
报告分别记录两步结果，只有两步均有成功回执及匹配回读才设置 `roundtrip_verified=true`。
恢复书架成员不代表排序、时间戳或服务端其他元数据也已恢复。

只允许授权、书架读取和当前精确预览对应的写入路径／请求体，不能用工具执行其他接口。
凭据、账号、书名、目标 ID、原始快照及实际请求体只留在进程内存，不进入报告或工作文件。
14 组离线检查覆盖请求体、预检、一次发送、错误归属／未确认拒绝、状态冲突、无操作、回执丢失、
回读失败、HTTP 拒绝、默认命令不联网及两步测试的中止条件；真实请求、回执含义及账号效果仍须验证。
