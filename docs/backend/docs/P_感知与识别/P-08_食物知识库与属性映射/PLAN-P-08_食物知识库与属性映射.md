# PLAN-P-08 食物知识库与属性映射

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-P-08 |
| 负责 | C（主责，D0 起草 → D1 定稿）；A 复核 `classId` 顺序与 `model_card` 一致性；B 复核加载路径与错误码 |
| 目标日 | D1 |
| 前置依赖 | **FF-19 类别表**（`SPEC-00` §3.3，唯一真源）；`docs/common/docs_api/schemas/foods.schema.json`；`PLAN-T-07` 的 `model_card` 中 `classId` 顺序（D4 产出，D1 暂以 FF-19 为准）；`PLAN-C-03` 的资产打包约定 |
| 预估工时 | 4 h |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `assets/foods.json` | 6 个顶层键（键名 = `label`），每键 9 字段（含 `icon`）——内容真源 |
| 2 | `docs/common/docs_api/schemas/foods.schema.json` | JSON Schema draft-07（`additionalProperties:false`，机器可校验） |
| 3 | `lib/domain/food_knowledge_base.dart` | `FoodInfo` / `FoodKnowledgeBase`（含 `all`，**签名不得改**） |
| 4 | `test/domain/food_kb_completeness_test.dart` | 键集合 == `class_labels` + FF-19 逐字一致 |
| 5 | `test/domain/food_kb_fields_test.dart` | 字段值域（`portionKcal > 0`、`portionDesc` 非空、标签非空、`icon` 存在） |
| 6 | `test/domain/food_kb_query_test.dart` | 查询、越界与未注册 → `ACD-KB-001`、`all` 只读 |
| 7 | `test/domain/food_kb_load_test.dart` | `load` 原子替换（失败保留旧表）与幂等 |
| 8 | `test/domain/kcal_render_template_test.dart` | 热量渲染模板（与份量 + 「估算」同现） |
| 9 | `ai/scripts/assert_kcal_not_isolated.py` | 孤立热量数字扫描 |
| 10 | `ai/scripts/assert_food_granularity.py` | 超能力命名黑名单 + 6 键计数扫描 |
| 11 | `ai/scripts/assert_no_medical_claims.py` | 医疗宣称词表扫描 |
| 12 | `docs/reports/p08_foods_kb.md` | 份量/热量的**引用来源**与文件体积实测记录 |
| 13 | `pubspec.yaml` 的 assets 声明（与 `PLAN-C-04` 对齐） | 打包配置 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 依据 FF-19 起草 6 个键的条目：`label`/`zhName`/`icon`/`attribute`/`category`/`portionDesc`/`portionKcal`/`nutritionTags`/`riskNote` | 交付物 1 | 1.5 h | FF-19 |
| 2 | 为每个份量与热量标注**可追溯来源** | 交付物 12 | 0.5 h | 1 |
| 3 | 编写 JSON Schema（`additionalProperties:false`） | 交付物 2 | 0.5 h | 1 |
| 4 | 实现 `FoodKnowledgeBase`（加载 + Schema 断言 + 键集合/label 断言 + 原子替换 + 错误码 + `all`） | 交付物 3 | 0.75 h | 3 |
| 5 | 单测：完整性 / 字段 / 查询 / 渲染模板 / 原子替换 | 交付物 4/5/6/7/8 | 0.5 h | 4 |
| 6 | 三个静态扫描脚本（热量孤立 / 粒度 / 医疗宣称） | 交付物 9/10/11 | 0.5 h | 1 |
| 7 | assets 打包声明 + 与 `T-07` 的类别顺序交叉核对 | 交付物 13 | 0.25 h | `PLAN-T-07`（D4 复核） |

**合计：4.5 h**，计入域 P 总工时（`PLAN-00` §5 中 P 域 52 h 的口径）。

## 3. 技术方案
**位置**：`assets/foods.json`（构建期打包，只读）→ **本功能（Dart 域层）** → `A-01`/`A-02`/`U-03`/`U-04`。

