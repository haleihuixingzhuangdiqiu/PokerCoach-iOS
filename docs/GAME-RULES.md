# 多人开手规则与第三盲

实现/核对日期：2026-09-16。此文描述规则引擎，不表示屏幕历史已全部识别，也不表示策略已被验证能够战胜真人。

## 公开接口

```swift
let rules = try PokerGameRules(
    smallBlind: 20,
    bigBlind: 50,
    ante: 0,
    utgStraddle: .optional(amount: 100)
)
let start = try rules.startHand(
    seats: initialSeats,
    button: buttonIndex,
    optionalStraddle: true
)
let state = start.state
let positions = start.positions
let postings = start.forcedBets
```

- `seats` 是实际参与本手的 2–9 名玩家，按顺时针排列。`button`、所有位置、`pending`、`PotLayer.eligible` 都是数组索引，而不是 `Seat.id`。
- 输入筹码为付强制注之前的数值，且必须没有本手投入、弃牌或行动标记；不会把已有牌局清空重建成“完整历史”。
- `UTGStraddlePolicy` 分为 `.disabled`、`.optional(amount:)`、`.mandatory(amount:)`。可选第三盲须在本手明确开启，且足额支付；强制第三盲每手自动支付。
- `PokerHandStart` 返回 `state`、`positions`、`forcedBets`。每笔强制注保留类型、座位、名义金额及实际支付金额。
- `ante` 为等额每人前注，默认 0；它计入累计投入，不计入本街已下注额。录像的 0.2 不会自动被当成前注。
- 仅实现一档 UTG live straddle；不接受双人第三盲，不声称支持 Mississippi、按钮 straddle、多档 straddle 或不规则补盲。

`TableState` 的旧初始化参数不变，末尾新增可选 `preflopMinimum: Int? = nil`。旧 JSON 缺失该字段仍可解码。`bigBlind` 永远是传统大盲；新增 `minimumBet` 在翻前取明确的名义开价，翻后恢复 `bigBlind`。`applying`、`advancing`、`PotSettlement` 的调用接口保持兼容。

## 行动顺序与金额

普通多人桌从大盲下一位行动；单挑庄家为小盲，翻前先行动、翻后后行动。存在 UTG 第三盲时，翻前从第三盲下一位开始，第三盲保留最后的过牌/加注选项。强制下注本身不算已经行动。

以 8 人、20/50/100、庄家索引 0 为例：小盲 1、大盲 2、第三盲 3，翻前顺序 `[4,5,6,7,0,1,2,3]`，底池 170，最小加注到 200。所有人跟入后，第三盲仍有选项。翻牌从庄家下一位开始，最小下注回到 50，而不是永久沿用 100。

原录像 `0018` 的顺时针映射为 `[顶部,右上,右中,右下,本人,左下,左中,左上]`。庄家位 3，重放前五人弃牌后本人位 4 行动，本街已投 20、跟注需补 80、底池 170、最小加到 200；180 无效，230 有效。测试直接重放了这条行动链。

## 短筹码和边池

- 普通短大盲仍有名义翻前开价；若有多个有筹码玩家，不能把短大盲支付的 30 自动改成全桌的大盲 30。
- 若只剩本人有筹码，其他玩家已全下，则只补足实际在场的最大下注；不会为了名义 50 去追不存在的筹码，也不会制造无意义的盲注选项。
- 可选 live straddle 不足额时拒绝创建，要求调用者明确桌规；`.mandatory` 明确表示强制第三盲，其短筹码可以全下而名义开价保留。**该短强制第三盲规则是配置契约，不是从现有 WPK 录像证明的特殊桌规。**
- 单次不完整全下加注不重新开放已经行动者的加注权；累计增量达到最近完整加注额时重新开放。
- 修复旧实现的短开池错误：翻后大盲 10，先有人全下 5，下一次完整加注至少到 15，不能用限注的“补到 10”方式处理无上限德州。
- 只有仍能在当前下注额之上投入的对手存在时才允许加注。
- 具有相同获胜资格的相邻筹码层合并成同一个主池/边池；单人未获跟注部分单列退款。弃牌玩家的已投入仍是死钱，不取得获胜资格。

原录像 `0186` 的反事实核对，内部单位为 0.01：本人加到 2100，一人跟入、另一人弃牌，得到主池 **3716**、边池 **1956**，总计 **5672**；1122 全下者仅有主池资格。若两人都弃牌，未获跟注的 **978** 退回本人，仍要与全下者争夺 **2874**。

## PokerKit 独立核对

已将固定版本 **PokerKit 0.7.4** 安装到工作目录 `work/pokerkit-oracle` 并实际执行，不是只看文档。官方将盲注/straddle 与 ante 分开，允许逐街指定起始行动和最小下注；状态接口按 raise-to 接收目标额，并维护边池资格。[官方模拟说明](https://pokerkit.readthedocs.io/en/stable/simulation.html)、[状态源码](https://raw.githubusercontent.com/uoftcprg/pokerkit/main/pokerkit/state.py)

实际发现：通用 `NoLimitTexasHoldem(blinds=(20,50,100), min_bet=50)` 给出的首次最小加注是 150，不能直接作为本录像的 live-straddle 桌规。审计脚本显式设置第 0 街最小增量 100、后续街 50，才得到翻前 200、翻后 50。短盲的名义开价策略也没有假装被这一通用配置自动证明。

独立核对脚本：[audit_game_rules_pokerkit.py](../tools/audit_game_rules_pokerkit.py)。本地结果保存在 `reports/game-rules-pokerkit-audit.json`，运行报告不随源码发布。共 **11 项断言组通过**：完整第三盲、盲位选项、换街恢复大盲、前注分离、短开池最小加注、一次/累计短加注是否重新开放，以及真实录像金额的边池/退款。

短全下重开规则同时参考 TDA 的第 47 条；最低下注以下的全下开池与后续完整加注，参考其官方论坛给出的无上限规则例子。[TDA 规则](https://www.pokertda.com/view-poker-tda-rules/)、[短大盲与短开池例子](https://www.pokertda.com/forum/index.php?topic=1040.0)

## 本地测试结果

2026-09-16 04:08:32，独立 release scratch：

- `PokerGameRulesTests`：**16 项通过**。
- 原 `BettingTests`：**6 项通过**；其中旧短开池期望 10 改为经独立规则核对的 15。
- 合计 **22 项，0 失败**。含 200 手固定随机种子的完整多人牌局，覆盖第三盲、短筹码、前注、换街、合法动作终止及最终筹码守恒。
- 日志：工作区 `work/game-rules-final-tests.log`、`work/game-rules-pokerkit.log`。

本轮没有修改 `Decision.swift`、Capture 或 `CoachModel`。完整应用构建和实时牌谱接入由主任务继续执行；以上测试只证明规则和筹码处理，不等于策略强度或真机识别通过。
