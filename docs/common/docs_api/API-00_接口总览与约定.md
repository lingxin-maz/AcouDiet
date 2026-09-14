# API-00 接口总览与约定

**上游**：`docs/common/SPEC-00_总则与冻结事实.md`（下称 SPEC-00）、主方案 §5.1
**地位**：本文件定义**全部跨层接口的公共约定**。各接口的具体签名见 `API-01`~`API-06`。

---

## 1. 分层边界（v1.0 唯一的「系统架构」视图）

```
┌──────────────────────────────────────────────────────────────────────────┐
│ L5 表现层 Presentation            Dart / Flutter widgets + Riverpod        │
│    页面 U-01…U-05、组件 U-06                                                │
└───────────────────────────┬──────────────────────────────────────────────┘
                            │  Provider / Notifier 调用域服务（进程内，同步或 Future）
┌───────────────────────────▼──────────────────────────────────────────────┐
│ L4 域层 Domain                    Dart                                      │
│    InferenceEngine (P-05)   VoteAggregator (P-06)   BehaviorAnalyzer (P-07) │
│    FoodKnowledgeBase (P-08) HealthScoreService (A-01) AdviceRules (A-02)    │
│    ReportService (A-03)     DemoController (M-01…M-04)                      │
│    ── 内嵌 tflite_flutter Interpreter + XNNPACK（L0 运行时）                │
└───────────────────────────┬──────────────────────────────────────────────┘
                            │  Repository 接口（API-03）
┌───────────────────────────▼──────────────────────────────────────────────┐
│ L3 数据层 Data                    Dart                                      │
│    AppDatabase / Migrations (D-01,D-02)   DAOs   Repos   FakeRepo（UI 占位） │
│    ── 本地 SQLite 单文件，无网络访问                                        │
└───────────────────────────▲──────────────────────────────────────────────┘
                            │  EventChannel（mel patch 流）+ MethodChannel（控制）
┌───────────────────────────┴──────────────────────────────────────────────┐
│ L2 桥接层 Bridge                  Flutter Platform Channel                 │
│    频道 `com.acoudiet.app/audio`（Method）+ `/audio_stream`（Event）        │
└───────────────────────────▲──────────────────────────────────────────────┘
                            │  Kotlin 内部调用（API-01 描述的是一侧契约）
┌───────────────────────────┴──────────────────────────────────────────────┐
│ L1 原生采集层 Native              Kotlin（Android only）                    │
│    AudioCapture (P-01)  Vad (P-02)  Preprocess (P-03)  MelFrontend (P-04)  │
│    AudioRecord(16k, MONO, PCM_16BIT) → 环形缓冲 65536 样本                  │
└──────────────────────────────────────────────────────────────────────────┘

        ══════════ 离线边界：v1.0 不存在任何网络接口 ══════════
```

**关键裁定**（主方案 §3.3）：**Mel 计算放在 L1（Kotlin 原生），不在 Dart 里做。** Dart 侧只接收算好的 `Float32List`，避免两套 FFT/Mel 实现导致精度崩塌。

**三层之间的耦合规则**：
1. L5 只能调 L4，不得直接调 L3 的 DAO，也不得直接调 L2 的 MethodChannel。
2. L4 不得 import Flutter widget（保持可单测）。
3. L3 不得包含业务规则（评分、建议、速度评级都属 L4）。
4. L1 不得包含 UI 文案与业务阈值（阈值来自 `feature_config`，经 `API-01` 握手校验）。

---

## 2. 接口清单

| 编号 | 名称 | 层间 | 类型 | 权威定义 |
|---|---|---|---|---|
| `API-01` | 原生桥接（MethodChannel / EventChannel） | L1 ↔ L2/L4 | 跨进程内通道，异步 | `API-01` |
| `API-02` | 推理与聚合引擎接口 | L4 内部 | Dart 类接口 | `API-02` |
| `API-03` | 数据访问层接口（DAO / Repository） | L3 ↔ L4 | Dart 抽象类 + SQL | `API-03` |
| `API-04` | 域服务接口（评分 / 知识库 / 报告 / 演示） | L4 ↔ L5 | Dart 抽象类 | `API-04` |
| `API-05` | **后端数据通讯规范** | 全系统 | 边界裁定 + 产物契约 + 预留协议 | `API-05` |
| `API-06` | AI 训练侧数据契约 | 离线 ↔ App（文件） | JSON/CSV 文件契约 | `API-06` |
| `docs/common/docs_api/schemas/*.json` | 机器可读 Schema | — | JSON Schema draft-07 | `docs/common/docs_api/schemas/` |

