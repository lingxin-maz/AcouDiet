# SPEC-G-03 推荐与外卖检索工具

| 项 | 值 |
|---|---|
| 域 | `G` · 智能体与云端智能 |
| 归属 | C |
| 状态 | ✅ v2.0 交付 |
| 上游依据 | `SPEC-00` §3.11（`FF-26d`/`FF-26e`/`FF-26i`/`FF-26j`）、§3.3（`FF-19` 类别中文名）、§3.9（`FF-24` 第 8 条）；`API-07` §3/§4；`API-03` §4–§7；`API-04` §3/§4/§5；`ADR-44` |
| 依赖的 SPEC | `SPEC-G-02`（注册表与观察形状）、`SPEC-A-01`、`SPEC-A-02`、`SPEC-A-03`、`SPEC-D-03`；下游 `SPEC-U-07` |

## 1. 目标与范围

### 1.1 一句话目标

实现 `SPEC-G-02` 注册表所需的**四个工具**：前三个**只读**既有域服务（`API-03` 仓储 / `API-04` 服务），不新造任何分数；第四个把「想吃什么」变成 **1..3 张待用户点击的交接卡片**——用 `feature_config.agent[].httpsTemplate` 拼 URL，**永不启动任何外部 App**。

### 1.2 范围内（In Scope）

| # | 内容 |
|---|---|
| 1 | `get_health_summary`：窗口级四维分数、总分、评级、聚合计数（字段白名单见 §4） |
| 2 | `get_recent_meals`：最近 N 条记录的**类别标签 / 类别 id / 进食时间戳 / 置信度**四字段 |
| 3 | `recommend_food`：基于 `API-04` §4 的规则建议及其理由（`dimension` + `text`） |
| 4 | `propose_takeout_search`：构造 1..3 张交接卡片（`proposalOnly == true`） |
| 5 | 关键词构造规则（仅取自**用户本轮消息 + 本地推荐结果**）与长度上限 `G-03-K1` |
| 6 | URL 展开：`template.replaceAll('{q}', Uri.encodeComponent(keyword))` |
| 7 | 平台可用性的**诚实呈现**：`enabled == false` 不出现；`verifiedOn == null` 必须标注未核实（`API-07` §3.3） |

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥

| 不做 | 归属 / 依据 |
|---|---|
| **下单、代操作、模拟点击、代填收货地址、代扣款** | ❌ 禁（`FF-26i`） |
| `AccessibilityService` 及其任何形态 | ❌ 禁（`FF-26i`）；不得以「可选开关」形式提供 |
| **启动外部 App**：`startActivity` / `MethodChannel` / `url_launcher` | ❌ 不在本层。唤起由 `SPEC-U-07` 在**用户点击后**经桥接层调用（`API-07` §3.2） |
| 平台可唤起性查询（`canOpen`） | ❌ 不在本层（`SPEC-G-03` 是纯 Dart，无 `MethodChannel`）；由 `SPEC-U-07` 决定按钮是否显示 |
| 新增/替换平台，或把平台数扩展到三个之外 | ❌ 禁（`FF-26j`；扩展须走 `SPEC-C-03`） |
| 对平台 URL 做**网络预检**（HEAD/GET 探测可达性） | ❌ 禁。可达性只由**真机人工核实**写入 `verifiedOn`（`API-07` §3.3） |
| 重算四维分数、总分、评级、聚合；新增任何分数 | ❌ 禁。只读 `API-04` §3/§4/§5 与 `API-03` §5 的输出 |
| 关键词从设备标识、位置、网络、通讯录、日历、媒体库推导 | ❌ 禁（`FF-26e`） |
| 关键词或卡片落盘持久化、跨会话缓存 | ❌ 不做 |
| 卡片渲染、按钮文案、降级态文案 | `SPEC-U-07`（本层只给数值槽位与结构） |
| 比价、门店级检索、配送范围/起送价计算、优惠券 | ❌ 不做 |

## 2. 功能行为

### 2.1 触发与前置条件

| 项 | 要求 |
|---|---|
| 触发 | **仅**由 `SPEC-G-02` 的编排循环按模型工具调用发起；本层不注册任何定时或 UI 直接入口 |
| 前置 ① | `SPEC-G-02` 已完成同意态与凭据的前置判断；本层不做网络判断 |
| 前置 ② | `args` 已通过 `SPEC-G-02` 的 `jsonDecode`；字段类型不符按缺省处理（§2.4 #3） |
| 前置 ③ | 读域服务所需的仓储/服务实例由装配层注入（`API-03`/`API-04`），本层不自行构造数据库连接 |
| 前置 ④ | `feature_config.agent` 恰为三个平台（`FF-26j`）；由 §7 #2 的构建期判据保证，运行时不造平台 |

