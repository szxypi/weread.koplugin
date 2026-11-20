# 真实账号的原生书架成员验收

新工具验证插件自身的详情、书架状态、确认窗口、后台读取与 SQLite／BookStore 流程。
默认离线；`--saved-session` 也仅执行只读预览。实际写入还要求本次具体授权、相同计划摘要、
宿主 `--apply` 和 Linux 运行器 `--armed` 同时具备，最多两次单本成员 POST。
先前 Python 两步测试的许可已使用，不自动授权这一次原生验收。

2026-11-10 的 600×800 与 1264×1680 真实只读验收均通过：

- 原生详情与独立 Python 墨水屏资料投影一致，实时预览的完整成员摘要与独立书架读取一致。
- 加入确认显示同一所选书籍；取消后的迟到按钮不派发，关闭状态窗口撤销任务并回收工作进程。
- 重建协调器后再次取得有效预览，界面心跳与实际原生绘制通过。
- 两种尺寸各有三次原生书架 GET 和一次原生资料 GET，数据及登录维护 POST 为零。
  Python 各读取三次前置资料及一次后置书架，最终仍为 139 本，成员集合未变。
- 凭据通过匿名内存描述符传入；生产 SQLite 和 BookStore 仅在 `/dev/shm` 临时目录写入，
  退出后删除。未生成私人截图，凭据文件审计和工作进程回收通过。
  本机进度保护使用合成哨兵，未读取或声称核对真实正文位置。

固定字段、两尺寸记录及候选包字节见[原生预览证据](validation-assets/2026-11-10/owner-native-membership-preview.json)。
这证明真实读取和原生预览／取消链路，不代表真实写入已经验收；两种尺寸也是分辨率模拟，实体 KO2 仍待验证。

## 限定写入工具

宿主先绑定同账号、所选普通不在架书籍、完整原成员集合和当前授权摘要。
批准执行后，在独立项目钥匙串条目持久保存一次实验意图并回读，再启动原生运行器。
原生实际请求只允许同账号的固定资料／书架 GET，以及所选编号的各一次加入和移除；
移除必须等加入回执、完整成员回读及本机快照核对通过后才开放。
不续期、不重试数据 POST，也不会为完成测试自动忽略其他成员变化。

宿主在结束后再次独立读取完整书架。只有明确恢复原成员集合、原生回执与请求计数匹配时，
才清除临时实验意图；确认零派发也可释放。失联、无可信回执或不确定结果保留记录，
重启后不能自动再次执行。该记录不含凭据或整份书架；它不覆盖、删除两个开发登录条目。
成员恢复也不等于排序、时间戳或其他服务端元数据恢复。

```sh
python3 scripts/test_owner_shelf_membership.py
python3 scripts/verify_owner_shelf_membership.py
python3 scripts/verify_owner_shelf_membership.py --saved-session --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  python3 /source/scripts/run_owner_shelf_membership.py \
  --koreader /validation/runtime/lib/koreader --candidate /validation/candidate.zip
```

执行模式只能在取得针对该书及两步操作的新授权后使用：

```sh
python3 scripts/verify_owner_shelf_membership.py --saved-session --apply \
  --expected-plan PLAN_SHA256 --lua-command \
  docker exec -i -w /validation/runtime/lib/koreader weread-validation xvfb-run -a \
  python3 /source/scripts/run_owner_shelf_membership.py \
  --koreader /validation/runtime/lib/koreader --candidate /validation/candidate.zip --armed
```

本地模拟已通过只读模式和两次写入模式、两种尺寸及相同传输限制；
`--mock-port` 只接受固定合成凭据，不能用于真实授权。
23 项离线检查覆盖严格去敏格式、双重执行门槛、计划变化、未知意图拒绝重放、
错误回执／不匹配独立回读、超时保留及已证明未派发的释放。
当前真实原生两步写入仍等待本次明确许可，读完等其他状态、断电／强杀、多设备和实体 KO2 仍待验收。
