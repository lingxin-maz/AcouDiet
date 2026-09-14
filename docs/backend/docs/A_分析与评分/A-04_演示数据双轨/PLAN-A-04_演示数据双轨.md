# PLAN-A-04 演示数据双轨

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-A-04 |
| 负责 | **B（主责：导入器、清除、幂等与缓存刷新）** + **C（协助：数据集构造、标识文案、一致性验证）** |
| 目标日 | **D8**（Track 1 数据自 D6 起累积至 D9 上午截止；D9 判轨） |
| 前置依赖 | `PLAN-D-01`（`diet_record.source` 列）、`PLAN-D-02`（`insertSession`/`deleteById`/`app_meta`）、`PLAN-D-03`（按 `source` 过滤的聚合）、`PLAN-A-01`/`A-02`/`A-03`（被验对象）、`PLAN-C-05`（一致性回归套件）、`PLAN-U-01`/`U-03`/`U-04`/`U-05`（标识落点）、`PLAN-M-03`（Demo Mode C） |
| 预估工时 | **6 人时**（0.75 人日；B 4 h + C 2 h） |

## 1. 交付物（Deliverables）

> 逐项列出**文件路径级**的产物，能点开验收。

| # | 产物 | 验收方式 |
|---|---|---|
| 1 | `app/assets/demo_dataset.json` | 20–30 条、§4 字段齐全、无预计算分数与展示字段 |
| 2 | `docs/common/docs_api/schemas/demo_dataset.schema.json`（见 `SPEC-A-04 §10` OQ-A04-4） | JSON Schema draft-07 校验通过 |
| 3 | `app/lib/demo/demo_dataset_loader.dart` | 解析 + 逐条校验 + 锚点物化（唯一读时钟处） |
| 4 | `app/lib/demo/demo_data_controller.dart` | `loadDemoDataset`（先清后写）/ `clearDemoDataset` / `isDemoActive`（同步 getter + 缓存刷新） |
| 5 | `app/lib/demo/demo_labels.dart` | 标识文案常量（A-04-K3 单一来源） |
| 6 | `app/test/data/demo_dataset_schema_test.dart` | 结构、条数、类别同序、速度自洽、禁字段 |
| 7 | `app/test/data/demo_data_controller_test.dart` | 加载/清除幂等、`real` 行隔离、指标行 1:1、两次导入分数相等 |
| 8 | `app/test/ui/demo_banner_widget_test.dart` | 四页面标识可见与清除后消失 |
| 9 | `app/test/domain/demo_track_consistency_test.dart` | **核心验收 + PLAN-C-05 跨功能一致性（`SPEC-C-05 §5` #2 权威测试名）** |
| 10 | `docs/evidence/PLAN-A-04_Track1累积.md` | D6–D9 每天每人真实检测次数、总数与判轨结论 |
| 11 | `docs/evidence/PLAN-A-04_演示数据自检.md` | 逐条贴命令与输出 |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 构造并校验 25 条数据集（覆盖 7 天 × 3–4 餐；`speedGrade` 按 `FF-21e` 自洽） | 交付物 1、2 | 1.5 h（C） | OQ-A04-4/5 |
| 2 | 实现加载器：解析、逐条校验、锚点与时间物化、`attribute` 快照 | 交付物 3 | 1.5 h（B） | 任务 1；`foods.json` |
| 3 | 实现控制器：先清后写、`byRange`+`deleteById` 清除、`isDemoActive` 缓存 | 交付物 4、5 | 1.0 h（B） | `PLAN-D-02` |
| 4 | 标识文案 + `U-01`/`U-03`/`U-04`/`U-05` 四页落点联调 | 交付物 5、8 | 0.5 h（C） | `PLAN-U-*` |
| 5 | 写一致性测试（含独立公式交叉验证）与 Track 1 证据 | 交付物 9、10、11 | 1.5 h（B+C） | 任务 2、3；`PLAN-A-01`~`A-03` |
| 6 | Track 1 每日累积记录（D6–D9 上午，全队） | 交付物 10 | 含在各自日常（非额外工时） | — |

## 3. 技术方案