### 2.2 主流程（编号步骤）

1. **`get_health_summary`**：`range == "week"` → 窗口取最近 7 个本地日；`range == "today"` → 窗口取 `API-04` §5 的 `ReportService.scoreWindowFor(今日 0 点)`（**不得**用单日窗口：单日 σ 不可定义，取单日会造出一个无依据的总分）。调 `HealthScoreService.score`，输出四维分数、总分、评级、`WeekSummary` 的聚合计数。`range` 缺失或非法 → `status:"error"` + 三字段。
2. **`get_recent_meals`**：调 `DietRepo.byRange(lastLocalDays(G-03-K2))`；`limit = args.limit` 缺失时取 `G-03-K4` 的缺省；取结果**尾部** `limit` 条（`byRange` 已按时间升序，由 `API-03` §4 保证，**不得**重排）；逐条只映射 §4 的四个白名单字段。
3. **`recommend_food`**：窗口取最近 7 个本地日；依次取得 `HealthScore`（`API-04` §3）与 `WeekSummary`（`API-03` §5），调 `AdviceEngine.generate`（`API-04` §4）；输出**逐字复用**引擎产出的 `text` 与其 `dimension`，**不得**改写、删数字或补数字；`args.avoid` 非空时，剔除文案中**精确包含**任一被回避类别中文名（`FF-19` 表）的建议项；剔除后只剩 `general` 项时，按引擎原语义如实返回。
4. **`propose_takeout_search`**：按 §2.2.1 构造关键词；按 §2.2.2 展开 URL；按 §2.2.3 过滤平台；产出 0..3 张卡片，`artifacts` 同时给出未采纳平台及其原因。**本步骤不调用任何启动接口。**
5. 四个工具都返回 `SPEC-G-02` 的固定形状观察 JSON；`status` 取值规则见 §6。

**§2.2.1 关键词构造（确定性，仅用本地状态）**

| 步 | 规则 |
|---|---|
| 1 | `anchor` = 本轮用户消息（`SPEC-U-07` 传入）中经归一化的文本：`trim` → 连续空白折叠为单个空格 → 去除首尾标点 |
| 2 | `dish` = `recommend_food` 结果中**首条非 `general` 项**文案里，按 `FF-19` 类别中文名做**精确子串**匹配得到的第一个类别标签；无匹配则为空串 |
| 3 | `keyword = [dish, anchor].where(非空).join(' ')` |
| 4 | 若 `keyword.runes.length > G-03-K1` → 按**码点**截断到上限（不加省略号，避免污染检索词） |
| 5 | 截断后为空（`anchor` 为空且 `dish` 为空）→ `status:"error"`，**不产出任何卡片** |

**§2.2.2 URL 展开**

| 步 | 规则 |
|---|---|
| 1 | 取 `template = feature_config.agent[i].httpsTemplate` |
| 2 | `template` 不含占位符 `{q}` → 该平台**不产出卡片**，列入 `artifacts.invalidPlatforms` |
| 3 | `url = template.replaceAll('{q}', Uri.encodeComponent(keyword))`（`API-07` §3.3：编码是**必做**步骤，不是可选项） |
| 4 | `url` 必须以 `https://` 开头，且其 host 必须与 `template` 的 host **逐字相等**；否则该平台不产出卡片并列 `invalidPlatforms` |

**§2.2.3 平台过滤与诚实呈现**

| 条件 | 处理 |
|---|---|
| `enabled == false` | **不产出卡片**；列入 `artifacts.skipped`。**不得**「先展示再提示可能打不开」 |
| `enabled == true` 且 `verifiedOn == null` | **产出卡片**，并置 `verified: false`；`SPEC-U-07` 必须据此显示「可能打不开」的次要提示（`API-07` §3.3） |
| `enabled == true` 且 `verifiedOn != null` | 产出卡片，`verified: true` |
| `args.platforms` 给出的 id 不在三平台表内 | **忽略**该 id，不报错（模型可以多给） |
| 过滤后为 0 个平台 | `status:"warning"`，卡片数 0，`next_actions` 如实说明「当前没有已启用的平台」（见 §10 OQ-G03-1） |
| 卡片数 > `G-03-K3` | 按平台表**声明序**截断，超出部分列入 `artifacts.skipped`（确定性，不随机） |

