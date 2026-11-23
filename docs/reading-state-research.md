# 在读状态的只读核对

书架现有筛选使用服务端明确的 `finishReading`，区分已读完与未读完。另有开源客户端使用 [`/book/markstatus` 的 `status=2`](https://github.com/teng-lin/weread-omni/blob/main/src/api/resources/shelf.ts) 标记或取消在读；这一实现本身不能证明该操作的独立回读字段、影响范围或恢复语义。

2026-11-24 使用已保存的同一账号授权，只读抽查数字书号书架的 30 本书。独立读取墨水屏进度接口，检查服务端的 `isStartReading`、章节号、`startReadingTime` 和书架的 `finishReading`，前后核对书架成员、标志及分组。仅保存[汇总计数](validation-assets/2026-11-24/reading-state-owner-readonly.json)，不保存书号、书名、具体位置或凭据；没有发送账号数据修改请求。

其中 6 本返回 `isStartReading=0` 且章节号非零；另有 4 本同时返回 `isStartReading=1` 和已读完。这个有限样本表明不能用章节位置或已读完状态推断该字段，也不能把它直接等同于用户手动设置的「在读」。字段缺失或格式异常时保持未知，不按零处理。

可使用 `python3 scripts/verify_reading_state.py` 离线检查；显式加入 `--saved-session` 才会检查钥匙串中的同账号授权并执行有界只读采样。账号核对后，墨水屏探针只允许书架与所选进度的 GET，遇到账号、书架、目标或接口异常即停止；结果只含汇总。此记录不证明写入操作成功或可逆。

下一步需在隔离测试书上建立可独立核对的前后状态，验证一次 `status=2` 的实际回执和影响，再视结果确认取消操作能否恢复；结果不明确时不接入生产写入或自动重试。实体 Kindle 和不同来源的书也仍待验证。
