# 书架操作的本地记录读取

读完标记、私密阅读的待核对记录，以及读完标记、书架加入／移除的离线队列，原来每次读取都通过可写连接重新初始化数据库。书架缓存同时保存时，重复设置 SQLite WAL 可能遇锁，导致记录虽可读取却被当作存储故障。对于自动同步，这会暂停已保存的操作；对于可能已派发的操作，仍会按未知结果保护，不重发。

现有表使用同账号的只读连接，读取前核对所需表、读取后再次核对账号，数据库锁的每次等待上限为 50 毫秒。第一次建库或旧版成员队列缺少标题表时仍使用原初始化；损坏、读取失败或账号改变不会被视作空记录。创建、领取、变更和删除继续使用原来的 FULL 同步及事务，不因只读路径改变发送规则。

三种尚未改造的入口分别执行三轮旧版与新版交替对照，每轮 5,000 次读取，同时确认有实际书架缓存写入重叠。旧版私密记录遇锁 214 次、读完队列 198 次、成员队列 212 次；新版各 15,000 次读取均未遇到该故障。队列测试交替读取单条和列表。该压力测试只覆盖合成数据，并不保证其他锁定或设备条件下不会出现错误。

- [私密记录对照](validation-assets/2026-11-21/private-store-contention-paired.json)
- [读完队列对照](validation-assets/2026-11-21/finish-queue-contention-paired.json)
- [成员队列对照](validation-assets/2026-11-21/membership-queue-contention-paired.json)
- [读完与离线队列原生回归：600×800](validation-assets/2026-11-21/shelf-store-shared-finish-600.json)、[KO2 尺寸](validation-assets/2026-11-21/shelf-store-shared-finish-ko2.json)
- [私密阅读原生回归：600×800](validation-assets/2026-11-21/shelf-store-shared-private-600.json)、[KO2 尺寸](validation-assets/2026-11-21/shelf-store-shared-private-ko2.json)
- [成员加入／移除原生回归：600×800](validation-assets/2026-11-21/shelf-store-shared-membership-600.json)、[KO2 尺寸](validation-assets/2026-11-21/shelf-store-shared-membership-ko2.json)

测试还覆盖持续独占锁时安全失败、解锁后保留原记录、旧队列缺标题表的初始化、账号切换、已领取操作不重发与 FULL 写入回滚。此阶段不修改真实账号；实体 Kindle 仍待验收。

私密阅读原生测试的首次两尺寸运行未通过：旧合成数据把空分组编码成 JSON 对象，现有协议检查要求数组，因此在第一次书架读取后停止，零模拟写入。修正测试样本为数组后，两尺寸完整回归通过；[600×800 失败记录](validation-assets/2026-11-21/shelf-store-private-fixture-600-unverified.json)和 [KO2 尺寸失败记录](validation-assets/2026-11-21/shelf-store-private-fixture-ko2-unverified.json)保留。新增协议组件测试分别核对空对象与空数组。