**关键骨架（≤30 行，仅示意结构）**：
```dart
class FoodKnowledgeBaseImpl implements FoodKnowledgeBase {
  late final Map<String, FoodInfo> _byLabel;      // 顶层键 → FoodInfo（键名 == label）
  late final List<FoodInfo> _byId;                // classId 顺序 = feature_config.class_labels

  @override
  Future<void> load({required String assetPath}) async {
    final raw = await rootBundle.loadString(assetPath);           // assets，无网络
    final json = jsonDecode(raw) as Map<String, dynamic>;
    validateAgainstSchema(json, 'docs/common/docs_api/schemas/foods.schema.json');  // 失败 → ACD-IO-002
    if (!setEquals(json.keys.toSet(), classLabels.toSet())) {
      throw AcdError('ACD-IO-002');                               // 6 键 == class_labels，FF-19
    }
    final next = <String, FoodInfo>{};
    for (final e in json.entries) {
      final f = FoodInfo.fromMap(e.key, e.value as Map<String, dynamic>);
      if (f.label != e.key) throw AcdError('ACD-IO-002');         // label == 键名
      next[e.key] = f;
    }
    _byLabel = next;                                              // 原子替换：失败保留旧表
    _byId = [for (final l in classLabels) next[l]!];
    assertNoIsolatedKcal(json); assertNoMedicalClaims(json);       // 运行时双保险
  }

  @override
  FoodInfo byClassId(int id) =>
      (id >= 0 && id < _byId.length) ? _byId[id] : throw AcdError('ACD-KB-001');

  @override
  FoodInfo byLabel(String label) =>
      _byLabel[label] ?? (throw AcdError('ACD-KB-001'));           // 不回退默认条目
}
```
**要点（按出错概率排序）**：
1. **类别真源是 FF-19**：顶层键集合必须**恰好等于** `feature_config.class_labels`（键名 = `label`），`label`/`zhName`/`attribute` 逐字一致，不得改写、不得新增、不得改序。`SPEC-00` §3.3 是唯一真源，本文档不复制第二份。
2. **禁止孤立热量数字**：热量只能由唯一模板 `「<portionDesc> · 估算 <portionKcal> kcal」` 渲染；禁止任何「只显示数字」的组件路径（渲染模板测试 + 静态扫描双保险）。
3. **禁止超能力命名**：`zhName`/`portionDesc`/`nutritionTags`/`riskNote`/`category` 都不得出现「全麦面条」「纯牛奶」「番茄」「鸡翅」「低脂」「有机」「无糖」等超出 6 类识别能力的词；扫描脚本在构建期拦截（`C-04` 不得出包）。
4. **错误码分两类**（`API-02` §6 / `API-04` §2.2）：加载与校验失败一律 `ACD-IO-002`；查询键非法（越界 / 未注册，含 `nuts`）一律 `ACD-KB-001`，**不得返回 `null`、不得回退默认条目**。
5. **`load` 原子替换 + 幂等**：校验失败保留旧表；重复调用结果相同。
6. **无网络**：知识库只来自 assets（FF-24 §4）；本功能不得引入任何 HTTP 客户端或营养 API。
7. `FoodInfo` 的 8 个字段是 UI 的唯一可见字段集；`icon` 仅 UI 使用、**不进 `FoodInfo`**；表外字段不许上 UI（`00_功能清单` §3）。
8. **知识库不落库**：仅 `attribute` 在写入记录时快照进 `diet_record.attribute`（`API-03` §2）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| JSON 可解析 | 命令 | `python -c "import json;json.load(open('assets/foods.json',encoding='utf-8'))"` 退出码 0 | D1 每次提交 |
| Schema 校验 | 命令 | `python -m jsonschema -i assets/foods.json docs/common/docs_api/schemas/foods.schema.json` 退出码 0 | D1 / D10 |
| `food_kb_completeness_test` | Dart 单测 | 顶层键集合 == `feature_config.class_labels`（6 个）；`label == 键名`；`zhName`/`attribute` 与 FF-19 逐字相等 | D1 |
| `food_kb_fields_test` | Dart 单测 | `portionKcal > 0`、`portionDesc` 非空、`nutritionTags` ≥ 1；每条含 `icon` | D1 |
| `food_kb_query_test` | Dart 单测 | 查询往返正确；越界 / 未注册（含 `nuts`）抛 `ACD-KB-001`；`all.length == 6` 且只读 | D1 |
| `food_kb_load_test` | Dart 单测 | 破坏 JSON → `ACD-IO-002` 且旧表仍可用；`load` 两次幂等 | D1 |
| `kcal_render_template_test` | Dart 单测 | 渲染输出匹配 `.*估算\s*\d+\s*kcal`，且必含 `portionDesc` | D1 |
| `assert_kcal_not_isolated.py` | 静态扫描 | 命中数 == 0 | D1 / D10 |
| `assert_food_granularity.py` | 静态扫描 | 黑名单命中数 == 0；顶层键数 == 6；无 `nuts` | D1 / D10 |
| `assert_no_medical_claims.py` | 静态扫描 | 命中数 == 0 | D1 / D10 |
| `label_mapping_test`（与 `PLAN-P-05` 共管） | Dart 单测 | KB 的 `label` 与模型侧 `classId→label` 映射全等 | D4（模型交付后） |
| `aapt dump badging` | 构建产物检查 | 无 `INTERNET` | D4 / D10 |

