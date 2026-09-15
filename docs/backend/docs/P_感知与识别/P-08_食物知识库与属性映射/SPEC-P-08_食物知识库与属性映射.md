# SPEC-P-08 食物知识库与属性映射

| 项 | 值 |
|---|---|
| 域 | P · 感知与识别 |
| 归属 | C |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.4.1（UI 数据契约表）、§6；**`API-04` §2（`foods.json` ↔ `FoodInfo` 字段映射与文案禁令的权威定义）**；`API-02` §6（`FoodInfo` / `FoodKnowledgeBase` 签名与错误码）；`docs/common/docs_api/schemas/foods.schema.json`（draft-07）；`SPEC-00` §3.3（FF-19）、§3.10（FF-25） |
| 依赖的 SPEC | `SPEC-T-07`（类别顺序真源）、`SPEC-U-03`/`SPEC-U-04`（展示方）、`SPEC-A-01`/`SPEC-A-02`（消费 `attribute` / `category` / `riskNote`） |

## 1. 目标与范围

### 1.1 一句话目标
提供 `assets/foods.json` 知识库：把 FF-19 的 6 个类别映射到属性、`category`、标准份量描述、估算热量、营养标签与建议文案，并强制「热量数字必须与份量描述同时出现且标注『估算』」与「食物粒度必须落在 6 类内」两条硬规则。

### 1.2 范围内（In Scope）
- `assets/foods.json` 的内容与结构：**顶层键恰好等于 `feature_config.class_labels` 的 6 个类别**（键名 = `label`），每键 9 个字段（`API-04` §2.1）。
- `FoodInfo` 的 8 个字段与 `FoodKnowledgeBase` 的 `load` / `byClassId` / `byLabel` / `all`（`API-02` §6）。
- JSON Schema 校验（`docs/common/docs_api/schemas/foods.schema.json`，draft-07，`additionalProperties:false`）与加载期断言。
- **硬规则 1**：`portionKcal` 必须与 `portionDesc` 同屏并带「估算」字样；**禁止孤立出现**（❌ `160 kcal`；✅ `约 1 小包（约 30g）· 估算 160 kcal`）。
- **硬规则 2**：食物粒度必须落在 FF-19 的 6 类内；**禁止「全麦面条」「纯牛奶」「番茄」「鸡翅」等超出识别能力的命名**。
- 文案纪律：与 FF-25 一致（营养与热量来自知识库 + 标准份量估算）；不得含医疗/疗效宣称。
- `load` 的**原子替换**语义：校验失败必须保留旧表（`API-02` §6）。
- 与 `U-03`/`U-04` 的字段对应关系（表外字段不许上 UI）。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
| 不做 | 归属 / 依据 |
|---|---|
| 类别定义与顺序（含中文标签） | **FF-19 是唯一真源**；本功能只做引用与校验，不得新增/改名/改序 |
| 精确营养计算（蛋白/脂肪/碳水/钠的克数） | 不做：v1.0 只给标签，不给营养计算 |
| 按克重换算热量 | 不做：无称重输入，**禁止**暗示可测热量（FF-25） |
| 图标资产本身（`assets/icons/*`） | `U-06` 设计系统；本功能只承载 `icon` 字段名（且 `icon` **不进 `FoodInfo`**，`API-04` §2.1） |
| 识别模型与推理 | `SPEC-P-05` |
| 健康评分与规则引擎 | `A-01` / `A-02`（本功能只提供素材） |
| 报告页图表 | `U-04` / `A-03` |
| 联网查询营养数据库 | **FF-24 §4：禁止**（APK 无 `INTERNET` 权限） |
| 15–20 类扩展；储备类别 `nuts` | 推迟第二阶段 / **不进 v1.0**（FF-19）；Schema 以 `additionalProperties:false` 结构性禁止 |
| 医疗/治疗性建议（降血糖、降血脂、减肥疗效等） | **禁止**（合规红线，`C-02`/FF-25） |
| 知识库内容写入 SQLite | 不做：`API-04` §2 与 `API-03` §2.4 明确知识库**不落库**；仅 `attribute` 快照进 `diet_record` |
| 多语言 / 英文 UI 文案 | v1.0 仅中文；`label` 的英文只作机器标识（FF-19） |
| 静默回退默认条目 | **禁止**：查表失败必须抛错（`API-04` §2 文案禁令 ④） |