### 2.3 状态与状态迁移（有状态的功能必填，无状态写「无状态」）

**无状态**。四个工具都是纯函数式的：不缓存上一次结果、不持有跨轮次字段、不读系统时钟以外的外部状态（只有 `get_health_summary` 的 `"today"` 与窗口计算需要「当前本地日」，来源为既有时间工具）。卡片与观察都是**值对象**，可被逐字段断言。同一输入重复调用 100 次输出逐字相同（关键词与 URL 部分）。

### 2.4 边界条件

| # | 场景 | 处理（确定性） |
|---|---|---|
| 1 | `args.limit` 缺失 / 非 `int` / 超界 | 缺失取缺省；非 `int` 视为缺失；越界按 `G-03-K4` 值域夹取（**不抛**） |
| 2 | `args.range` 非法 | `status:"error"` + 三字段，`safe_retry` 明确列出两个合法值 |
| 3 | `byRange` 返回空列表 | `status:"success"`，`summary` 如实写「窗口内没有记录」，`artifacts.count == 0`；**不得**用演示数据填充 |
| 4 | 记录缺少置信度（占位指标行） | 该字段输出 `null`；**不得**用 `0` 冒充置信度 |
| 5 | `recommend_food` 只得到 `general` 免责声明项 | 照实返回（`API-04` §4 的强制项），`next_actions` 说明数据不足 |
| 6 | `args.avoid` 含表外类别名 | 忽略该项，不报错 |
| 7 | 关键词含空格、中文、`#`、`&`、`/`、`?` | 由 `Uri.encodeComponent` 处理；断言解码后逐字等于关键词 |
| 8 | 关键词超 `G-03-K1` | 按码点截断（§2.2.1 步 4）；**不得**因超长而放弃构造 |
| 9 | 平台模板缺 `{q}` / host 不一致 / 非 https | 不产出该平台卡片，列入 `invalidPlatforms`；其他平台照常 |
| 10 | 三平台全 `enabled == false` | 0 张卡片 + `status:"warning"`（§10 OQ-G03-1） |
| 11 | `WeekSummary` 缺失某些键 | 按 `API-03` §5 的「缺失补 0」语义处理（与 `SPEC-A-02` §2.4 #5 一致） |
| 12 | 单次轮次内被调用两次 `propose_takeout_search` | 两次输出逐字相同（无状态）；由 `SPEC-G-02` 的轮次上限约束次数 |

## 3. 接口契约

> 只写与本功能直接相关的契约；完整签名以对应 `API-0x` 为准（见 `docs/*/docs_api/`），此处给「本功能用到的部分」并标注 API 编号。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| G-02 → G-03 | `get_health_summary` | `{range: "today"｜"week"}` | 观察 JSON（`artifacts` 见 §4） | `ACD-DB-003`/`ACD-DB-004`/`ACD-SCORE-001` 映射为 `status:"error"` 观察 |
| G-02 → G-03 | `get_recent_meals` | `{limit: int(1..20)}` | 观察 JSON（`artifacts.meals[]`） | `ACD-DB-003` 同上 |
| G-02 → G-03 | `recommend_food` | `{avoid?: string[]}` | 观察 JSON（`artifacts.advice[]`） | `ACD-SCORE-001`/`ACD-KB-001` 同上 |
| G-02 → G-03 | `propose_takeout_search` | `{keyword: string, platforms?: string[]}` | 观察 JSON（`artifacts.cards[]`，0..`G-03-K3` 张） | 无（本工具**无副作用**） |
| G-03 → L3/L4（只读） | `HealthScoreService.score` / `ReportService.scoreWindowFor` / `AdviceEngine.generate` / `StatsRepo.week` / `DietRepo.byRange` | 见 `API-04` §3/§4/§5、`API-03` §4/§5 | 原类型 | 透传映射，**不吞** |
| G-03 → 桥接层 | ❌ **无调用** | — | — | — |

- `propose_takeout_search` 的 `proposalOnly` 恒为 `true`（`API-07` §4.1）；本层**没有任何**启动函数、没有任何 `MethodChannel` 引用（§7 #5 机械判据）。
- 卡片结构见 §4；`SPEC-U-07` 只能**填数值槽位**，不得把工具返回的任意文本当文案渲染（`API-07` §4.3）。

