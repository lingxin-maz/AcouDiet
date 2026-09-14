# Gemma 归属与许可材料（草案）

> ⚠️ **这不是法律意见，也还不是可直接发布的成品。** 本文件是一份**待核对草案**：
> 标着 `【待核对】` 的每一处，都必须由人打开官方条款逐字确认后才能去掉标记。
> 本机 DNS 对 `huggingface.co`、`ai.google.dev` 等站点返回非公网 IP，**条款原文无法在本环境取证**
> —— 所以本文件里没有任何"我查过条款，结论是 X"的句子。

**文档性质**：合规材料 + 打包前检查表
**触发场景**：把 `建议模型/` 的权重打进 APK 对外分发（方案 B）
**不适用场景**：方案 A（编译期冻结文案）—— 那条路线不打包权重，本文件不涉及

---

## 1. 事实：这份权重到底是什么

以下每一条都是**本机实测**（权重文件在 `建议模型/`，解析脚本见 §6），不是转述：

| 项 | 实测值 | 来源 |
|---|---|---|
| 文件名 | `model.safetensors` | 目录列举 |
| 大小 / 精度 | 536,223,056 B，**全部 BF16**（236 个张量无一例外） | safetensors header 解析 |
| 参数量 | 268,098,176（≈270M） | 同上，按 shape 累乘 |
| 架构 | `Gemma3ForCausalLM` / `model_type: gemma3_text` | `config.json` |
| **基座** | **`unsloth/gemma-3-270m-it`** | `config.json:39` |
| 微调痕迹 | `unsloth_fixed: true`，`unsloth_version: 2026.3.11` | `config.json` |
| 上下文 | `max_position_embeddings: 32768`，`sliding_window: 512`，滑动/全注意力每 6 层交替 | `config.json` |
| 词表 | 262,144，tied embedding | `config.json` + shape |
| tokenizer | `GemmaTokenizer`，33,384,443 B，**含 CJK**（汉字 54,367 / 假名 29,404 / 谚文 14,007 次出现） | `tokenizer_config.json` + 词表统计 |
| chat template | Gemma 3 `<start_of_turn>` 格式 | `chat_template.jinja` |
| 官方卡自称许可 | `license: apache-2.0` | `README.md` YAML front-matter |
| README 语言标注 | `language: [en]` | 同上 |
| README 声称量化 | 「4-bit Quantized / FP16 Mixed」 | 同上 —— **与实测不符，实测是全 BF16** |

> 📌 **实测与卡面矛盾这一条本身就要留档。** 对上游交付物的描述与实际不符，是"作者未验证"的信号；
> 在答辩/审计里，这比"模型小"更值得说明。

---

## 2. 结论：为什么**不能**只写一句 `apache-2.0`

这是一份 **Gemma 系模型的衍生权重**（微调自 `gemma-3-270m-it`）。

- 上游卡上的 `apache-2.0` 只可能覆盖**权重发布者自己贡献的那一层**；
- 基座本身的许可是 **Gemma 条款**（同源社区量化件的 README 标的正是 `license: gemma`）；
- 衍生作品通常需要**继承并传递**基座的条款与**使用政策**（Use Policy）；
- tokenizer 也是 Gemma 系（`GemmaTokenizer`），它的分发条件与权重**不是同一件事**，须单独确认。

因此：

> **本项目对外分发时，必须把"这是 Gemma 衍生模型"如实写出，并按 Gemma 条款履行归属与使用政策传递义务。**
> 把整个制品简单标注为 `apache-2.0` 是**不准确**的，且可能构成条款违反。

---

## 3. 【待核对】清单（发布前必须逐条打勾）

| # | 需确认的事项 | 为什么必须确认 | 状态 |
|---|---|---|---|
| L1 | Gemma 条款原文 + **Gemma Prohibited Use Policy** 现行版本 | 决定"健康/营养建议"这一用途是否被允许、是否需额外声明 | 【待核对】 |
| L2 | 分发衍生权重时**必须随附**的文本（NOTICE / 条款副本 / 归属声明形态） | 缺少随附文本是典型的合规缺口 | 【待核对】 |
| L3 | Gemma 条款是否包含**使用政策传递（pass-through）**义务，以及具体措辞 | 决定 App 内是否必须展示政策链接/声明 | 【待核对】 |
| L4 | tokenizer 的分发条件是否与权重相同 | tokenizer 是独立制品，许可往往另行声明 | 【待核对】 |
| L5 | 上游发布者标注 `apache-2.0` 与基座许可的**关系**（是否有权如此标注） | 上游标注不等于基座授权，风险在本项目落地时分发时体现 | 【待核对】 |
| L6 | 是否要求向 Google 提交**衍生模型登记** | 部分 Gemma 版本有此要求 | 【待核对】 |
| L7 | 微调所用语料的来源与许可（Smolify 称"合成蒸馏"） | 语料许可不明也是一个独立风险面 | 【待核对】 |

> 🔴 **L1 与 L2 未清之前，不应产出对外分发的 Release APK。**
> 内部测试包（不对外发）不受此限。

---

## 4. 随包归属文本（模板，待 §3 确认后定稿）