## 2. 功能行为

### 2.1 触发与前置条件
1. 启动阶段（`Dart` 主 isolate）调用 `load(assetPath: 'assets/foods.json')`（`API-02` §6）。
2. 加载时执行：JSON 解析 → JSON Schema 校验 → 6 键完整性断言 → `label == 键名` 断言 → 硬规则扫描。
3. 任一步失败 → 抛 `ACD-IO-002`（asset 缺失 / 解析失败 / Schema 不通过），且**保留旧表**。
4. 查询键非法（`classId` 越界 / `label` 未注册）→ `ACD-KB-001`；**不得回退默认条目**。

### 2.2 主流程（编号步骤）
1. 读取 `assets/foods.json` 原始字节；缺失 → `ACD-IO-002`。
2. JSON 解析；失败 → `ACD-IO-002`。
3. 用 `docs/common/docs_api/schemas/foods.schema.json` 校验；失败 → `ACD-IO-002`（detail 带违规路径）。
4. 断言顶层键集合 == `feature_config.class_labels`（6 个），无多键、无缺键（`additionalProperties:false` 已结构性禁止 `nuts`）。
5. 对每条记录断言 `label == 键名`（Schema 无法表达，属加载器断言，`API-04` §2.1）。
6. 断言 `zhName` / `attribute` 与 FF-19 逐字一致；`portionDesc` 非空；`portionKcal > 0`；`nutritionTags` 至少 1 项。
7. 硬规则扫描：`portionKcal` 无孤立渲染路径；文本不命中超能力命名黑名单；无医疗宣称。
8. 构建索引（`label` → `FoodInfo`）后**原子替换**内存表：校验失败则旧表继续可用。
9. 展示方（`U-03`/`U-04`）只能使用 `FoodInfo` 的 8 个字段；表外字段不许上 UI（`00_功能清单` §3 风险 R-19）。
10. `portionKcal` 的唯一合法渲染模板形如 `「<portionDesc> · 估算 <portionKcal> kcal」`；**禁止**任何只渲染数字的路径。

### 2.3 状态与状态迁移
`FoodKnowledgeBase` 为**只读单例**：`UNLOADED → LOADED`（成功，原子替换）或 `UNLOADED → FAILED`（抛 `ACD-IO-002`，旧表保留）。加载成功后查表为纯内存只读、无锁、可跨 isolate 共享只读副本（`API-02` §6）；无写操作、无热更新（无网络，FF-24）。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 资产缺失 / JSON 非法 / Schema 不通过 | `ACD-IO-002`；旧表保留；相关页面进入错误态 |
| 顶层键数 ≠ 6 或多出键 | `ACD-IO-002`（Schema `additionalProperties:false` + 键集合断言） |
| `label` 与键名不符 | `ACD-IO-002`（加载器断言，**不得自动纠正**） |
| `zhName` / `attribute` 与 FF-19 不符 | `ACD-IO-002` |
| `portionKcal < 1` 或缺失 | Schema 校验失败 → `ACD-IO-002` |
| `nutritionTags` 为空数组 | Schema `minItems: 1` → `ACD-IO-002` |
| `riskNote` 为空串 | 允许（Schema 未设长度下限），但字段必须存在 |
| `byClassId` 越界 | `ACD-KB-001`（不返回 `null`、不返回默认条目） |
| `byLabel('nuts')` / 未注册 label | `ACD-KB-001`（`API-02` §6） |
| `all` 被调用方修改 | 必须抛错（不可变只读视图，`API-02` §6） |
| Demo / 预置数据引用表外食物 | 视为缺陷：预置数据必须只用 FF-19 的 6 类（`A-04` 遵守） |

