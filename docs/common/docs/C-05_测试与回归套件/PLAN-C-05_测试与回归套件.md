# PLAN-C-05 测试与回归套件

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-C-05`（不可裁剪） |
| 负责 | A+B（A 主责 Python 侧与对齐门禁；B 主责 Dart/仪器测试与隐私回归；C 协助演示前清单与报告归档） |
| 目标日 | **D3→D9**（D3 起建套件，D5/D8 节点日跑全集合，D9 前完成演示前回归） |
| 前置依赖 | `PLAN-T-02` 划分产物；`PLAN-T-08` 对齐脚本；`PLAN-A-01` 评分服务；`PLAN-D-05` 清理逻辑；真机可用；**测试命令须在沙箱外普通终端执行** |
| 预估工时 | 10 h（A 4 h + B 4.5 h + C 1.5 h） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/test/domain/health_score_consistency_test.dart` | 评分卡数字 == UI 数字（判据 #2）；含 `FF-22` 字面表达式求值顺序断言与比值 `0.30` 的回归用例（见 §3） |
| 2 | `app/test/domain/score_reproducibility_test.dart` | 评分纯函数可复现（判据 #2） |
| 3 | `app/test/ui/score_card_render_test.dart` | 渲染值 == 服务值（按 `API-05` §6.2 舍入口径） |
| 4 | `app/test/cfg/mel_layout_test.dart` | 行主序布局（判据 #4） |
| 5 | `app/integration_test/cache_cleanup_test.dart` | `audio_*` 零残留（判据 #6，真机） |
| 6 | `app/integration_test/demo_selfcheck_test.dart` | 自检面板 4 项全绿（判据 #9 / 附表 A #3） |
| 7 | `app/test/data/tx_atomicity_test.dart` | 无孤儿行为指标行（判据 #7） |
| 8 | `app/test/data/db_schema_no_blob_test.dart` | schema 无 BLOB 音频列（判据 #6） |
| 9 | `ai/scripts/test_split_no_leak.py` | 划分无泄漏（判据 #3） |
| 10 | `ai/scripts/test_split_withdrawn_excluded.py` | 撤回归档剔除（判据 #3） |
| 11 | `ai/scripts/test_dataset_shape.py` | 数据集形状与 SSOT 一致（判据 #4 前置） |
| 12 | `ai/scripts/test_mel_crosslang.py` | Mel 跨语言对齐门禁（判据 #4） |
| 13 | `ai/scripts/parity_test.py` | parity 门禁（判据 #5；`SPEC-T-08` 的实现载体） |
| 14 | `records/compliance/C-05/<节点>_<YYYYMMDD>_<套件>.txt` | 全集合运行输出与判读结论（字段见 `SPEC-C-05` §4.2） |
| 15 | `records/compliance/C-05/pre_demo_checklist_<YYYYMMDD>.md` | 附表 A + 附表 B 的现场打勾件 |

> 交付物 #1~#13 为**测试实现文件**，本 PLAN 只登记路径与断言；实现由 A/B 在各自分支完成。

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 搭目录与命名规范（`app/test/`、`app/integration_test/`、`ai/scripts/`） | 规范落文 + 空套件可跑 | 1 h | — |
| 2 | 划分无泄漏与撤回剔除断言 | 交付物 #9 #10 | 2 h | `PLAN-T-02` |
| 3 | dataset 形状与 Mel 跨语言断言 | 交付物 #11 #12 | 2 h | `PLAN-P-04`、`PLAN-T-08` |
| 4 | parity 门禁脚本接入（D4 硬闸门） | 交付物 #13 | 1 h | `PLAN-T-07` |
| 5 | 一致性与可复现性测试（含渲染口径） | 交付物 #1 #2 #3 | 2 h | `PLAN-A-01`、`PLAN-A-04` |
| 6 | 隐私回归三项（真机清理、schema、权限） | 交付物 #5 #8、命令 | 1.5 h | `PLAN-D-05`、`PLAN-C-01` |
| 7 | 事务一致性与自检面板冒烟 | 交付物 #6 #7 | 1 h | `PLAN-D-02`、`PLAN-M-04` |
| 8 | 演示前回归 + 30 分钟清单演练与归档 | 交付物 #14 #15 | 0.5 h | #5 #6 #7 |

## 3. 技术方案

**运行矩阵（按节点取集合）**：

