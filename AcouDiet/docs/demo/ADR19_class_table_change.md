# ADR-19 类别表修订：执行记录与实测证据

训练侧交付的语料类别表与冻结的 `SPEC-00` §3.3 **FF-19** 冲突，用户选择**方案 A：正式修订 FF-19**。
本文件是这次修宪的**执行记录**（裁定理由见 `docs/01_裁定记录ADR.md` 的 ADR-19）。

---

## 1. 新旧对照

| ID | 旧（冻结） | 新（ADR-19） | 中文 | 知识库属性 | 处理 |
|---|---|---|---|---|---|
| 0 | `chips` | `chips` | 薯片 | 脆性食品 → **脆性高加工零食** | 保留，属性改 |
| 1 | `apple` | **`cabbage`** | 苹果 → 卷心菜 | 脆爽果蔬 → **脆爽蔬菜** | 替换 |
| 2 | `cookie` | **`gummies`** | 饼干 → 软糖 | 脆性食品 → **黏弹性零食** | 替换 |
| 3 | `bread` | **`noodles`** | 面包 → 面条 | 软性主食（不变） | 替换 |
| 4 | `carrot` | `carrot` | 胡萝卜 | 脆爽蔬菜（不变） | 保留 |
| 5 | `drink` | `drink` | 饮料 | 液体（不变） | 保留 |

**id 位置不变**，所以「食物结构」的 `healthy_labels` 由 `["apple","carrot","bread"]` 改为
`["cabbage","carrot","noodles"]` —— **id 集合仍是 {1,3,4}**，四个评分算例（100/61/28/29）的算术因此
完全不变。`chips` 与 `gummies` 是两类零食，所以「脆性 = chips + gummies」。

**`noodles` 原本是 FF-19 明文规定「不进 v1.0」的储备类别**，`nuts` 仍然是。本次修订拆掉了
`noodles` 上的四道结构性防线，但**防线机制本身保留**，只是成员集合改成了 `{nuts}`：

| 防线 | 位置 | 修法 |
|---|---|---|
| 制品门禁禁止词 | `ai/tests/run_all.py` `CUT_TOKENS` | 去掉 `noodles` |
| 制品闸门禁止词 | `tool/verify_artifacts.py` banned 列表 | 去掉 `noodles` |
| 消融禁止词 | `ai/src/ablations.py` `FORBIDDEN` | 去掉 `noodles` |
| 知识库 Schema 结构性拒绝 | `foods.schema.json` 枚举键 | 六个键按新表重写 |
| SPEC 禁词 | `SPEC-U-03` 等四处「禁止…『面条』」 | 改为禁止**更细**的命名（「全麦面条」等） |

## 2. 改动清单（全部已落盘并验证）

| 层 | 文件 |
|---|---|
| SSOT | `shared/feature_config.json`（`class_labels`、`structure.healthy_labels`、新增 `_decisions.class_table`） |
| 生成物 | `feature_config.g.dart` / `FeatureConfig.kt` / `assets/feature_config.json` / `test/cfg/feature_config_keys.g.json`（由 `tool/gen_feature_config.dart` 重生成） |
| 宪法 | `SPEC-00` §3.3 FF-19 表 + `docs/01_裁定记录ADR.md` ADR-19 |
| 知识库 | `app/assets/foods.json`（6 条重写）、`foods.schema.json`（枚举键与描述重写） |
| App 代码 | `food_class.dart`（枚举）、`food_icon.dart`（图标：cabbage→grass、gummies→cookie、noodles→ramen）、`food_catalog.dart`（**删掉手抄的标签数组，改读 SSOT**）、`fake_repo.dart` + `detection_session.dart`（**属性不再由 classId 硬编码**）、`audio_bridge.dart`（**标签数组改读 SSOT**） |
| 资产 | `demo_dataset.json`（由 `gen_demo_dataset.py` 重生成 28 条）、`models/model_card.json`（`classLabels` + `featureConfigSha256` 更新） |
| AI 侧 | `src/config.py` 默认值、`scripts/make_synthetic_dataset.py`（`TEXTURES` 新六类）、`ingest_feedback.py` 文档示例；语料与 `splits/*.csv` **全部重生成**（3120 公开 + 240 自采） |
| 测试 | `test/support/fixtures.dart` 及 9 个 App 测试文件、`tool/pure_tests.dart` / `session_tests.dart` / `ui_presenter_tests.dart` / `data_tests.dart` |
| 文档 | 19 个 SPEC/PLAN/README 由脚本改名，另手工修正判断项（属性示例、储备清单、禁词表） |

