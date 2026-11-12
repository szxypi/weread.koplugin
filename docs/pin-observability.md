# 置顶状态的只读可观测性

2026-11-12 在私密阅读原生往返通过后，继续核对置顶状态。
[官方书架说明](https://github.com/Tencent/WeChatReading/blob/d98e66ee60a8c7bcd35da549d0643c4470439643/skills/shelf.md)描述的是官方网关的 `books[].isTop`。
这不能证明墨水屏或 Web 原始接口也返回该字段。
[weread-omni 的同步参数说明](https://github.com/teng-lin/weread-omni/blob/88bd2e095d7d7ee423eaadf8f40653e72c5be6d4/docs/endpoints.md)另列出 `synckey`、`lectureSynckey`、`onlyBookid`。

新增默认离线的 `verify_pin_observability.py`，仅在显式 `--saved-session` 下进行受限读取：

- 墨水屏 `/shelf/sync`、`?synckey=0`、`?synckey=0&lectureSynckey=0&onlyBookid=0`。
- Web 完整书架、读取前后同账号验证，以及 `apikeyGet?only_show=1` 查询已有密钥。
- 仅当查询取得可用密钥时，允许一个 `/shelf/sync` 官方网关读取 POST；该 POST 不修改账号数据，单独计数。

实际三份墨水屏和一份 Web 回包各有 140 个图书条目，成员及可见私密／读完字段一致，140 个置顶字段均缺失。
只读密钥查询没有取得可用密钥，本轮官方网关读取未执行。该结果不能宣称官方通道无置顶值，也不能把缺失解释为 false。
原有置顶展示和明确状态下的稳定优先排序保留，生产置顶修改仍未接通。

[去敏报告](validation-assets/2026-11-12/pin-observability.json)仅包含数量、状态、布尔值；凭证和原始响应只留内存。
零账号数据修改、零授权续期，Web 和墨水屏开发登录继续保留。没有启用 Skill 或签发新密钥的操作。
新增八项离线边界测试覆盖默认不联网、缺失／明确 false／异常字段、拒绝写入与未知查询、
密钥查询的登录边界、网关固定读取路径及无 Cookie／响应大小限制。
生产 Lua 未修改，既有真实原生验收不作为置顶修改的证明。

下一步需要可独立核验的真实置顶原值和修改后读回，之后才接入 Lua；在此之前继续其他功能开发。

```sh
python3 scripts/test_pin_observability.py
python3 scripts/verify_pin_observability.py --saved-session
```