## 5. 完成定义（DoD）
- [ ] `SPEC-P-08` §7 全部 14 条判据通过（**必需项**；第 13 条在 D4 模型交付后复跑）。
- [ ] 交付物 1–12 全部存在且路径一致。
- [ ] **`API-02` §6 的 `FoodInfo` / `FoodKnowledgeBase`（含 `all`）签名逐字一致**；错误码只用 `ACD-IO-002`（加载/校验）与 `ACD-KB-001`（查询键），且二者已补登 `API-00` §3.5。
- [ ] **D1 硬验收**：`PLAN-00` §1 D1 行的「三方接口冻结」中，本功能的字段契约已冻结并以 `API-04` §2 为准。
- [ ] 顶层键集合 == `class_labels`；6 条记录的 `label`/`zhName`/`attribute` 与 FF-19 逐字一致。
- [ ] 每个 `portionKcal` 与 `portionDesc` 都有**可追溯来源**并写入 `docs/reports/p08_foods_kb.md`。
- [ ] 三个静态扫描脚本命中数全为 0，且已接入 `C-04` 的出包前置检查。
- [ ] 越界与未注册 label 查询抛 `ACD-KB-001`（不返回 `null`、不回退默认条目）；`load` 原子替换已测。
- [ ] 无网络依赖（无 HTTP 客户端、无营养 API）；知识库不写入 SQLite。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 份量/热量缺可追溯来源 | D1 报告中来源栏为空 | 只保留「标准份量描述」并以定性表述呈现（如「一小份」），**去除具体 `portionKcal` 数字**，UI 只显示份量描述；待来源补齐后恢复 |
| `category` 与 `A-01` 的 `structure` 维口径混用 | `PLAN-A-01` 联调时字段口径不符 | `API-04` §2.1 把 `category` 定位为**展示用次级标签**；`structure` 维只能按 FF-22 的 `cabbage + carrot + noodles` 计算，**不得**依赖 `category`（见 `SPEC-P-08` §10 第 1 条） |
| `riskNote` 文案与 `A-02` 重复 | 两处文案冲突 | `API-04` §2.1 已把 `riskNote` 定位为 `A-02` 的**引用素材**；`A-02` 只做组合与排序，不另写静态文案 |
| `icon` 字段归属不清 | `U-06` 与 P-08 互相等待 | `icon` 由 `U-06` 的图标资产负责填充；**不进 `FoodInfo`**，本功能只在 Schema 中保留字段位 |
| D1 时间不足（C 同时做设计系统 `U-06` 与自采） | D1 傍晚 Schema 未定 | 先交付 `foods.json` + 最小 Schema（保证 6 类字段齐全），三个扫描脚本推后到 D2 补 |
| 模型 `classId` 顺序与 FF-19 不符 | D4 `model_card` 核对发现 | **以 FF-19 为准**，回退 `T-07` 重导出（`classId` 顺序不可协商） |

## 7. 与检查点的关系
- 本功能**不在关键路径上**（`PLAN-00` §3：`D0 → P-04 → T-08 → T-07 → P-05 → D5 闭环 → D9 Demo`），但它是 ②自动记录与 ③健康报告 + 评分卡的展示数据源，且是 FF-25 热量口径红线的唯一承载点。
- **D1 硬验收**：`PLAN-00` §1 D1 行「`P-08` 定稿」「三方接口冻结」——本功能的字段契约属于冻结范围。
- **D4 复核点**：`model_card` 交付后，必须复跑本 PLAN §4 的 `label_mapping_test`（类别顺序一致性）。
- **CP4（D7 晚）**：报告页数据接通真实记录时，本功能提供 `attribute`/`category`/`portionDesc`/`portionKcal`；未完成则报告页的部分字段留空，**但不得删除功能**（见 SPEC §9 的裁减下限）。
- 本功能不属于「不可砍」五项之一，因此当 D6–D8 需要腾工时，**它是优先被简化的对象之一**；简化下限 = 6 条最小记录，**不得整项删除**。

**文档结束**