> 实现路径、关键代码骨架、算法步骤。**必须与 SPEC 的契约一致，不得另立参数。**

**分层**：`demo_dataset_loader`（纯解析 + 校验 + 锚点物化）→ `demo_data_controller`（写入/清除与状态缓存）。控制器**不含**聚合与评分逻辑；一致性测试直接调用 `SPEC-A-01`~`A-03` 的服务。**清除只允许使用 `API-03 §4` 的冻结方法**，不得新增 `DietRepo` 方法（`API-04 §9` OQ-6）。

```dart
// demo_data_controller.dart —— 状态由「库内是否存在 source=='demo' 行」承载（API-04 §6）
class DemoDataController {
  bool? _cachedActive;                                  // 同步 getter 只读缓存
  bool get isDemoActive => _cachedActive ?? false;

  Future<void> loadDemoDataset() async {
    final rows = await loadAndValidateDemoDataset(_assets);   // 校验失败抛 ACD-DEMO-002，零写入
    await _deleteDemoRows();                                  // A-04-K6 先清后写（幂等）
    final anchorMs = _localMidnightOf(DateTime.now());         // A-04-K5：唯一一次读时钟
    try {
      for (final r in rows.materialize(anchorMs)) {
        await _dietRepo.insertSession(record: r.record, metrics: r.metrics); // 1+1 行单事务
      }
      await _meta.put('demo_data_enabled', '1', DateTime.now().millisecondsSinceEpoch);
      await _meta.put('demo_dataset_id', rows.datasetId, DateTime.now().millisecondsSinceEpoch);
      _cachedActive = true;
    } catch (e) {
      await _deleteDemoRows();                                // A-04-K7 失败清理，不留半套数据
      rethrow;
    }
  }

  Future<void> clearDemoDataset() async {
    await _deleteDemoRows();                                  // 无 demo 行时自然 no-op，不抛错
    await _meta.put('demo_data_enabled', '0', DateTime.now().millisecondsSinceEpoch);
    await _meta.put('demo_dataset_id', '', DateTime.now().millisecondsSinceEpoch);
    _cachedActive = false;
  }

  Future<void> _deleteDemoRows() async {                      // 冻结方法组合，禁止新增 Repo 方法
    final all = await _dietRepo.byRange(DateRange(startMs: 0, endMs: kMaxEpochMs));
    for (final r in all.where((r) => r.source == 'demo')) {
      await _dietRepo.deleteById(r.recordId);                 // 指标行级联删除
    }
  }
}
```

**实现要点**：
1. `source` 必须**显式**写 `'demo'`，禁止依赖列默认值（默认值会让真实记录被误判）。
2. 每条演示记录必须经 `insertSession` 配对 1 行 `behavior_metrics`（可为占位行），**不得缺行**（`API-03 §2.3`）。
3. 锚点与时间物化用**本地日历算术**（`DateTime(y,m,d)`），不用毫秒相减，避免夏令时偏移。
4. `isDemoActive` 为同步 getter + 缓存；页面进入时刷新一次，**不得**在 getter 内查询。
5. 标识文案只从 `demo_labels.dart` 取；四个页面共用，代码审查禁止内联字符串。
6. `attribute` 由加载器从 `foods.json` 快照写入（`API-03 §2.1`），数据集本身不含该字段。

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `demo_dataset_schema_test.dart` | 单元 | 条数 20–30；字段齐全；`dayOffset` 覆盖 0–6；`classId`/`classLabel` 同序；`speedGrade` 按 `FF-21e` 自洽；禁字段命中 0 | 数据集每次改动后 |
| `demo_data_controller_test.dart` | 单元（内存库） | 先清后写幂等；`real` 行不受影响；指标行 1:1；两次导入分数逐字段相等 | 提交前 |
| `demo_banner_widget_test.dart` | Widget | 四页面标识可见；清除后消失 | D8、D9 |
| `demo_track_consistency_test.dart` | **跨功能（PLAN-C-05）** | 评分/周报/建议三路输出与 UI presenter 逐字段相等，且与测试内独立公式实现相等 | D8、D9 前必跑 |
| `tx_atomicity_test.dart` | 单元 | 无孤儿 `behavior_metrics` 行（`SPEC-C-05 §5` #11） | D5、D8 |
| `flutter test` 全量 | 回归 | 退出码 0 | D8、D9 |

