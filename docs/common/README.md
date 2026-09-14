# 跨端公共文档索引（`docs/common/`）

**定位**：**前端与后端都要遵守**的约定、合规要求与工程底座。
**规模**：5 个功能 + 2 份章节级文档 + 2 份跨端接口契约 + 6 份 JSON Schema。
**总索引**：`docs/README.md` ｜ 冲突裁定：`docs/01_裁定记录ADR.md`

---

## 1. 什么会落在这里

判据只有一条：**它是不是"只跟一端有关"**。

| 落 `common/` | 落 `frontend/` | 落 `backend/` |
|---|---|---|
| 两端都要遵守的**约定** | 用户看得见、点得到的**界面** | 设备内采集/计算/存储、离线训练 |
| 合规与伦理、SSOT、构建、测试 | `U-*`、`M-03`、`M-04` | `P-*`、`D-*`、`A-*`、`T-*`、`M-01`、`M-02` |
| 例：`C-03` 管的是**两侧都要读同一个 `feature_config`** | | |

**"跨端"不等于"不重要"**：`C-03`（SSOT 与变更传播）是**四个硬闸门之一**，它坏了两侧的 Mel 参数就会各写一套，模型直接失效且**不报错**。

---

## 2. 目录

```
docs/common/
├── README.md                              ← 本文件
├── SPEC-00_总则与冻结事实.md                 ★ 宪法：FF-01~FF-25 冻结事实 + 文档模板 + 写作禁令
├── PLAN-00_总排期与依赖.md                   ★ D0–D10 + 4 个检查点 + 工时预算
├── docs_api/
│   ├── API-00_接口总览与约定.md              分层边界 / 命名 / 30 个错误码登记表 / 握手 / 背压
│   ├── API-05_后端数据通讯规范.md            ★ 「无云端后端」裁定 + 数据流向 + 制品契约 + v2.0 预留协议
│   └── schemas/                            6 份机器可校验契约（draft-07）
│       ├── feature_config.schema.json
│       ├── diet_record.schema.json
│       ├── health_score.schema.json
│       ├── foods.schema.json
│       ├── metrics.schema.json
│       └── sync_envelope.schema.json
└── docs/
    ├── C-01_权限最小化与无网络权限可验证/{SPEC,PLAN}
    ├── C-02_知情同意与数据伦理归档/
    ├── C-03_feature_config单一真源与变更传播/
    ├── C-04_构建签名与发布/
    └── C-05_测试与回归套件/
```

> **`SPEC-00` 与 `PLAN-00` 是本节唯一的"不成对"文档**：它们是章节级文档（宪法与总排期），本就不需要 PLAN/SPEC 配对。`verify_docs.py` 已把这一例外写进规则。

---

## 3. 功能清单（5）

| 编号 | 名称 | 一句话 | 归属 | 目标日 | 状态 |
|---|---|---|---|---|---|
| `C-01` | 权限最小化与无网络权限可验证 | Manifest 仅 `RECORD_AUDIO`；`aapt dump badging` 留证；飞行模式全流程验证 | B | D4 | ✅ |
| `C-02` | 知情同意与数据伦理归档 | 同意书 7 条 + 先签后用 + 归档（姓名打码） | C | D0 | ✅ |
| `C-03` | **`feature_config` 单一真源与变更传播** | SSOT（**49 键**，`ADR-21`）+ 双侧读取 + **15 字段**握手（`ADR-21`；原 ~~12~~）+ 14 项变更单 | A+B | D0→D1 | ✅ **硬闸门** |
| `C-04` | 构建、签名与发布 | release 签名、`flutter build apk`、体积与权限复核、D10 代码冻结 | B | D9→D10 | ✅ |
| `C-05` | 测试与回归套件 | 一致性测试 / 防泄漏 / 数值对齐 / 隐私回归 / 演示前清单 | A+B | D3→D9 | ✅ |

---

## 4. 为什么这 5 项必须跨端

| 编号 | 前端会碰它吗 | 后端会碰它吗 |
|---|---|---|
| `C-01` | 是 —— 权限弹窗与「去设置」引导在 UI 上 | 是 —— `AudioRecord` 与 Manifest 由原生持有 |
| `C-02` | 是 —— 隐私声明页在 `U-05` | 是 —— 数据匿名编号 `P01…` 进数据集 |
| `C-03` | 是 —— `feature_config.dart` 常量由前端读 | 是 —— Kotlin 常量 + Python 训练脚本 |
| `C-04` | 是 —— 前端资源与文案进 APK | 是 —— 模型与 `foods.json` 打包进 `assets/` |
| `C-05` | 是 —— 跨功能一致性测试断言「评分卡数字 == UI 数字」 | 是 —— parity / 对齐 / 防泄漏断言 |

---

## 5. 四道机械验收（**交付前必须全绿**）

```powershell
# 1) 环境（预期 PASS=28 FAIL=0）
. D:\Desktop\Food\_toolchain\acoudiet-env.ps1
python D:\Desktop\Food\_toolchain\verify_env.py

# 2) 规格文档（预期 BLOCKER × 0）
python D:\Desktop\Food\_toolchain\verify_docs.py

# 3) 无网络（预期输出中不含 INTERNET）
aapt dump badging app-release.apk | findstr uses-permission

# 4) 旧值零残留（预期命中 0，历史对比表除外）
rg -n "3s|3 秒|hop.*160|帧移 10"
```

---

## 6. 与两端的关系（引用约定）

- **引接口用编号**：写 `API-03`，不要写路径。指整个契约目录时用 `docs/*/docs_api/`。
- **引功能用编号**：写 `SPEC-P-04` / `PLAN-C-03`。
- **数值只引用 FF 编号**：写「见 FF-04」，**不要复制字面值** —— 复制就是漂移的开始（`SPEC-00` §5 规则 2）。
- **跨层口径冲突一律以 `docs/*/docs_api/` 为准**（`ADR-10`）。

---

**文档结束**