**调用方向图例**：`L5 → L4 → L3`（同步/Future）；`L1 → L4`（EventChannel 单向推送）；`L4 → L1`（MethodChannel 请求）。

---

## 3. 公共约定

### 3.1 命名

| 语境 | 规范 | 例 |
|---|---|---|
| Dart / Kotlin 标识符 | `lowerCamelCase` | `melPatchSize` |
| JSON 字段 | `lowerCamelCase` | `"tauConfirm"` |
| SQLite 表 / 列 | `snake_case` | `diet_record.ended_at_ms` |
| Python（训练侧） | `snake_case` | `n_frames` |
| 常量 | `SCREAMING_SNAKE_CASE` | `TAU_CONFIRM` |
| 频道名 | 反向域名 + 斜杠 | `com.acoudiet.app/audio` |
| 错误码 | `ACD-<AREA>-<NNN>` | `ACD-MEL-001` |

> ⚠️ `feature_config.json` 使用 `snake_case`（Python 侧可读优先）。**Dart 侧读取后必须由生成器转成 camelCase 常量**，禁止在业务代码里手写字符串键名。转换规则与代码生成见 `PLAN-C-03`。

### 3.2 时间

| 项 | 规范 |
|---|---|
| 传输/存储 | **epoch 毫秒（UTC）**，`int64`，字段名带 `Ms` 后缀 |
| 时长 | **秒**，`double`，字段名带 `Seconds` 后缀；毫秒级字段带 `Ms` 后缀 |
| 日期分组 | 按**设备本地时区**的日历日（`yyyy-MM-dd`）字符串 |
| 显示 | 由 `U-*` 层格式化，域层不得产出格式化字符串 |
| 禁止 | 不得存 `DateTime` 序列化的 ISO 字符串作为主存储格式（时区解析歧义） |

### 3.3 数值与单位

| 概念 | 类型 | 值域 | 说明 |
|---|---|---|---|
| 置信度 `confidence` | `double` | `[0,1]` | Softmax 概率；展示时才转百分比并取整 |
| 音频电平 `rms` | `double` | `[0,1]` | 线性幅度，仅用于波形动画，不参与业务判定 |
| Mel 张量 | `Float32List` | `[0,1]` | 长度 `128 × n_frames`，行主序，见 SPEC-00 §3.1 |
| 热量 `kcal` | `int` | `>0` | **估算值**，必须与标准份量描述同时出现（FF-25） |
| 分数 `score` | `int` | `[0,满分]` | 四维之和 = 总分 |
| 评分 `grade` | `enum` | `良好 / 一般 / 需改善` | 三值枚举 |

### 3.4 标识符

| 实体 | 格式 | 例 |
|---|---|---|
| 饮食记录 `recordId` | UUID v4 | `9f1c…` |
| 检测会话 `sessionId` | `S-<epochMs>-<4位hex>` | `S-1757462400000-a3f1` |
| 志愿者/受试者 | `P<两位序号>` | `P01` |
| 公共数据集录音 | 原始文件名（去扩展名） | `chips_0012` |
| 模型制品 | `<name>_<quantization>_v<version>.tflite` | `acoudiet_fp32_v1.0.0.tflite`（`ADR-21`：档位进文件名；`int8` 档的名字与旧规则逐字相同，无兼容性成本） |

**`sessionId` 规则的理由**：`epochMs` 保证时间可读、单调递增便于排序，hex 后缀防同毫秒碰撞。**不使用 UUID 生成会话 ID**，因为会话 ID 会出现在日志与演示截图里，可读性优先。

### 3.5 错误模型

所有跨层错误统一为：

```json
{
  "code": "ACD-MEL-001",
  "message": "音频特征计算失败，请重新开始检测",
  "detail": { "expectedFrames": 128, "actualFrames": 127 },
  "retryable": false
}
```

> ⚠️ **`expectedFrames` 的数取决于该错误由谁抛**（`ADR-21`（2026-09-12）引入两套帧数后必须说清）：**模型输入侧**（`ACD-INF-002`，`tflite_inference_engine.dart`）比的是**张量宽度 `nFrames = 128`**；**Mel 载荷侧**（`ACD-MEL-001`，`MelFrontend`）比的是**原始 STFT 帧数 `rawMelFrames = 129`**，此时该字段写 129。上例取自前者的实际载荷结构，故为 128。**不要把两个数混用** —— 见 `SPEC-00` §3.5、FF-11 与 `ADR-21`。