## 5. 完成定义（DoD）

> 逐条可勾选；必须至少包含「对应 SPEC 第 7 节全部判据通过」。

- [ ] `SPEC-A-04 §7` 全部 12 条判据通过（贴命令与输出到交付物 11）。
- [ ] `diet_record.source` 已由 `PLAN-D-01`/`PLAN-D-02` 落地，且**无列默认值**（硬前置，见 §6）。
- [ ] 一键加载 → 报告页数字自洽 → 一键清除 → 四页面标识消失，全流程在真机上各截图一张。
- [ ] `demo_dataset.json` 与 `SPEC-A-04 §4` 字段表逐字一致，`note` 字段说明数据来源。
- [ ] 清除路径未新增任何 `DietRepo`/`DAO` 方法（对照 `API-03 §4`/`§3.1` 逐方法核对）。
- [ ] 一致性测试在**当前生效数据集**（Track 1 或 Track 2）上通过，并在证据中注明用的是哪条轨。
- [ ] Track 1 累积证据（交付物 10）在 D9 上午完成统计并给出判轨结论。
- [ ] 隐私确认已留痕（若使用团队成员真实饮食数据）。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `source` 列缺失或带默认值 | D6 检查 `SPEC-D-01` 仍无该列 / 列为 `DEFAULT 'real'` | **阻断本 PLAN**：升级到 D6 站会立即补列并去掉默认值（1 小时内可完成）；**不得**用「按时间戳猜测演示数据」的替代方案 |
| 导入非原子（OQ-A04-2） | 写入中途崩溃后残留半套 demo 行 | 靠 A-04-K7 的失败清理补偿；自检面板增加「demo 行数与数据集条数不一致」检查项 |
| 数据集构造时间不足 | D8 中午仍无 25 条 | 用合成数据（仍须通过全部校验与一致性测试），并在 `note` 与 PPT 中**如实标注为合成演示数据** |
| Track 1 累积 < 20 条 | D9 上午统计 | 启用 Track 2（CP4 规定动作）；PPT 如实说明数据来源 |
| 演示数据污染真实档案分数 | 报告页分数与真实用量不符（`SPEC-D-03 §10` #2 已预警：冻结签名无 `source` 参数） | 按 `API-00 §3.9` 走变更单给 `StatsRepo` 四个方法加可选 `source` 参数；A 域不得私加过滤条件绕开 |
| 现场忘记清除演示数据 | 演示后库内仍为 demo 轨 | 设置页常驻清除入口 + 顶部标识常显；列入 `PLAN-M-04` 自检项 |
| 有人要求「顺手」加 CSV 导出或上传 | 代码审查发现导出/网络调用 | 立即移除（`X-03`、`FF-24`、`API-05 §9` `DISABLED`） |
| 一致性测试与环境耦合（真机时间/时区） | 测试在不同时区失败 | 测试固定注入锚点（A-04-K5 支持显式传入），不依赖真机时钟 |

## 7. 与检查点的关系

> 本功能是哪个 CP 的组成部分，未完成时 CP 如何处置。

- 本功能是 **CP4（D7 晚）** 规定的**兜底动作**：CP4 未过 → 立即启用 Track 2 预置数据集，放弃真实累积（`PLAN-00 §2`）。
- 同时是 **CP3（D9 午「三种 Demo 模式全部可用」）** 中 `M-03`（Demo Mode C 报告演示）的**唯一数据源**：本功能不可用时 Mode C 不成立，只能演示 A+B 两种模式，须在 PPT「后续工作」中如实登记。
- 属主方案 §8.2.1 第 ⑤ 项「不可砍」范围（三种 Demo 模式）；**不得以静态截图/录屏替代真实数据链路**。
- D9 判轨动作（Track 1 vs Track 2）的结论必须写进交付物 10，作为答辩「这些数据怎么来的」的直接证据（主方案 §9.1）。

**文档结束**