## 4. 数据契约

**卡片值对象（`propose_takeout_search` 产出）**

| 字段 | 类型 | 约束 |
|---|---|---|
| `platformId` | `String` | `meituan` / `eleme` / `taobao` 三值之一（`FF-26j`） |
| `label` | `String` | 取自平台表，用于按钮 |
| `url` | `String` | `https://` 开头；host 与模板一致；含已编码关键词 |
| `verified` | `bool` | `verifiedOn != null` 时为 `true`；`false` **必须**触发 UI 的次要提示 |
| `keyword` | `String` | 明文关键词，长度 ≤ `G-03-K1` 码点 |

**观察 JSON 的 `artifacts` 字段白名单（`FF-26d`）**

| 工具 | 允许的键 |
|---|---|
| `get_health_summary` | `regularity`/`structure`/`snack`/`speed` 四维分数、`totalScore`、`grade`、`recordCount`/`snackCount`/`lateNightCount`/`classCounts`（聚合计数） |
| `get_recent_meals` | `meals[]`，每项**仅** `classId`/`classLabel`/`eatenAtMs`/`confidence` |
| `recommend_food` | `advice[]`，每项**仅** `dimension`/`text` |
| `propose_takeout_search` | `cards[]`（上表五字段）、`skipped`、`invalidPlatforms`、`keyword` |

- **`get_recent_meals` 不得输出 `estimatedKcal`**：热量不在 `FF-26d` 白名单七类之内（`FF-26d` 列的是类别、时间戳、置信度、行为指标、四维分数与评级、聚合计数）。本 SPEC 在此**显式登记**这条排除，并由 §7 #7 的负控守住。
- 全部 `text`/`label`/`summary` 字符串受 `FF-25` 约束（§7 #15 由 `SPEC-G-02` 的同一断言覆盖本层产出）。
- **不新增 schema 文件**、**不新增 SQLite 表**、**不写入任何磁盘文件**。

## 5. 参数与常量

> 逐项引用 `SPEC-00` §3 的 FF 编号；**禁止在此重新写出可能漂移的字面值**。

| 引用 | 用途 |
|---|---|
| `FF-19` | 六个类别的中文标签与 id——`dish` 匹配与 `classLabel` 输出的唯一来源 |
| `FF-26d` | 外发字段白名单（§4 的字段表按它裁剪） |
| `FF-26e` | 禁止清单：本层不得出现 PCM / Mel / 音频路径 / 设备标识 / 位置 |
| `FF-26g` | 单请求与轮次上限（本层不自行设置超时） |
| `FF-26i` | 交接而非代下单；四条禁用路径 |
| `FF-26j` | 平台**恰好三个**；模板与核实状态在 `feature_config.agent` 的 `platform_*` 键 |

> ⚠️ **键名映射（`ADR-44` 实施时确定，此处是权威表）**：平台数据**不是** `feature_config` 里的一个对象数组，而是 `agent` 段内**按平台展平**的标量键。原因见 `PLAN-G-01` §3：`tool/gen_feature_config.dart` 的生成器把顶层标量与被展平的嵌套键投射成 Dart/Kotlin 常量，但**不支持「对象数组」**——加支持会改动一个全项目依赖的生成器，而展平键零改动即可获得同样的单一真源保证。
>
> | 本文档的字段名 | SSOT 真实键（`feature_config.agent.`） | 生成常量 |
> |---|---|---|
> | `httpsTemplate`（美团） | `platform_meituan_url` | `agentPlatformMeituanUrl` |
> | 🆕 `schemeTemplate`（美团） | `platform_meituan_scheme` | `agentPlatformMeituanScheme` |
> | `enabled`（美团） | `platform_meituan_enabled` | `agentPlatformMeituanEnabled` |
> | `verifiedOn`（美团） | `platform_meituan_verified_on` | `agentPlatformMeituanVerifiedOn` |
> | `label`（美团） | `platform_meituan_label` | `agentPlatformMeituanLabel` |
> | 同上四平台字段 | 把 `meituan` 换成 `eleme` / `taobao` | 把 `Meituan` 换成 `Eleme` / `Taobao` |
>
> 🆕 **`ADR-45`：`schemeTemplate` 是用户要求「直接打开手机 APP」的落点。** 启动顺序是
> `canOpenUrl(scheme)` → `openUrl(scheme)` → 失败回落 `openUrl(httpsTemplate)`。
> **scheme 是"尝试"而不是"答案"**：模板未在真机核实过，未装该 App 的设备根本没有 handler，
> 而**丢掉交接是不可接受的结局**。`ProposeTakeoutSearchTool` 的卡片**同时**带上 `url` 与
> `scheme`，UI 不必自己再推导一份（第二份真源就是第二处会漂移的地方）。
>
> `verifiedOn` 为**空字符串**（不是 `null`）表示未核实：生成器会**跳过** `null` 值，那样该常量根本不会存在，于是「未核实」与「字段缺失」将无法区分。文档里写 `null` 的地方一律读作**空字符串**。
| `API-07` §3.3 | `httpsTemplate` / `enabled` / `verifiedOn` 的语义与编码要求 |
| `API-07` §4.1 / §4.2 | 四个工具的参数与观察固定形状 |
| `API-03` §4/§5 | `byRange`（升序、半开区间）与 `WeekSummary` 字段口径 |
| `API-04` §3/§4/§5 | `HealthScoreService` / `AdviceEngine` / `ReportService.scoreWindowFor` 签名 |