| 区域码 | 含义 | 代码 |
|---|---|---|
| `ACD-PERM` | 权限 | `001` 录音权限被拒绝（可再次请求）；`002` 被永久拒绝，需跳系统设置 |
| `ACD-SESS` | 会话生命周期 | `001` 会话不存在/已结束；`002` 状态转换非法（含并发会话超限） |
| `ACD-AUD` | 音频设备 | `001` `AudioRecord` 初始化失败；`002` 设备被占用（其他 App 正在录音） |
| `ACD-MEL` | 特征计算 | `001` 帧数不符（**最高频的联调错误**）；`002` 输入采样数不符 |
| `ACD-INF` | 推理 | `001` 模型加载失败；`002` 输入张量形状不符；`003` 委托初始化失败（**预期情况，必须自动回退 CPU 且不抛出**）；`004` 推理**调用**失败 —— 覆盖两种情形：**未 `load()` 即 `run()`**（调用方缺陷）与 `Interpreter.run()` 执行异常 |
| `ACD-BEH` | 行为分析 | `001` 包络缺失或长度不符（`SPEC-P-07`） |
| `ACD-KB` | 知识库 | `001` 类别越界／`classId` 不在 FF-19 的 6 类内（`SPEC-P-08`） |
| `ACD-SCORE` | 评分与报告 | `001` 评分所需数据不足或口径冲突（`SPEC-A-01`） |
| `ACD-DB` | 数据库 | `001` 迁移失败；`002` 唯一约束冲突；`003` 写入失败（可重试 1 次）；`004` 记录与指标不满足 1:1 约束 |
| `ACD-CFG` | 配置 | `001` 原生端与 Dart 端 `feature_config` 版本不匹配（**必须 fail fast，禁止进入检测页**） |
| `ACD-IO` | 文件 | `001` 临时音频清理失败（**不阻断主流程，仅记日志，但须出现在自检面板**）；`002` assets 读取失败 |
| `ACD-DEMO` | 演示模式 | `001` 示例音频缺失或损坏；`002` 演示数据集缺失或不可解析；`003` 模式切换非法 |
| `ACD-ART` | **离线工具链**（AI 侧脚本，不出现于 App 运行时） | `001` 数据集缺失；`002` 划分泄漏断言失败；`003` 训练/导出失败；`004` 制品 hash 闭环不通过；`005` 数值对齐未达阈值 |
| `ACD-UNK` | 未分类 | `000` |

> 🔴 **本表是错误码的唯一登记处。** 新增任何错误码必须**先在此登记**，再在对应 `API-0x` 使用；未登记即使用的代码无权威依据（`SPEC-M-04` 在自检面板中直接回显错误码，因此这条纪律在现场是可观测的）。
>
> **`ACD-ART-*` 的定位**：这五个码属于 `ai/scripts/` 的退出诊断，出现在训练与导出日志里（`API-06`），**不会出现在 App 运行时**。把它们登记在此是为了让交付物清单可以用同一套编号自查（`PLAN-C-05` 的测试清单引用它们）。

**Kotlin → Dart**：用 `result.error(code, message, detail)` → Dart 侧收到 `PlatformException(code, message, detail)`。
**Dart 内部**：抛出 `AcouDietError`（`API-02` §2.4 定义），由 L5 的 Riverpod `AsyncValue.error` 承接。

### 3.6 版本协商（**必须实现，否则 `ACD-CFG-001` 无法触发**）

```
启动握手（一次，App 冷启动时）：
  1. Dart 读 assets 里的 feature_config.json → 得到 { melVersion, nFrames, nMels, ... }
  2. Dart 调 native.getCapabilities() → 得到原生端编译期固化的一组同名字段
  3. 逐字段比对；任一不符 → 抛 ACD-CFG-001，禁止进入检测页
  4. 一致 → 缓存 NativeCapabilities，整个 App 生命周期不再重复握手
```