## 3. 接口契约
> 权威定义：`API-02` §6（签名）与 `API-04` §2（字段映射与文案约束）。**类名、字段名、方法签名不得改动。**

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L4 内部 | `FoodKnowledgeBase.load({required String assetPath})` | 资产路径（生产值 `assets/foods.json`） | `Future<void>`（原子替换、幂等） | `ACD-IO-002` |
| L4 内部 | `FoodKnowledgeBase.byClassId(int classId)` | `classId ∈ [0,6)` | `FoodInfo`（非空） | `ACD-KB-001` |
| L4 内部 | `FoodKnowledgeBase.byLabel(String label)` | 已注册 `label` | `FoodInfo`（非空） | `ACD-KB-001` |
| L4 内部 | `FoodKnowledgeBase.all` | — | `List<FoodInfo>`（长度 6，只读） | — |
| 本功能 → `A-01`/`A-02` | `attribute` / `category` / `nutritionTags` / `riskNote` | — | 字段值（`riskNote` 为 `A-02` 的文案素材） | — |
| 本功能 → `U-03`/`U-04` | `FoodInfo` 的 8 个字段 | — | 展示输入 | — |
| 构建期 | JSON Schema 校验 | `foods.json` + `foods.schema.json` | 退出码 | — |

```dart
class FoodInfo { String label; String zhName; String attribute; String category; String portionDesc;
                 int portionKcal; List<String> nutritionTags; String riskNote; }
class FoodKnowledgeBase {
  Future<void> load({required String assetPath});
  FoodInfo byClassId(int classId);
  FoodInfo byLabel(String label);
  List<FoodInfo> get all;
}
```

## 4. 数据契约
> 权威文件：`docs/common/docs_api/schemas/foods.schema.json`（draft-07）与 `API-04` §2.1/§2.2。字段名 `lowerCamelCase`（`API-00` §3.1）。

| `foods.json` 字段 | 类型 | 映射到 `FoodInfo` | 值域 / 约束 |
|---|---|---|---|
| 顶层键（6 个） | `String` | — | **必须恰好等于** `feature_config.class_labels`（FF-19）；`nuts` 不得出现 |
| `label` | `String` | `label` | 必须与所在键名逐字相等；与 FF-19 英文标签一致 |
| `zhName` | `String` | `zhName` | 必须与 FF-19 中文名逐字一致 |
| `icon` | `String` | —（UI 专用） | `assets/icons/` 下文件名；**不进 `FoodInfo`** |
| `attribute` | `String` | `attribute` | 必须与 FF-19「知识库属性」列逐字一致；写入记录时**快照**进 `diet_record.attribute` |
| `category` | `String` | `category` | 展示用细分类别（如「高加工零食」「水果」）；**不是** FF-22 的 `structure` 维口径 |
| `portionDesc` | `String` | `portionDesc` | 非空；**`portionKcal` 唯一合法的搭配说明**，二者必须同屏 |
| `portionKcal` | `int` | `portionKcal` | `> 0`；**估算值**；禁止孤立展示 |
| `nutritionTags` | `Array<String>` | `nutritionTags` | `minItems: 1`；来源是知识库，**不是模型输出** |
| `riskNote` | `String` | `riskNote` | 可为空串；供 `A-02` 引用；不得含医疗宣称 |

**展示模板硬约束（防孤立热量数字）**：唯一允许的热量渲染形如 `「<portionDesc> · 估算 <portionKcal> kcal」`。**禁止**任何只渲染 `portionKcal` 的路径。