## 3. 实测证据

### 3.1 离线与工具链

| 项 | 结果 |
|---|---|
| `tool/verify_all.ps1` | **ALL SUITES PASSED (16 steps)**，exit 0（含 Mel parity） |
| `flutter analyze` | **0 error** |
| `flutter test` | **104 项全过** |
| L3 数据层 | **47 → 57 项**（新增 10 项 v2 迁移断言） |
| UI presenters | **370 → 373 项** |

### 3.2 设备实测：新类别真的走通了

在模拟器上植入一条 `noodles`（id 3）记录，冷启动后首页渲染：

```
06:10  面条        ≈280 kcal
软性主食 · 1 碗（约 200g）（估算）
```

`食物结构 30/30` —— 证明 `noodles` 确实落在新的 `healthy_labels` 里。
链路：SSOT → 生成的常量 → `foods.json` → 知识库 → UI，全部一致。

### 3.3 ⚠️ 设备实测暴露的第二个缺陷：老数据会把首页打死

**现象**：数据库里只要有一条**改表之前**写入的记录（`class_label='bread'`），首页整页变成
**「食物知识库查询失败 / ACD-KB-001」**，今天/本周/报告全都没了。

**根因**：`sql_repos.dart` 的按类聚合对**不在 `class_labels` 里的 label** 主动抛
`ACD-KB-001`（`"unregistered class label"`）。这个抛错本身是**对的**——它拒绝把不认识的类别
静默算成 0。问题在于改类表之后，**原本合法的 label 变成了不合法的**，而项目一直没有数据迁移。

**修法：新增 schema 迁移 v2**（`app_database.dart`，`schemaVersion` 1 → 2）。因为 id 位置不变，
改名是无损的：

```sql
UPDATE diet_record SET class_label='cabbage' WHERE class_id=1 AND class_label='apple';
UPDATE diet_record SET class_label='gummies' WHERE class_id=2 AND class_label='cookie';
UPDATE diet_record SET class_label='noodles' WHERE class_id=3 AND class_label='bread';
```

三条语句都**同时校验 id 与旧 label**，因此：可重复执行（第二次是空操作），且
**label 与 id 互相矛盾的脏数据不会被「猜」** —— 那种数据仍然应该报 `ACD-KB-001`。
`attribute` **刻意不改**：`API-03` §2 规定它是写入时快照，历史记录保持当时的措辞。

**设备实测**（v2 真的跑了）：

| 时刻 | `user_version` | 记录 |
|---|---|---|
| 启动前 | 1 | `legacy-a \| bread` |
| 启动后 | **2** | `legacy-a \| **noodles**` |

首页随即正常渲染该条为 `面条 / 1 碗（约 200g）/ ≈280 kcal`（属性显示 `正餐`，因为那是被植入的快照值——
迁移按设计不动快照）。`data_tests.dart` 里新增 10 项断言覆盖：三条改名、已合法 label 不动、
id/label 矛盾不猜、二次执行为空操作、迁移后可被冻结六类解析。

## 4. 仍需知悉的两点

1. **数据量风险未解决**：训练侧语料 `noodles` 412 段、`drink` 293 段，低于 `SPEC-T-01` 的单类
   500 片段门槛（`cabbage` 恰好 500，零余量）。该语料会让 `SPEC-T-01 --strict` 以 `exit 3` 退出。
   本裁定**不放宽门槛**，只如实登记在 ADR-19 与 `SPEC-00` §3.3；**在作任何准确率声明之前应先评估
   FF-19 的 4 类降级开关**。
2. **成品模型**：本条写于 2026-09-12 上午，当时训练侧的 `.tflite` 还没拿到，`model_card.json`
   的 `quantization` 是 `pending`，`tool/verify_artifacts.py` 返回 **exit 3 = 未构建**。
   **当天已由 `ADR-21` 关闭**：模型组交付了三个制品，已按用户要求（精度最高）投放
   `acoudiet_fp32_v1.0.0.tflite`，模型卡由 `python tool/install_model.py --tflite <path> --version 1.0.0`
   写全，闸门现返回 **exit 0 = PASS**。同一轮里还发现交付制品的 Mel 前端规格与本仓冻结的那套不一致，
   因此 `ADR-21` 同时修订了 FF-02/FF-07/FF-08/FF-11/FF-14 —— 投放模型**不只是**复制文件这一件事。
