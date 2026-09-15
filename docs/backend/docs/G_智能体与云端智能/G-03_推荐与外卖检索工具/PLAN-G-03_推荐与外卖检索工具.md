# PLAN-G-03 推荐与外卖检索工具

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-G-03 |
| 负责 | C |
| 目标日 | v2.0-第 8 日 |
| 前置依赖 | `PLAN-G-02` 的注册表与观察类型；`SPEC-A-01`~`SPEC-A-03`/`SPEC-D-03` 已交付；`shared/feature_config.json` 的 `platforms` 段（三平台 + `verifiedOn`）；`. D:\Desktop\Food\_toolchain\acoudiet-env.ps1` 已激活 |
| 预估工时 | 18 人时 |

## 1. 交付物（Deliverables）

| # | 路径（前缀 `app/lib/domain/agent/tools/`，除注明外） | 内容 |
|---|---|---|
| 1 | `get_health_summary_tool.dart` / `get_recent_meals_tool.dart` / `recommend_food_tool.dart` | 只读 `HealthScoreService`/`StatsRepo`、`DietRepo.byRange`（四字段）、`AdviceEngine.generate`（`text` 逐字复用） |
| 2 | `propose_takeout_search_tool.dart` / `takeout_keyword.dart` / `platform_table.dart` | 卡片构造且 `proposalOnly == true`；`G-03-K1` 码点截断；平台表三平台校验 |
| 3 | `shared/feature_config.json`、`app/assets/feature_config.json`、`app/lib/core/feature_config.g.dart` | `platforms` 段（经 `tool/gen_feature_config.dart` 同步） |
| 4 | `app/tool/agent_tests.dart` / `app/tool/probe_takeout_urls.dart` | 追加 `SPEC-G-03` §7 #1–#15 的断言与负控；探针打印各核实状态下的产出卡片 |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | `platforms` 段落 + 常量生成 + 平台表读取与三平台校验 | 交付物 2、3 | 4h | `API-07` §3.3 |
| 2 | `get_health_summary`（`today` 用 `scoreWindowFor`，`week` 用 7 本地日）与 `get_recent_meals`（尾部 `limit` 条、四字段） | 交付物 1 | 5h | `API-04` §3/§5、`API-03` §4 |
| 3 | `recommend_food`（`text` 逐字复用、`avoid` 过滤） | 交付物 1 | 3h | `API-04` §4 |
| 4 | 关键词构造与码点截断 | 交付物 2 | 2h | `FF-19` |
| 5 | 卡片构造 + URL 展开 + 平台过滤/诚实标注 | 交付物 2 | 3h | 1、4 |
| 6 | 套件断言与逐条负控 + 探针与真机核实写回 `verifiedOn` | 交付物 4 | 4h | 2–5 |

## 3. 技术方案

```dart
// get_health_summary_tool.dart —— 单日窗口不可用于总分
final range = args['range'] == 'week' ? DateRange.of(TimeUtil.lastLocalDays(7))
    : ReportService.scoreWindowFor(TimeUtil.startOfLocalDay(nowMs));
final score = await health.score(range: range);   // API-04 §3
final agg   = await stats.summary(range);         // API-03 §5
// get_recent_meals_tool.dart —— FF-26d 白名单四字段，无热量字段
final rows = await db.byRange(DateRange.of(TimeUtil.lastLocalDays(recentLookbackDays)));
final tail = rows.length > limit ? rows.sublist(rows.length - limit) : rows;
final meals = tail.map((r) => <String, Object?>{'classId': r.classId,
    'classLabel': kB.labelOf(r.classId), 'eatenAtMs': r.eatenAtMs,
    'confidence': r.confidence}).toList();        // 占位指标行 -> null
// takeout_keyword.dart（G-03-K1 冻结于此）：normalize -> [dish, anchor].join(' ')
static const int maxRunes = 32;                   // 超限按 runes 截断，不加省略号
// propose_takeout_search_tool.dart（永不启动）：proposalOnly == true（FF-26i）
for (final p in platformTable.declaredOrder) {
  if (!p.enabled) { skipped.add(p.id); continue; }
  final url = p.template.replaceAll('{q}', Uri.encodeComponent(kw));
  if (!p.template.contains('{q}') || !_sameHost(url, p.template)) {
    invalid.add(p.id); continue; }
  cards.add({'platformId': p.id, 'label': p.label, 'url': url,
             'verified': p.verifiedOn != null, 'keyword': kw}); }
```

**纪律**：本层不 import `dart:io`/`dart:ui`/`package:flutter`；没有任何启动函数（`startActivity`/`MethodChannel`/`url_launcher` 一律不出现）；关键词只有两个来源（用户本轮消息 + 本地推荐），**不接受**第三个；`SPEC-U-07` 只能填数值槽位（`API-07` §4.3）。