> 放入 `app/assets/llm/NOTICE.txt` 并在 `U-05 我的与设置` 的许可页可达。
> **方括号内为待填/待核对内容，不要在核对前删掉方括号。**

```text
本应用包含端侧语言模型权重 acoudiet-nia（文件名 acoudiet-nia-q4_k_m.gguf）。

该权重是 Gemma 系模型的微调衍生作品，基座为：
    gemma-3-270m-it
    Copyright [年份] Google LLC
    依据 [Gemma 条款的准确名称与版本，见 L1] 提供
    [条款正文位置：assets/llm/LICENSE-GEMMA.txt，见 L2]

微调与蒸馏由 smolify 完成（原始发布：smolify/smolified-nutriai-distilled-nutritionist）。
本应用的量化（bf16 → Q4_K_M）与打包由 [本项目/操作人] 完成。

分词器：GemmaTokenizer（随模型分发，其分发条件见 [L4 的确认结果]）。

本应用不含任何网络权限，模型权重在构建期打包进 APK，运行时不上传、不下载、不更新。
```

**同时需要改的地方**（否则隐私/宣传口径会自相矛盾）：

| 位置 | 现状 | 需要改成 |
|---|---|---|
| `pubspec.yaml` 描述 | 「v1.0 ships with no cloud backend and no INTERNET permission」 | 仍然成立，**但不要写成"无模型/纯本地规则"** |
| `AndroidManifest.xml` | 仅 `RECORD_AUDIO` | **不变**（端侧推理不需要网络） |
| `API-05 §9.1 T1` | 「引入 LLM 健康助手」= v2.0 触发条件 | 需新增裁定：**端侧 LLM 不触发云端协议**（因为它没有网络出口） |
| `SPEC-A-02 §1.3` | 「不接入 LLM 或任何网络服务」 | 须修订为「不接入**网络服务**；建议文案可由**端侧**模型改写，且不改变数字与条数」 |
| `SPEC-C-01 §7` 判据 | 权限集合 == `{RECORD_AUDIO}` | **不变**（这是端侧路线唯一的、也是最大的优势） |

---

## 5. 体积与发布流程影响（把代价写清楚）

| 项 | 现在 | 打包 bf16 → Q4_K_M 后 |
|---|---|---|
| 权重 | 不在包内 | ≈ 150–180 MB（估算；**以实测为准**） |
| tokenizer | 不在包内 | ≈ 33 MB（APK 内可压缩，落地约 4–6 MB） |
| 运行时 `.so` | 仅 TFLite | 另加数 MB（llama.cpp 或 LiteRT） |
| release APK | 25,533,450 B | **估算 180–210 MB** |

> ⚠️ **表里的数字是估算。** 真实值必须在制品产出后实测，并回填本表 —— 本项目的惯例是不把估算当结论。

**发布流程上会被打破的既有断言**（必须同步修改，否则门禁会红）：

| 位置 | 断言 | 影响 |
|---|---|---|
| `specs`/`FF-16` 关于模型体积的口径 | 资产体积上限（fp32 ≤ 6 MB / int8 ≤ 2.5 MB） | 该口径针对**声学模型**；LLM 权重必须**另立一条**口径，不能混用 |
| `tool/verify_artifacts.py` | 「`assets/models/` 恰一份模型制品」 | 因此 LLM 权重**不得**放进 `assets/models/`，应放 `assets/llm/` |
| `tool/verify_all.ps1` 16 步 | 体积/权限相关步骤 | 需新增「LLM 资产存在性 + 许可文本可达」一步 |
| `docs/compliance/C-01_privacy_checklist.md` | 七条 FF-24 约束 | 第 1/3/6 条**不受影响**（仍无音频落盘、仍无网络、仍无后台 Service），但需补一句"模型权重为构建期资产" |

---

## 6. 复现本文件的实测（供复核）

```powershell
# 权重元数据（dtype / 参数量 / 张量名）：读 safetensors 的 JSON header，不加载张量本身
$p='D:\Desktop\Food\建议模型\model.safetensors'
$fs=[System.IO.File]::OpenRead($p); $br=New-Object System.IO.BinaryReader($fs)
$len=$br.ReadInt64(); $json=[System.Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$len)); $fs.Close()
$h=$json|ConvertFrom-Json
($h.PSObject.Properties | Where-Object { $_.Name -ne '__metadata__' }).Count   # 236
($h.PSObject.Properties | Where-Object { $_.Name -eq 'model.embed_tokens.weight' }).Value.dtype   # BF16

# tokenizer 的 CJK 覆盖：读 tokenizer.json 全文本统计
#   汉字 [\u4e00-\u9fff] = 54367；假名 [\u3040-\u30ff] = 29404；谚文 [\uac00-\ud7af] = 14007
```

---

## 7. 如果最终不做端侧分发

方案 A（编译期冻结文案）下**本文件的 §4 归属模板不再需要**，因为 APK 里不含任何 Gemma 衍生权重。
但那一路线仍需保留一条说明：文案由**离线**模型辅助生成、后经人工审定冻结 ——
这与"App 内运行 LLM"是两件完全不同的事，**不要混为一谈**。