## 5. 参数与常量
| 项 | 引用 |
|---|---|
| 类别数、英文标签、中文名、知识库属性 | FF-19（**唯一真源**，不得在本文档复制成第二份） |
| 热量与份量的共现与「估算」标注 | FF-25（宣传口径红线） |
| 营养/热量来源口径 | FF-25：「营养与热量来自知识库 + 标准份量估算，UI 明确标注『估算』」 |
| `attribute` 快照进记录 | `API-03` §2（`diet_record.attribute`） |
| 知识库不落库 | `API-03` §2.4 / `API-04` §2 |
| 无网络出口 | FF-24 §4 |
| 命名与资产路径 | `API-00` §3.1 / `API-05` §3 第 8 类 |
| `kcal` 类型与值域 | `API-00` §3.3（`int`、`> 0`、必须与份量描述同现） |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 资产缺失 | 文件读取失败 | `ACD-IO-002`；旧表保留 | 「数据文件缺失，请重装应用」 |
| JSON 解析失败 | 解析异常 | `ACD-IO-002` | 同上 |
| Schema 校验失败 | `jsonschema` 校验 | `ACD-IO-002`（detail 带违规路径） | 同上 |
| 6 键不完整 / 多键 | 键集合断言 | `ACD-IO-002` | 同上 |
| `label` 与键名或 FF-19 不符 | 逐字比对 | `ACD-IO-002`（**不得自动纠正**） | 同上 |
| 存在孤立热量数字 | 构建期正则扫描 | **构建失败**（`C-04` 不得出包） | 无（开发期拦截） |
| 存在超能力命名 | 构建期黑名单扫描 | **构建失败** | 无（开发期拦截） |
| `byClassId` 越界 | 边界检查 | `ACD-KB-001`（不返回 `null`） | 页面错误态，不显示空白记录 |
| `byLabel` 未注册（含 `nuts`） | 索引未命中 | `ACD-KB-001`，**不回退默认条目** | 同上 |
| 加载失败但页面已打开 | `load` Future 抛错 | Riverpod `AsyncValue.error` 承接（`API-00` §3.5） | 页面错误态 + 重试按钮 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 资产存在且为合法 JSON | `python -c "import json;json.load(open('assets/foods.json',encoding='utf-8'))"` | 退出码 0 |
| 2 | Schema 校验通过 | `python -m jsonschema -i assets/foods.json docs/common/docs_api/schemas/foods.schema.json` | 退出码 0 |
| 3 | 键集合 == `class_labels` | `flutter test test/domain/food_kb_completeness_test.dart` | 顶层键集合与 `feature_config.class_labels` **完全相等**；无 `nuts` |
| 4 | `label == 键名`，且 `zhName`/`attribute` 与 FF-19 逐字一致 | 同上 `label_equalsKey_and_ff19Match` | 6 × 3 个字符串全部相等 |
| 5 | 热量与份量同现且标注「估算」 | `python ai/scripts/assert_kcal_not_isolated.py` + `flutter test test/domain/kcal_render_template_test.dart` | 扫描命中数 == 0；渲染输出匹配 `.*估算\s*\d+\s*kcal` 且必含 `portionDesc` |
| 6 | 无超能力命名 | `python ai/scripts/assert_food_granularity.py` | 黑名单（含「全麦面条」「纯牛奶」「番茄」「鸡翅」「低脂」「有机」「无糖」）命中数 == 0 |
| 7 | 字段值域 | `flutter test test/domain/food_kb_fields_test.dart` | 6 条 `portionDesc` 非空、`portionKcal > 0`、`nutritionTags` ≥ 1 |
| 8 | 无医疗宣称 | `python ai/scripts/assert_no_medical_claims.py`（词表：治疗、降血糖、降血脂、减肥、药用、疗效 等） | 命中数 == 0 |
| 9 | 查询接口正确 | `flutter test test/domain/food_kb_query_test.dart` | `byClassId(i).label` 与 FF-19 一致；`byLabel` 往返成功；`all.length == 6` |
| 10 | 越界/未注册不静默 | 同上 `byClassId_outOfRange_throwsACD_KB_001` / `byLabel_unregistered_throwsACD_KB_001` | 抛 `ACD-KB-001`；`byLabel('nuts')` 抛错且**不回退默认条目** |
| 11 | `load` 原子替换与幂等 | `test/domain/food_kb_load_test.dart` 的 `brokenJson_keepsOldTable` / `loadTwice_idempotent` | 破坏 JSON 后抛 `ACD-IO-002` 且旧表仍可用；连调 2 次结果相同 |
| 12 | `all` 只读 | 同上 `all_isUnmodifiable` | 修改 `all` 抛错 |
| 13 | 与其他类的类别映射一致 | `flutter test test/domain/label_mapping_test.dart`（与 `PLAN-P-05` 共管） | KB 的 `label` 与模型侧 `classId→label` 映射全等 |
| 14 | 无网络依赖 | `aapt dump badging`（`PLAN-C-01`） | 无 `INTERNET`；知识库仅来自 assets |