| 节点 | 集合 | 命令 |
|---|---|---|
| 提交前 | 快集合（单元 + pytest 单测 + 命令级搜索） | `flutter test`；`python -m pytest ai/scripts -q` |
| D1 | 划分断言 | `python -m pytest ai/scripts/test_split_no_leak.py ai/scripts/test_split_withdrawn_excluded.py -q` |
| D3 | Mel 跨语言门禁 | `python -m pytest ai/scripts/test_mel_crosslang.py -q` |
| D4 | parity 门禁 + 权限复核 | `python ai/scripts/parity_test.py --n 50`；`SPEC-C-01` §7 #1/#2 命令 |
| D5 / D8 | 一致性 + 事务 + 清理 | `flutter test`；`flutter test integration_test/cache_cleanup_test.dart` |
| D9 前 | 全集合 + 附表 A/B | 上述全部 + 人工核对表 |

**取证骨架（PowerShell，≤30 行；`flutter`/`pytest` 在沙箱外普通终端执行）**：

```powershell
. D:\Desktop\Food\_toolchain\acoudiet-env.ps1
$out = 'docs\compliance\C-05'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$stamp = Get-Date -Format yyyyMMdd
flutter test 2>&1 | Tee-Object "$out\precommit_${stamp}_flutter_test.txt"
python -m pytest ai/scripts -q 2>&1 | Tee-Object "$out\precommit_${stamp}_pytest.txt"
# 失败即阻塞：任一套件非零退出码则不发车
if ($LASTEXITCODE -ne 0) { Write-Error 'GATE_FAIL: 提交前集合未通过' }
# 门禁判读（SPEC-C-05 §4.2）
Select-String -Path "$out\*_${stamp}_*.txt" -Pattern 'failed|FAILED|Error:'
# 隐私回归三项
rg -n --glob '!**/build/**' -e 'http' -e 'dio' -e 'socket' -e 'WebSocket' -e 'url_launcher' `
  app\lib app\android\app\src app\pubspec.yaml | Tee-Object "$out\privacy_scan_${stamp}.txt"  # 期望 0 命中