**握手字段清单（15 字段，`ADR-21`（2026-09-12）由 12 字段扩至 15 字段）**：`melVersion`、`sampleRate`、`nFft`、`hopLength`、`nMels`、`rawMelFrames`、`nFrames`、`fmin`、`fmax`、`preemphasis`、`preemphasisBoundary`、`powerToDbRef`、`topDb`、`normalization`、`patchSamples`。
> **`ADR-21` 的入列/出列**：入列 `rawMelFrames`、`preemphasisBoundary`、`powerToDbRef`、`topDb`、`normalization`（5 个）；出列 ~~`dbClipMin`~~、~~`dbClipMax`~~（2 个，对应**已删除**的 `db_clip_range` 键）。⚠️ `rawMelFrames`（129，STFT 原始帧数）与 `nFrames`（128，张量宽度）**两者都必须比对** —— 把这两个数合成一个数正是 `ADR-21` 所修缺陷的成因。
**为何必须**：这是捕获「改了 Python 忘改 Kotlin」这类错误（风险 R-20）的**唯一运行时防线**。

### 3.7 线程与调度

| 动作 | 线程 | 约束 |
|---|---|---|
| `AudioRecord.read()` + 预处理 + Mel | 原生后台线程（专用 `HandlerThread`） | 不得在主线程；单次处理 < 32 ms（hop 512 @16 kHz） |
| EventChannel 事件投递 | Android 主线程 | 事件负载已算好，投递本身 < 1 ms |
| TFLite `Interpreter.run()` | **Dart 独立 isolate** | 不得在 UI isolate 执行；单 patch 目标 < 100 ms |
| 投票聚合 | 推理 isolate 内 | 状态跨 patch 保持（FF-20c） |
| SQLite 读写 | Dart 主 isolate（`sqflite`） | 单次查询 < 20 ms；批量写入用事务 |
| 评分 / 报告计算 | Dart 主 isolate | 数据量小（周级聚合），无需 isolate |

### 3.8 背压与降级

| 链路 | 速率 | 策略 |
|---|---|---|
| Mel patch 事件 | 2 次/秒 × 65,536 B（`mel = 128×128×4 B`，即 `nMels × nFrames`；含包络则 +819×4 B ≈ 68 KB/事件） | **drop-oldest**：若 Dart 侧未消费完上一个 patch，丢弃最旧的未消费 patch，**绝不阻塞原生线程**。实时检测只关心最新状态 |
| 电平事件 | 10 次/秒 × 8 B | 直接投递，无缓冲 |
| 推理排队 | 最多 1 个待处理 patch | 超过则丢旧，保证「当前状态」语义 |
| 数据库写入 | 每次确认结果 1 行 | 会话结束时批量提交一次事务 |

**明确不做**：不做无界队列、不做重试补偿、不做离线同步队列（无网络，`API-05` §1）。

### 3.9 接口变更流程

任何接口契约变更**必须**：
1. 在**变更传播单**登记（**共 14 项** = 主方案 §4.1.1 的 P-1~P-9 + 本项目追加的 A-1 / A-2 / ADR-05 / ADR-07 / ADR-09。**表的物理位置是 `SPEC-C-03` §7 附表**，`PLAN-C-03` 只做打勾登记）；
2. 同步更新本目录对应 `API-0x` 与 `docs/common/docs_api/schemas/*.json`；
3. 若涉及内存布局或数值口径 → **必须重跑 `PLAN-T-08` 的对齐测试**；
4. 若涉及 `feature_config` → **必须重跑 `PLAN-C-03` 的全局搜索验收**（`3s` / `hop.*160` / `帧移 10` 命中数为 0）。

**禁止**：只改代码不改契约；或在 `docs/*/docs_api/` 之外的地方复制一份接口签名。

---

## 4. 契约与代码的对应关系

| 契约 | 生成/校验方式 | 计划项 |
|---|---|---|
| `feature_config.json` → Dart 常量 | 代码生成（`dart run build_runner` 或简单脚本），不手写 | `PLAN-C-03` |
| `DietRecord` 模型 ↔ SQLite 表 | 手写 `fromMap/toMap` + 单元测试双向往返 | `PLAN-D-01` |
| `HealthScore` 返回结构 | 冻结的 Dart 类 + JSON 往返测试 | `PLAN-A-01` |
| `foods.json` → 知识库 | JSON Schema 校验 + 启动时加载断言 | `PLAN-P-08` |
| `metrics.json`（评估产出） | JSON Schema 校验 + 报告页引用 | `PLAN-T-05` |
| MethodChannel 契约 | 侧侧对称测试（Kotlin 单测 + Dart 单测用 mock 通道） | `PLAN-P-01` `PLAN-P-04` |

---

**文档结束**