## 4. 测试与验证

| 测试 | 类型 | 断言（映射 `SPEC-G-03` §7） | 何时跑 |
|---|---|---|---|
| `meituan url encodes the keyword` / `platforms are exactly meituan, eleme, taobao` | 单元（零网络） | #1 URL 逐字等于期望、解码还原等于关键词；#2 id 集合长度 == 3。负控：去 `Uri.encodeComponent`／加第四平台，各自变红 | `agent_tests.dart` |
| `disabled platform is not offered` / `unverified platform is reported as unverified` | 单元 | #3 `cards` 无该 id 且在 `skipped`（负控忽略 `enabled` 即红）；#4 `verifiedOn == null` → `verified == false`（负控硬编码 `true` 即红） | 同上 |
| `tools never launch an external app` / `no AccessibilityService anywhere` | 静态 | #5 `MethodChannel`/`startActivity`/`url_launcher`/`HttpClient` 命中 0；#6 全仓 `AccessibilityService` 命中 0（负控加桩即红） | `verify_all.ps1` |
| `observation fields stay inside the egress whitelist` | 单元 | #7 键 ⊆ `FF-26d`，`meals[]` 键集恰四字段；负控补 `estimatedKcal` 即红 | `agent_tests.dart` |
| `keyword is capped and stable` | 单元 | #8 64 码点 → ≤ `G-03-K1`；100 次逐字相同；无省略号 | 同上 |
| `tools reuse the domain services verbatim` / `keyword derives only from the user turn and local advice` | 单元 | #9 分数逐字段等于服务输出、`text` 逐字相等（负控自算总分即红）；#10 可还原为 `[dish, anchor]`（负控拼设备标识即红） | 同上 |
| `invalid template is reported not offered` / `empty keyword yields no card` | 单元 | #11 缺 `{q}`/host 不符/非 https 均不产出卡片（负控原样返回模板即红）；#12 `cards.length == 0` 且 `status == "error"` | 同上 |
| `card and summary strings avoid FF-25 terms` / `check_l4_usage.py --strict` / `check_network_boundary.py --strict` / 步骤清单 | 单元 + 静态 + 集成 | #14 命中 0（负控写入词表内一个词即红）；#13 两步 exit 0；#15 步骤数与 `SPEC-G-02` §7 #16 一致 | 同上 + `verify_all.ps1` |

## 5. 完成定义（DoD）

- [ ] `SPEC-G-03` §7 的 15 条判据全部通过，每条新闸门的负控**已实测变红**并留证。
- [ ] `pwsh -File tool/verify_all.ps1` exit `0` 且步骤数不变（与 `SPEC-G-02` 共用同一步骤）；`feature_config.agent` 恰为三个平台，`verifiedOn` 逐条写回**真机核实日期**，未核实的保持 `null` 且被如实标注。
- [ ] `app/lib/domain/agent/tools/**` 无 `package:flutter`/`MethodChannel`/`HttpClient`/`url_launcher`/`AccessibilityService`；`get_recent_meals` 输出键集恰四字段（含热量字段即视为未完成）。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 平台模板真机打不开（饿了么 H5 入口已在阿里体系内改道） | 真机点击落到首页或跨域跳转 | 把该平台 `enabled` 置 `false`（**只改配置、不改代码**，`API-07` §3.3），UI 不显示；不得以「可能打不开」掩盖 |
| 现场只剩一个平台可用 | `enabled == true` 的平台数 ≤ 1 | 卡片数自然为 1；`SPEC-U-07` 不得伪造第二张卡片；答辩材料如实说明核实状态 |
| 全部平台禁用 → 0 张卡片与 `API-07` §4.1 的「1..3」冲突／关键词命中不到类别名／负控无法变红 | `cards.length == 0` 分支被触发；`dish` 为空串；删掉判据后套件仍绿 | 0 张卡片按 `SPEC-G-03` §10 OQ-G03-1 取「允许 0 张 + `warning`」，与 `API-07` 表述对齐后回填；关键词退化为仅用户消息（§2.2.1 已定义），不编造类别；负控不变红的闸门视为**未完成** |

## 7. 与检查点的关系

- 本功能是 v2.0 **Agent 链路闸门**的组成部分，与 `SPEC-G-01`/`SPEC-G-02` 同批验收；三者齐备后 `SPEC-U-07` 方可开工。未完成时 `propose_takeout_search` 整体**不注册**（注册表退为三个只读工具），**严禁**用一张死链卡片充数；平台可用性不达标不阻断核心链路（`FF-26f`）。

**文档结束**