## 8. 非功能约束
- **体积与加载**：`foods.json` 为纯文本小文件；实测字节数与加载耗时在 D1 产出并记入 `records/reports/p08_foods_kb.md`（**不写预测值**）。
- **线程**：`load` 在启动阶段于 Dart 主 isolate 完成；查表为纯内存只读、无锁（`API-02` §6）。
- **离线**：只读 assets，无网络、无数据库依赖（FF-24 §4）。
- **可本地化**：字段设计为可翻译（v1.0 只交付中文 `zhName` 与文案），英文 `label` 仅作机器标识。
- **无障碍**：本功能无 UI；文案可读性由 `U-03`/`U-06` 承担。
- **合规**：文案不得含医疗宣称（`C-02` 的配套要求）。

## 9. 裁剪与未做
- **本功能不属于「不可砍」五项之一**（`00_功能清单` §6：五项为实时检测闭环、自动记录、健康报告+评分卡、`parity_test`、三种 Demo 模式）。但它是 ②自动记录与 ③健康报告 + 评分卡的**展示数据源**，且是 FF-25「热量必须标估算、与份量同现」红线的**唯一承载点**。**极端情况下可裁减为 6 条最小记录（仅 `label`/`zhName`/`attribute`/`portionDesc`/`portionKcal`），但不得整项删除。**
- 15–20 类扩展：**不做**（推迟第二阶段）；储备类别 `nuts`：**不进 v1.0**（FF-19，Schema 结构性禁止）。
- 精确营养计算、按克重换算热量、称重输入、联网营养数据库、医疗/疗效类文案、多语言本地化、用户自定义食物条目：**不做**。
- 知识库内容写入 SQLite：**不做**（`API-03` §2.4）。
- 查表失败静默回退默认条目：**不做**（`API-04` §2 文案禁令 ④）。

## 10. 开放问题
1. **`category` 的取值口径未冻结**：`API-04` §2.1 把它定义为「记录页次级标签（如『高加工零食』）」，但 FF-22 的 `structure` 维按 `cabbage + carrot + noodles` 三类计算占比，与 `category` **不是同一口径**。本 SPEC 约定 `category` **只作展示**、`structure` 维**不得**依赖 `category`。**需 A/C 确认**后再写入 `SPEC-A-01`。
2. **标准份量的量值来源未定**：`portionDesc` 与 `portionKcal` 的具体数值必须有可追溯来源（包装标注 / 膳食指南），**需 C 在 D1 给出引用并写入 `records/reports/p08_foods_kb.md`**；否则「估算」二字缺乏依据。
3. **`adviceText` 不再需要**：`API-04` §2.1 的字段表把建议文案素材归为 `riskNote`，不再单列 `adviceText`。本 SPEC 已据此收敛（原开放问题关闭）；若 `A-02` 需要更长的静态文案，须走 `API-00` §3.9 变更流程。
4. **`riskNote` 是否允许空串**：Schema 未设 `minLength`，本 SPEC 允许空串；若 `A-02` 依赖每条记录都有文案，需在 Schema 增加 `minLength: 1` 并重跑全部 6 条记录。**需 C 确认。**
5. **文件名与上游清单不一致**：`00_功能清单` §2 表格中的名称与本文件名一致，但同类问题存在于 `P-04`/`P-05`/`P-07`（见交付报告），**需 C 统一裁定后同步 `SPEC-00` §2 的命名规则**。

**文档结束**