```

**禁令（写进团队协作规则）**：①不得用 `skip:` 绕过失败；②不得为让测试变绿而放宽阈值；③不得在两处重复实现同一断言；④测试代码不得复制 SSOT 的字面值。

**评分公式的求值顺序（`FF-22`；约束 `health_score_consistency_test.dart`）**

> `FF-22` 的四维公式必须按**字面表达式**求值 —— `structure = 30 × min(1, p / 0.4)` 即「先算 `p / 0.4` → 再取 `min` → 最后乘 30」；**不得做代数重排**（如 `30 × p / 0.4`）。二者在 IEEE-754 下**不等价**：`30 * min(1, 0.30/0.4)` = `22.499999999999996 → 22`，而 `30 * 0.30/0.4` = `22.5 → 23`。**最后一个 ULP 会改变 `round()` 的结果**，直接使域层分数与 UI 显示数字不一致（判据 #2 的差异字段数从 0 变为非 0）。

`health_score_consistency_test.dart` 必须做到：

| # | 要求 | 说明 |
|---|---|---|
| 1 | 对 `regularity` / `structure` / `snack` / `speed` **四维各断言一次**「实现求值 == 按 `FF-22` 字面表达式求值」 | 断言写成「同一输入的两种写法必须相等」，而不是只断言一个期望整数 —— 后者会在实现重排后仍然通过 |
| 2 | 夹具的比值取**浮点安全值**（如 `{0.10, 0.20, 0.25, 1.00}`） | **避开** `p / 0.4` 恰为半值的组合（如 `0.30`），否则夹具本身就在 ULP 边界上 |
| 3 | 保留一条**回归用例**，固定记录比值 `0.30` 在**字面表达式**下应得 **22** | `30 × min(1, 0.30/0.4) → 22`；若实现改为 `30 × p / 0.4` 得 23，该用例必须失败。这条用例是求值顺序的**唯一机械守卫** |

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| 提交前快集合 | 命令 | `failed == 0`；`skipped` 非 0 须登记 | 每次提交前 |
| 划分无泄漏 | 单元（pytest） | 主体级交集为空、无重复原始文件 | D1、每次重划 |
| Mel 跨语言 | 单元（pytest） | `atol < 1e-3` | D3（门禁）、D4 |
| parity | 单元（pytest） | 标签一致率 ≥0.98；置信度偏差 ≤0.05 | D4（门禁）、D8 |
| 评分一致性 | 单元（Dart） | 四维与总分逐字段等于 UI 显示值；四维各断言「实现求值 == `FF-22` 字面表达式求值」；比值 `0.30` 的回归用例恒得 **22** | 提交前、D5、D8、D9 前 |
| 评分可复现 | 单元（Dart） | 两次运行逐字段相等 | 提交前、D8 |
| 事务一致性 | 单元（Dart） | 无孤儿行为指标行 | D5、D8 |
| 隐私回归三项 | 仪器 + 命令 | 残留 0 / 无 BLOB / 无网络权限 | D8、D9 前、D10 |
| 自检面板冒烟 | 仪器 | 4 项全绿 | D9 前每次演练 |
| 演示前回归（附表 A） | 人工核对表 | 5 项全勾 | CP3 前 |
| 30 分钟检查清单（附表 B） | 人工核对表 | 8 项全勾 | 每次现场演练 |

## 5. 完成定义（DoD）

- [ ] `SPEC-C-05` 第 7 节 9 条判据 + 测试清单总表 15 行全部就位并可执行
- [ ] 三处目录与命名规范落文，空套件在干净检出上可跑通
- [ ] D3 Mel 对齐门禁与 D4 parity 门禁均通过并有归档输出
- [ ] 隐私回归三项在真机上至少跑通一次（`SPEC-C-05` §2.4）
- [ ] 一致性测试针对「当前生效数据集」，Track 1/2 切换后仍通过
- [ ] 全集合运行报告字段齐全（§4.2），存放于 `records/compliance/C-05/`
- [ ] 附表 A（5 项）与附表 B（8 项）在 D9 前完成一次完整演练并签字
- [ ] 团队协作规则四条禁令写入 README 或站会记录

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 测试不稳定（偶发失败） | 连跑 3 次结果不一致 | 定位时间依赖/随机种子/并发；**禁止靠重跑掩盖**；必要时暂时标记并登记 §10 |
| 一致性测试与 UI 不一致（**R-10**） | 判据 #2 失败 | **冻结 UI 修复数据或修评分服务**，不得改断言；优先保评分服务为唯一真源 |
| 对齐门禁差一点 | 判据 #4/#5 超阈值 | 按 `SPEC-T-08` 定位（内存布局、归一化、边界帧）；禁止放宽阈值 |
| 真机不可用 | `flutter devices` 为空 | 降级为单元 + 命令级；**D9 前必须补跑真机隐私回归**，否则 CP3 风险不可接受 |
| 套件跑得太慢被绕过 | 提交前集合超过站会间隔 | 拆分快/慢集合，慢集合移到节点日；不减少断言 |
| 阈值被要求放宽以"先过" | 评审或排期压力 | 拒绝；走 `SPEC-C-03` 变更流程并留下记录 |
| 排期压缩导致套件半成品 | D8 仍有未实现测试 | 优先保 ①一致性 ②划分 ③对齐 ④隐私四类（不可砍）；⑤演示前清单可降级为人工核对表 |

## 7. 与检查点的关系

| CP / 节点 | 关系 | 未完成时的处置 |
|---|---|---|
| D1 接口冻结 | 划分无泄漏断言是 `PLAN-T-02` 的验收条件 | 未过 → 不得进入 D2 训练（数据泄漏会让全部指标失真） |
| D3 | Mel 跨语言对齐是**硬闸门**（`SPEC-T-08`） | 未过 → 关键路径告警，触发 `PLAN-P-04` 的 Plan-S 评估 |
| D4 | parity 门禁是**硬闸门**，也是 `P-05` 集成的准入 | 未过 → 不集成 TFLite，不进入 D5 |
| **CP2**（D5 晚） | 端到端闭环 + 事务一致性 | 未过 → D6 全天扑联调，UI 与报告页砍到最简 |
| **CP3**（D9 午） | 演示前回归（附表 A）与 30 分钟清单（附表 B）是现场保命手段 | 未过 → 停止一切新功能，全员扑 Demo 稳定性 |
| **CP4**（D7 晚） | 一致性测试覆盖 Track 1/Track 2 双轨（R-10） | 未过 → 启用预置数据集并保留一致性断言 |
| D10 | 全集合报告归档为提交材料的一部分 | 未归档 → 材料不完整，按 `SPEC-C-05` §7 #9 判不通过 |

**文档结束**