**表 G-03-T1 本域新增常量**

| 编号 | 常量 | 取值 | 状态与理由 |
|---|---|---|---|
| `G-03-K1` | 关键词长度上限 | **= `feature_config.agent.recommend_keyword_max_chars`**（SSOT 键，值 `32` 个 Unicode 码点） | ⚠️ **本 SPEC 只引用、不取值**（`SPEC-00` §5 规则 2「只写一次」：数值参数的权威归属是 `feature_config`）。上限的作用是让 URL 长度有界、并让「关键词从设备状态任意推导」这条禁止项无从落地。超限按**码点**截断（§2.4 #8）；**不得**用 `String.substring`（它数的是 UTF-16 码元，会把 emoji 截成孤立代理项，得到一个无法编码的字符串） |
| `G-03-K2` | `get_recent_meals` 的回溯深度 | 最近 `7` 个本地日 | **在此冻结**。该值是**回溯深度**，不是聚合窗口口径；聚合窗口的唯一权威仍是 `API-03` §5 |
| `G-03-K3` | 单次产出卡片数上限 | `3` | `API-07` §4.1 的「1..3」；与 `FF-26j` 的三平台集合等值，故任何一次调用天然满足 |
| `G-03-K4` | `limit` 值域与缺省 | `1..20`，缺省 `10` | 值域取自 `API-07` §4.1；缺省值为本域提案 |
| `G-03-K5` | 关键词占位符 | 字面量 `{q}` | `API-07` §3.3 的模板约定 |
| `G-03-K6` | 截断方式 | 按 **码点** 截断，**不加**省略号 | 省略号会改变检索词并可能被平台解析为标点 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 关键词为空 | §2.2.1 步 5 | `status:"error"` + 三字段，不产出卡片 | 提示换一个说法，**不弹外部 App** |
| 平台表非三个 / 模板非法 | 构建期判据（§7 #2）+ 运行期 §2.2.2 | 构建期红；运行期不产出该平台卡片 | 少一个按钮，不报错、不抛异常 |
| 平台 `enabled == false` | 字段判定 | 不产出卡片，列入 `skipped` | 不显示该平台按钮 |
| 平台未核实 | `verifiedOn == null` | 产出卡片 + `verified:false` | 次要提示「可能打不开」（`API-07` §3.3） |
| 全部平台被跳过 | 过滤后计数为 0 | `status:"warning"` | 「当前没有已启用的平台」 |
| 读库失败 | `ACD-DB-003`/`ACD-DB-004` | 映射为 `status:"error"` 观察（**不抛**） | 工具结果说明失败；页面按 `SPEC-U-07` 展示可重试 |
| 记录数不足 | `recordCount < 3`（`API-04` §4 语义） | 建议只含 `general` 项 | 如实展示，不编造推荐 |
| `WeekSummary` 残缺 | 缺键判定 | 按缺 0 处理（`API-03` §5） | 数字少一份，不报错 |

**核心链路不受影响**：本 SPEC 任一失败路径都**不得**阻断 `P-*`/`D-*`/`A-*`/`M-*`/`U-01`~`U-06`（`FF-26f`）。

## 7. 验收标准（可机器判定）

