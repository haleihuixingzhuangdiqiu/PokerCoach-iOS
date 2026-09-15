# 公开源码与本地复现

这是面向 WebPcker／WPK 界面的研究源码快照。维护状态、使用定位以 README 为准；换主题、分辨率、按钮布局或桌规后需要自行适配和验证。

## 公开内容

包含 Swift 源码、测试、构建生成器、审核工具、示例牌局和必要的字形／空下注区特征。模板 JSON 保存裁剪后的特征及来源标记，不包含完整牌桌截图、头像或录屏。原图、视频、设备标识、安装记录、应用容器、录屏诊断、策略轨迹、签名材料、生成的 Xcode 工程、`work/` 与 `reports/` 不随仓库发布。文档中的历史本地报告路径是证据说明，不代表仓库附带这些文件。

## 不带私人素材时的测试

运行 `swift test -c release` 可以验证规则、概率、范围更新、状态机、模拟策略、合成图像和传输逻辑。依赖私人图像的用例发现素材缺失时使用 `XCTSkip`，**跳过不等于识别通过**。

涉及私人帧的测试分布在 `AceTemplateCoverageTests`、`GenuineFiveSixCoverageTests`、`RankGlyphIsolationTests`、`RankLearningIntegrationTests`、`ActionControlReaderTests`、`VisibleRaiseCaptureTests`、`SceneGateTests`、`HeroSettlementTests`、`EmptyBoardPresenceTests`、`TableSnapshotCaptureTests` 和 `StraddleCaptureRegressionTests`。这些类中的纯逻辑／合成图测试仍可运行。

通过环境变量接入自己持有的本地资料：

| 变量 | 含义 |
|---|---|
| `POKER_PRIVATE_FIXTURE_ROOT` | 私人素材根目录，其下为 `video-holdout/`、`video-hd/`、`card-confirm-audit/frames/`、`rank-coverage-fixtures/`、`rank-56-fixtures/` 等。 |
| `POKER_PRIVATE_SCREENSHOT_DIR` | 个别原始截图测试读取的目录；未设置时使用系统临时目录。 |
| `POKER_TEST_ARTIFACT_DIR` | 表格识别测试的输出目录；默认 `work/test-artifacts/`。 |
| `POKER_READER_ARTIFACT_DIR` | 可选的合成识牌图片输出目录。 |

未配置 `POKER_PRIVATE_FIXTURE_ROOT` 时保留原研究工作区的上两级 `work/` 路径兼容。公开检出建议显式配置；文件命名、固定牌面与哈希预期见对应测试。任意新截图不能直接替代原始回归素材，应另建标注和独立验证集。

`tools/check_card_regression.py` 要求标注文件中的全部 8 帧、每帧全部 7 个牌槽各出现一次；缺帧、重复、漏槽不能得到通过结果。没有原素材时，不应生成空观测来代替识别回归。

A 模板审计工具使用当前 23 项模板，不再要求回退到历史 21 项。先用当前源码重新编译，再执行：

```sh
mkdir -p work
swiftc -O Sources/PokerCoachCapture/RegionImaging.swift \
  Sources/PokerCoachCapture/RankTemplates.swift \
  Sources/PokerCoachCapture/CardRegionReader.swift \
  tools/audit_rank_coverage.swift -o work/rank-coverage-audit
work/rank-coverage-audit audit "$PWD"
python3 tools/check_rank_coverage.py
```

上述工具需要本地的原始 A 训练图、独立 A 验证图、历史 20 项基线及完整回归帧；素材路径沿用 `POKER_PRIVATE_FIXTURE_ROOT`。`audit` 写入 `comparison-current.json` 和源码／模板哈希清单，检查器拒绝旧 `comparison.json` 冒充当前验证。`train` 只生成 `wpk-rank-templates-candidate-a.json` 候选，保留现有 5/6，不写回生产资源。此工具只审核 A 的独立截图与同源回放；6 仍没有独立留出样本，不能把通过结果说成全牌泛化验证。

iOS 的私人补牌 UI 用例默认跳过；在 XCTest Scheme 的测试环境中设 `POKER_RUN_PRIVATE_UI_FIXTURES=1` 才启用，并需先向被测 App 的 `Documents/RankLearningFixture.png` 放入本地测试图。显式启用后若 App 无法读取牌样，该用例会失败，不能用跳过掩盖加载故障；公共首页／帮助 UI 用例不依赖此图。

## 自行签名与主题适配

生成工程时设置自己的 `POKER_DEVELOPMENT_TEAM` 和唯一的 `POKER_BUNDLE_ID`，再运行 `ruby iOS/generate_project.rb`。需要本地 Ruby `xcodeproj` 库、Xcode 和自己的开发者签名配置；录屏扩展自动使用主 Bundle ID 加 `.broadcast`。不要提交证书、私钥、描述文件或设备容器；原维护者的签名不能作为公开分发方式。

主题适配主要位于 `WPKVideoLayout`、`WPKActionControlReader`、`WPKTableSnapshotReader` 及 `Sources/PokerCoachCapture/Resources/`。修改归一化区域、视觉判定和模板后，应重新验证牌张、筹码小数点、按钮是否启用、遮挡、发牌动画和结算状态；未知字段保持未知。先用合成／本地回放验证，再验证真机 ReplayKit、后台和 PiP 生命周期。策略与完整状态前提见 [完整牌局策略](FULL-HAND-STRATEGY.md)。