**统一入口**：`app/tool/agent_tests.dart`（纯 Dart 离线套件，失败即 **exit 非 0**；与 `SPEC-G-02` 同一套件、同一 `verify_all.ps1` 步骤）。**全部 URL 断言确定性、零网络**。
每条新闸门都带负控，负控必须被证明**会变红**。

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | URL 构造确定性且编码正确 | `agent_tests.dart` → `meituan url encodes the keyword` | 给定固定平台表夹具与关键词 `卷心菜 沙拉` → `url` 逐字符等于期望字面量；`Uri.decodeComponent` 还原后逐字等于关键词。**负控**：删掉 `Uri.encodeComponent` → 含空格/中文的用例变红 |
| 2 | 平台表恰为三个 | 同文件 → `platforms are exactly meituan, eleme, taobao` | `feature_config.agent` 的 id 集合逐字相等且长度 == 3（`FF-26j`）。**负控**：追加第四个平台 → 用例变红 |
| 3 | 禁用平台不被提供 | 同文件 → `disabled platform is not offered` | 夹具中 `enabled:false` 的平台 → `cards` 中该 `platformId` 命中 0，且出现在 `skipped`。**负控**：忽略 `enabled` 字段 → 该 id 进入 `cards`，用例变红 |
| 4 | 未核实平台被如实标注 | 同文件 → `unverified platform is reported as unverified` | `verifiedOn:null` 的平台产出的卡片 `verified == false`；`verifiedOn` 非空 → `true`。**负控**：把 `verified` 硬编码为 `true` → 用例变红 |
| 5 | 本层不启动任何外部 App | 静态检索 `app/lib/domain/agent/tools/**` 与 `check_network_boundary.py --strict` | `MethodChannel`/`startActivity`/`url_launcher`/`AccessibilityService` 命中 **0**；`HttpClient`/`Socket` 命中 **0**；`proposalOnly == true` 有独立断言。**负控**：加入一行 `MethodChannel` 构造 → 检索命中数 > 0，闸门变红 |
| 6 | 全仓无无障碍代操作 | 构建期文本检索（并入 `verify_all.ps1`） | 全仓 `AccessibilityService` 命中 **0**（`FF-26i`）。**负控**：加一个空 `AccessibilityService` 子类桩 → 命中数 > 0，闸门变红 |
| 7 | 外发字段落在 `FF-26d` 白名单内 | 同文件 → `observation fields stay inside the egress whitelist` | 四个工具产出的所有键 ⊆ §4 白名单；**`get_recent_meals` 输出的 `meals[]` 键集恰为四字段**。**负控**：给 `meals[]` 添上 `estimatedKcal` → 用例变红 |
| 8 | 关键词长度有界且确定性 | 同文件 → `keyword is capped and stable` | 64 码点输入 → `keyword.runes.length <= G-03-K1`；同输入 100 次逐字相同；不含省略号 |
| 9 | 前三个工具不新造分数 | 同文件 → `tools reuse the domain services verbatim` | `get_health_summary` 的分数逐字段等于 `HealthScoreService.score` 的输出；`recommend_food` 的 `text` 逐字等于 `AdviceEngine.generate` 的输出（去 `avoid` 情形）。**负控**：在工具内自行加总四维分数 → 与 service 输出不等，用例变红 |
| 10 | 关键词只来自本地状态 | 同文件 → `keyword derives only from the user turn and local advice` | 关键词的构成可还原为 `[dish, anchor]`；同输入 100 次相同；无 `DateTime.now()`/设备标识参与。**负控**：把关键词拼上设备标识 → 断言变红 |
| 11 | 模板非法时诚实降级 | 同文件 → `invalid template is reported not offered` | 缺 `{q}` / host 不一致 / 非 https 的夹具 → 不产出卡片且列入 `invalidPlatforms`。**负控**：缺 `{q}` 时直接原样返回模板 → 断言变红 |
| 12 | 空白关键词不产出卡片 | 同文件 → `empty keyword yields no card` | 空 `anchor` + 无匹配 `dish` → `cards.length == 0` 且 `status == "error"` |
| 13 | 层纯净与网络单点 | `python tool/check_l4_usage.py --strict` + `python tool/check_network_boundary.py --strict` | 两步 exit `0`；`app/lib/domain/agent/tools/**` 无 `package:flutter` |
| 14 | 红线词表 | 同文件 → `card and summary strings avoid FF-25 terms` | 卡片 `label`/`keyword`/`summary` 对 `FF-25` 词表命中 **0**。**负控**：写入词表内一个词 → 用例变红 |
| 15 | 套件接入总闸门 | `pwsh -File tool/verify_all.ps1` | 步骤清单包含 agent 套件且总数与 `SPEC-G-02` §7 #16 一致；套件失败时总闸门 exit 非 0 |

## 8. 非功能约束

| 项 | 约束 |
|---|---|
| 语言与层 | **纯 Dart**。`app/lib/domain/agent/tools/**` 不得 import `package:flutter`；不得引用 `HttpClient`/`Socket`/`MethodChannel` |
| 依赖 | **零新增 pub 依赖**（不用 `url_launcher`，不联网校验可达性） |
| 网络 | 本层**不发起任何网络请求**：URL 只被**构造**，不被**访问**（`R-OUT-4`：出网单点仍在 `SPEC-G-01`） |
| 隐私 | 关键词只由用户本轮文本与本地推荐构成；不读设备标识、位置、网络、通讯录（`FF-26e`）；不写磁盘 |
| 权限 | 本层不需要任何新权限；不触发 `INTERNET` 之外的行为（`FF-24` 第 5 条） |
| 权限边界说明 | `API-07` §3.4 的 `<queries>` **不是权限**，不进入 `uses-permission`，不影响 `SPEC-C-01` §7 的权限集合等式；本层不涉及它 |
| 功耗 | 无轮询、无网络探测；成本与一次字符串拼接同阶（**数值**【待实测】） |
| 无障碍 | 卡片必须可用纯文本表达平台名与核实状态（`verified:false` 不得只靠颜色）；由 `SPEC-U-07` 落实，本层提供布尔字段 |

## 9. 裁剪与未做

| 项 | 决定 |
|---|---|
| 代下单、模拟点击、代填地址、代付款 | ❌ 不做（`FF-26i`）。对外口径只能是「帮你想好点什么，并一键跳到外卖 App 的搜索结果」（`API-07` §3.1） |
| `AccessibilityService` | ❌ 不做，且**不得**以可选项形式出现在代码或 Manifest 中 |
| 逆向客户端私有接口 | ❌ 不做（违法且随版本失效） |
| 第四及以后的外卖/电商平台 | ❌ 不做（`FF-26j`；扩展须走 `SPEC-C-03`） |
| 比价、门店检索、配送范围、起送价、优惠券 | ❌ 不做 |
| 检索词的持久化与「最近搜索」 | ❌ 不做（`X-03` 的导出同理不涉及） |
| 账号体系、平台登录 | ❌ 不做（`X-01` 仍在裁剪登记） |
| 用网络探测平台可达性 | ❌ 不做（`API-07` §3.3 明确要求真机人工核实） |

## 10. 开放问题

| 编号 | 问题 | 影响 | 待谁拍板 |
|---|---|---|---|
| OQ-G03-1 | `API-07` §4.1 写「产出 **1..3** 张卡片」，而三平台全部 `enabled == false` 时**诚实结果是 0 张**。需裁定：① 允许 0 张 + `warning`（本 SPEC 当前取法），还是 ② 补一张「当前没有已启用的平台」的**说明卡**。二者都要与 `API-07` §4.1 的表述对齐 | 卡片数断言与 UI 空态 | B + C，`SPEC-U-07` 开工前 |
| OQ-G03-2 | 三平台的真机核实**未完成**：`API-07` §3.3 已记录「美团路由存在但真机未核实 / 淘宝未核实 / 饿了么很可能不可用」。本 SPEC 不得把未核实模板呈现为可用，因此交付时很可能只有 1..2 个平台 `enabled == true` | 现场可用平台数 | B（真机核实），`SPEC-U-07` 联调前 |
| OQ-G03-3 | §2.2.1 步 2 的 `dish` 用**文案子串匹配** `FF-19` 类别名，是启发式：规则 4/5 的文案不含类别名，此时 `dish` 为空、关键词退化为仅用户消息。是否需要 `AdviceEngine` 增一个**结构化**类别字段（会改 `API-04` §4，须走 `SPEC-C-03` 变更传播） | 关键词的相关性 | C 主提，A/B 确认 |
| OQ-G03-4 | `G-03-K4` 的 `limit` 缺省值 `10` 与 `G-03-K2` 的 7 天回溯深度均为本域提案；若某周记录很少，`limit` 会被窗口自然截短 | 结果条数 | C |

**文档结束**
