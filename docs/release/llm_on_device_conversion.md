# 端侧建议模型（NIA）落地清单

**目标**：把 `建议模型/` 的 bf16 safetensors 变成手机上能加载的制品，并让 App 在**报告页**
用它对 A-02 的建议做文字改写。

**当前状态（实事求是）**

| 环节 | 状态 |
|---|---|
| Dart 侧接线（端口 / 提示词 / 护栏 / 回落 / 装配） | ✅ **已完成并跑过离线测试** |
| C shim（`acoudiet_llm_shim.c/.h`，把 llama.cpp 的结构体参数关在 C 里） | ✅ **已写完**（编译需 NDK + llama.cpp，见 §5.1） |
| Dart ↔ shim 绑定 + 解码 → UTF-8 全链路 | ✅ **已写完并通过离线测试**（`test/domain/llm_engine_adapter_test.dart`） |
| Android 构建脚本（llama.cpp + shim → `.so`） | ✅ **已写完**：`tool/build_acoudiet_llm_shim.ps1` |
| 制品（GGUF） | ❌ **未产出**（本机无转换链、无网络） |
| `.so` 产物 | ❌ **未产出**（本机无 NDK、无 llama.cpp 源码） |
| 许可材料 | ⏳ 草案已成：`docs/release/gemma_attribution_and_license.md`，7 条待核对 |

> ⚠️ **Dart 侧已经完全就位，不需要再改代码。** 重量级的两件事——转换与编译——必须在
> **另一台能联网、装了 Android NDK 的机器**上做，产物拷回来即可。
> 本机 Python 3.7 / torch 1.13、无 `transformers`、无 `llama.cpp`，且 `huggingface.co`
> 被 DNS 拦（`198.18.0.33`），所以这一步在本机无法完成。

---

## 1. 第 0 步：先量，别先转

在动手转换之前，先把下面三件事量出来。**任何一项不过，就不要继续**——否则得到的只是
"包大了 180 MB、建议质量没变"。

| # | 判据 | 判据说明 | 不过就停的理由 |
|---|---|---|---|
| P0-1 | **中文输出可用** | 用下面的提示词跑 20 条真实 facts，人工读：是不是通顺中文、有没有夹英文 | README 标 `language: [en]`；tokenizer 认汉字（实测 54,367 个汉字 token）**不代表**微调语料有中文 |
| P0-2 | **不编数字** | 看 20 条输出里有没有一个阿拉伯/中文数词 | `FF-25` 红线；护栏会拦，但"全靠护栏拦"说明模型不可用 |
| P0-3 | **优于纯规则基线** | 现有 5 条规则文案 vs 模型改写，人工盲评（同一批 facts） | `模型选型调研 §10.2` 已预告："纯规则基线必须参赛，大概率它会赢" |

**第 0 步用的提示词**：直接取 `app/lib/domain/service/nutrition_advice_prompt.dart` 的
`NutritionAdvicePrompt.build(...)` 输出（它就是喂给模型的原文，含系统指令与红线词表），
facts 用 `app/assets/demo_dataset.json` 推导出的四条：零食次数、晚间次数、平均咀嚼间隔、类别数。

---

## 2. 环境预检（联网机器）

```bash
python -c "import sys, torch, transformers; print(sys.version); print(torch.__version__); print(transformers.__version__)"
# 需要：Python >= 3.10，torch >= 2.1，transformers >= 4.50（gemma3 架构）
```

不满足就先建隔离环境（`python -m venv`），再装：

```bash
pip install "transformers>=4.50" "torch>=2.1" sentencepiece safetensors
```

---

## 3. 转 GGUF

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
pip install -r requirements.txt

# 转换：输入是「建议模型/」那个目录（已含 config.json / tokenizer.json / chat_template.jinja）
python convert_hf_to_gguf.py /path/to/建议模型 \
    --outfile acoudiet-nia-f16.gguf \
    --outtype f16

# 量化：Q4_K_M 是体积/质量权衡的默认档
./llama-quantize acoudiet-nia-f16.gguf acoudiet-nia-q4_k_m.gguf Q4_K_M
```

**验收**：查看转换输出里的**张量数与层数**，必须与实测元数据一致（见 §6）。

> 📌 输入目录里 `tokenizer.json` 是 33 MB 的 **tokenizers 格式**；`convert_hf_to_gguf.py` 会优先用它。
> 若脚本要求 `tokenizer.model`（SentencePiece 原始文件），需要从基座 `unsloth/gemma-3-270m-it`
> 取同一份 —— **这也属于分发物，许可问题见归属文档 L4**。

---

## 4. 与原始模型做数值对齐（**这一步不能省**）

本项目的声学模型有一条 `T-08` 跨语言 Mel 对齐闸门（`atol=1e-3`）。LLM 这一侧同样需要一条
**同 prompt 同 seed 的对照**，否则"模型换成了量化版、输出变了"没有任何基线可查。

```bash
# 参考侧：transformers + bf16 原始权重，贪心解码
# 候选侧：llama.cpp + Q4_K_M，greedy
# 输入：同一个 prompt（§1 的那一段）
```

| 判据 | 期望 | 记录位置 |
|---|---|---|
| 同 prompt 下两端**输出文字一致或语义等价** | 记录差异，若差异明显则不可接受 | 本文件 §7 回填 |
| Q4 量化前后（F16 vs Q4_K_M）输出一致性 | 同上 | 同上 |
| 生成速度（tokens/s）、峰值内存 | 记录实测值，**不要写估算** | 同上 |

---

## 5. 接入 App

### 5.1 C shim（**已完成，只剩编译**）

`llama_model_load_from_file` 与 `llama_init_from_model` 都吃**按值传递的结构体**，
`dart:ffi` 无法表达，而且字段布局随 llama.cpp 版本变化。所以本项目把结构体参数关在 C 里：

| 文件 | 作用 | 状态 |
|---|---|---|
| `app/android/app/src/main/cpp/acoudiet_llm_shim.h` | 5 个导出符号的契约 | ✅ 已完成 |
| `app/android/app/src/main/cpp/acoudiet_llm_shim.c` | 默认参数 + 转发（无业务逻辑） | ✅ 已完成 |
| `app/lib/data/native/llama_llm_engine.dart` | 绑定这 5 个符号 + UTF-8 解码 | ✅ 已完成并通过离线测试 |
| `tool/build_acoudiet_llm_shim.ps1` | NDK 构建 → `jniLibs/<abi>/` | ✅ 已完成，**待在你机器上执行** |

导出的 5 个符号：

```c
void *acoudiet_llm_create(const unsigned char *bytes, size_t len, int n_ctx);
int   acoudiet_llm_generate(void *h, const char *prompt, char *out,
                            int out_cap, int max_tokens, int max_ctx);
const char *acoudiet_llm_last_error(void);
const char *acoudiet_llm_version(void);
void  acoudiet_llm_free(void *h);
```

编译（**需要 Android NDK + llama.cpp 源码**）：

```powershell
pwsh -File tool\build_acoudiet_llm_shim.ps1 `
    -LlamaCpp D:\src\llama.cpp `
    -Ndk "$env:ANDROID_NDK_HOME" `
    -Abis arm64-v8a
```

脚本会先检查 `llama_model_load_from_buffer` 是否存在 —— Android 上asset 不是文件系统路径
（`ADR-22` 的实测教训），所以**必须**从内存加载权重，这条不可降级。

> 📌 若你的 llama.cpp 用的是别的符号名（例如把内存加载拆成了别的入口），
> 改 `acoudiet_llm_shim.c` 的 `acoudiet_llm_create` 内部即可，**Dart 侧不用动**。
> 这正是这层 shim 存在的意义。

### 5.2 制品放哪

```
app/assets/llm/acoudiet-nia-q4_k_m.gguf     ← 权重（默认路径见 defaultWeightPath）
app/assets/llm/NOTICE.txt                   ← 归属文本（见许可文档 §4）
app/assets/llm/LICENSE-GEMMA.txt            ← 条款副本（待 L2 确认后放）
app/android/app/src/main/jniLibs/<abi>/libacoudiet_llm.so  ← 运行时（§5.1 的产物）
```

**不要放 `app/assets/models/`**：那是声学模型的 drop-in 区，
`tool/verify_artifacts.py` 断言那里"恰一份模型制品"（本仓该断言目前 PASS），
混进去会直接打破它。

`pubspec.yaml` **已经加好**（`assets/llm/`，与 `assets/models/` 同做法），
`app/assets/llm/README.md` 也已就位 —— 所以这个目录是存在的，Flutter 构建不会因为
"声明了一个不存在的资产目录"而失败。

### 5.3 需要在报告页调用

`ReportService.polishedAdvices(range: ...)` 已经就位，返回 `PolishOutcome`。渲染要求：

| 要求 | 原因 |
|---|---|
| `outcome.items` 顺序渲染 | 与规则引擎的顺序一致（`priority` → `dimension` → 声明序） |
| 免责声明仍渲染末位的 `general` 项 | 逐字冻结，**不经模型** |
| **`outcome.degraded == true` 时不做任何额外提示** | 缺模型是正常状态；弹提示等于把内部状态暴露给用户 |
| 需要展示时，用 `outcome.modelId` / `runtimeVersion` / `latencyMs` | 只进自检面板，不进报告正文 |

---

## 6. 复核本清单引用的实测数据

```powershell
# 权重元数据（无需加载张量）
#   236 个张量 / 268,098,176 参数 / 全部 BF16 / 536,223,056 B
#   基座 config.json: "model_name": "unsloth/gemma-3-270m-it"
#   tokenizer.json 含汉字 54,367 / 假名 29,404 / 谚文 14,007
# 逐条命令见 docs/release/gemma_attribution_and_license.md §6
```

---

## 7. 回填表（每完成一步就填，**不填估算值**）

### 7.1 已实测（2026-09-13，Windows 宿主机）

| 项 | 实测值 | 备注 |
|---|---|---|
| GGUF F16 体积 | **542,834,176 B** | sha256 `ea227355…754f` |
| GGUF Q4_K_M 体积 | **253,113,856 B** | sha256 `17fb352a…c530`；**比估算的 150–180 MB 大** |
| Q4_K_M 位宽 | 7.36 BPW | `llama-quantize` 报告；90/236 张量走了 fallback |
| 生成速度（x86 宿主机，Q4_K_M） | **≈ 101–111 tokens/s** | `llama-cli`，贪心 |
| prompt 处理 | ≈ 1200–1450 t/s | 短 prompt |
| 模型能否加载 | ✅ 能 | 236 张量全部识别，词表对齐（`hello` → 23391） |
| 中文输出能力 | ❌ **不能** | 见 §7.2 —— 这是**阻断性发现** |
| 英文输出质量 | ✅ 通顺、切题 | 但会编造数字（见下） |
| 运行时 `.so` 体积 | 【待测】 | 需要 NDK 编译，本机无 NDK |
| release APK 体积 | 【待测】 | 权重单独 253 MB，打包后必然 ≥ 280 MB |

### 7.2 🔴 阻断性发现：这个模型**不会说中文**

`docs/release/llm_on_device_conversion.md` §1 把"中文输出可用"列为 P0-1 关卡。实测**未通过**：

| 测法 | 输入 | 输出 |
|---|---|---|
| 中文输入 | `请用简体中文回答：本周零食吃了很多次，建议少吃薯片。` | `The food is too high-calorie. Cut the calories and add a small portion of protein to your meal tonight.`（**英文，且答非所问**） |
| 中文输入 | `你是营养建议润色助手。请把这句话改写得自然一些：进食速度偏快，建议放慢进食节奏。` | `You are in a nutrient-deficient state. Your progress is stalling...`（**英文**） |
| 英文指令 + 强制中文 | `Reply in Simplified Chinese only. Rewrite this sentence naturally: ...` | **一个 token 都没生成**（`Generation: 0.0 t/s`） |

结论：
* 该模型**没有可用的中文生成能力**，且**不理解"用中文回答"这条指令**；
* 这与它 README 的 `language: [en]` 一致 —— tokenizer 认识汉字（词表含 54,367 个汉字 token），
  但**微调语料是英文**，所以"能分词"不等于"能说"；
* 同一批测试里模型还**编造了数字**（`cut your protein intake by 20%`），
  而事实里只有"snack 5 times" —— 这正是护栏要拦的东西（`has_number`）。

**因此：A-02 的润色层在当前制品上无法交付。** 理由不是工程质量，而是
**产品的建议文案必须逐字是中文**（`SPEC-A-02 §4`、A-02-K11 ≤40 字）。

> 已实现的护栏会在这种情况下**全部拦下**，于是 `PolishOutcome.degraded == true`、
> 建议原样走规则文案 —— 也就是**用户什么改变都看不到**。
> 换句话说：模型进了 APK，体积涨到 ~280 MB，功能却与不进一样。
> 这不是"效果打折"，是**纯粹的代价**。

### 7.3 待测（需要 Android 侧）

| 项 | 值 | 日期 |
|---|---|---|
| 运行时 `.so` 体积（按 ABI） | **x86_64 = 5,259,640 B (5.02 MB)；arm64-v8a = 4.87 MB** | 2026-09-13 ✅ **已产出** |
| 16 KB 页对齐（Android 15 要求） | ✅ 三个 LOAD 段对齐 `0x4000` | 2026-09-13 |
| 导出的 shim 符号 | ✅ 5 个全部 `GLOBAL DEFAULT`（`acoudiet_llm_create/generate/last_error/version/free`） | 2026-09-13 |
| release APK 体积（打包后） | 【待测】 | 需要可运行 Flutter 的机器 |
| 目标机首 token 时延 / 峰值内存 | 【待测】 | 同上 |

### 7.4 🔴 发现二：**润色层在真实数据上没有东西可改**（ADR-26 之前）

> **本节记录的是"发现问题的状态"，已由 `ADR-26` 修复。** 现在同一份数据下是
> **4 / 5 条送进模型**（详见本节末尾的复测）。

把 `app/tool/probe_polishable_advice.dart` 跑在演示数据上（命中规则 1/2/3 的那一周），
规则引擎产出 5 条建议，**旧口径下可改写条数 = 0 / 5**：

```
[regularity] 有 3 次进食发生在晚间，建议把正餐与加餐安排得更早一些。
[snack     ] 本周零食 9 次，建议减少薯片与软糖的频率，两餐之间可优先选择卷心菜或胡萝卜。
[speed     ] 本周平均咀嚼间隔约 0.4 秒（偏快），建议放慢进食节奏。
[structure ] 本周记录到的食物只有 2 类，建议主食与蔬果类都出现一些。
[general   ] 提供日常健康管理建议，不进行疾病诊断，不替代专业医疗意见
```

全部含数字（连「**两**餐之间」的「两」都被 `AdviceTextGuard` 算作数词），
而旧版 `NutritionAdviceService._targetsFor` **刻意把含数字的句子排除在改写之外**
（因为"数字只能由 App 从聚合字段填充"）。

**后果：无论换哪个模型、中文多好，本层都改不动任何一条建议。**
这不是模型问题，是**文档 + 护栏设计互相抵消**：

| 设计元素 | 它做什么 | 与润色层的冲突 |
|---|---|---|
| 旧版护栏拒绝任何数字 | 防模型编造数据 | 真实建议**全部**含数字 → 全被排除 |
| 唯一天然无数字的模板（规则 4 规律性） | — | 缺 σ 数据源，**实测从不触发** |
| `general` 免责声明 | 合规 | 逐字冻结，永不经模型 |

**复测（ADR-26 之后，`probe_polishable_advice.dart` 新口径输出）：**

```
[regularity] 数字=3      →送模型  有 3 次进食发生在晚间，建议把正餐与加餐安排得更早一些。
[snack     ] 数字=9/两   →送模型  本周零食 9 次，建议减少薯片与软糖的频率，两餐之间可优先选择卷心菜或胡萝卜。
[speed     ] 数字=0.4    →送模型  本周平均咀嚼间隔约 0.4 秒（偏快），建议放慢进食节奏。
[structure ] 数字=2      →送模型  本周记录到的食物只有 2 类，建议主食与蔬果类都出现一些。
[general   ] 数字=无     →冻结    提供日常健康管理建议，不进行疾病诊断，不替代专业医疗意见

送进模型改写: 4 / 5（除免责声明外全部）
其中天然无数字: 0（所以**每一条都受数字判据约束**）
```

### 7.5 Qwen3.5-0.8B 的实测（P0 判据）

| 判据 | 结果 |
|---|---|
| **P0-1 中文可用** | ✅ **通过**。自然中文、切题，例如把「进食速度偏快，建议放慢进食节奏。」改写成「吃饭的时候稍微慢点，别一口气吞下去啦。」 |
| 思考模式 | 默认**开启**（会先输出大段英文思考）；`--reasoning off` 可关闭，关闭后必须用正确模板 `<|im_start|>`（不是 Gemma 的 `<start_of_turn>`） |
| 生成速度（x86 宿主） | ≈ 42 tokens/s |
| 截断风险 | **真实存在**：4 条里 1 条超 40 字（47 字），且被截断的是"请增加主食与蔬果类摄入"——语义丢失的残句 |
| **P0-2 不编数字** | ⚠️ **分路径**：*改写*已有句子时，4 条里 3 条正确保留数字（含 `0.4`、`2`），1 条把「有 3 次进食发生在晚间」改写成「晚餐正餐与加餐尽量提前安排」——**丢掉了那个 3**；而*根据事实自己给建议*时，它把 `0.4` 抄了回来（明确要求"不要写任何数字"也照抄） |
| 制品 | `Qwen3.5-0.8B-Q4_K_M.gguf` = **507.8 MB**（`unsloth/Qwen3.5-0.8B-GGUF`，经 `hf-mirror.com` 取得） |
| **ADR-26 数字判据通过率** | **3 / 4**。失败的那条把「有 **3** 次进食发生在晚间」改写成「…睡前 **1** 小时」——**凭空多出一个数字**，被护栏拦下并回落。这正是甲方案的已知失效模式 |

> **对 `hf-mirror` / `modelscope` 的可用性实测**：本机 `huggingface.co` 超时，
> 但 `hf-mirror.com` 与 `modelscope.cn` 均可达（下载 ~1 MB/s）。

---

### 7.6 🔧 本机 CMake 不可用 —— `.so` 是用 clang 直接编译出来的

**实测结论：CMake 在这台机器的沙箱里完全无法执行。** 一个单文件最小工程配 NDK toolchain
也会永久挂住（打印 `The C compiler identification is Clang 18.0.3` 之后不再前进）；
预置 `CMAKE_C_COMPILER_WORKS=1` + `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY` 绕开编译器校验
也无效。而**NDK 的 clang 本身完全正常**（实测：x86_64 与 arm64 的 `.c` 编译和 `.so` 链接都在秒级完成）。
所以瓶颈是 CMake/Ninja，与 llama.cpp 无关。

因此新增 `tool/build_llm_shim_no_cmake.ps1`：显式做 CMake 会做的事——生成版本头、逐个编译
53 个编译单元、用 clang++ 链接。踩到并修掉的四个真实 API/工具链问题：

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | `use of undeclared identifier 'cpu_set_t'` | 缺 `_GNU_SOURCE`（bionic 靠它暴露 `cpu_set_t`） | 加 `-D_GNU_SOURCE` |
| 2 | `'llama-version.h' file not found` | 该头与 `ggml-version.h` 一样是 CMake `configure_file` 生成的，上游只有 `.in` | 从两个 `.in` 模板生成 |
| 3 | `call to undeclared function 'llama_batch_clear'` | **b10937 删除了** `llama_batch_clear` / `llama_batch_add` | 直接填 `llama_batch` 的字段（`token/pos/n_seq_id/seq_id/logits`） |
| 4 | 链接失败 / `-static-libstdc++` 被忽略 | 用 C 驱动 `clang` 链接 C++ 产物 | 改用 `clang++` 链接 |

还有一个**只有验证才能发现**的缺陷：`-fvisibility=hidden`（为了不导出 llama.cpp 的 ~1600 个内部符号）
把 shim 自己的 5 个导出函数也一起藏了 —— 第一次成功链接出的 `.so` 有 1615 个动态符号、
**`acoudiet_llm_*` 一个都没有**，Dart 侧 `dlopen` 后必然找不到。修法是在头文件里给这 5 个函数加
`__attribute__((visibility("default")))`。

### 7.7 ⚠️ 换基座带来的许可变更（未完成）

当前权重是 **Qwen3.5-0.8B**，不再是 Gemma 蒸馏模型。两者的许可**完全不同**：

| | Gemma 蒸馏模型（已弃用） | **Qwen3.5-0.8B（当前）** |
|---|---|---|
| 基座 | `unsloth/gemma-3-270m-it` | `Qwen/Qwen3.5-0.8B` |
| 许可 | Gemma 条款，衍生作品需传递 | **Apache-2.0**（待人工核对定稿） |
| 中文 | ❌ 不会（实测） | ✅ 通过 P0-1 |
| 体积 | 253 MB | 507.8 MB |

**`docs/release/gemma_attribution_and_license.md` 记录的是 Gemma 那条路线，不可直接套用到当前权重。**
对外分发前必须重新核对 Qwen 的归属与许可要求。

---

### 7.9 🔴 用户实测反馈「健康建议不显示」的三个根因（v1.1.0 首包缺陷）
v1.1.0 第一次打包后用户实测反馈建议内容看不到变化。逐层排查后确认**不是模型的问题**，
而是三个独立缺陷叠在一起 —— 全部由本项目的静态检查「看不见」：

| # | 缺陷 | 为什么之前没发现 |
|---|---|---|
| 1 | **润色层从未被调用**。`ReportNotifier.reload()` 用的是 `report.advices`（未润色的规则文案），全仓**没有任何页面调用 `polishedAdvices`** | `polishedAdvices` 有完整单元测试，但**测试直接调它**，不经过 `reload()`；`notifiers.dart` 又不在离线套件的编译范围内 |
| 2 | **提示词与护栏口径自相矛盾**。系统指令写「不得新增任何数字」，而 ADR-26 的护栏要求「数字必须与原文逐字相等」。真实建议**每条都含数字**，模型照指令删掉数字 → 必然过不了护栏 → 整批回落 | 提示词的单元测试只断言"格式与占位符替换"，从不检查它与 `AdviceTextGuard` 的口径是否一致 |
| 3 | 打包时才发现 `notifiers.dart` 缺 `import '../../domain/model/advice.dart'`，`Advice` 未定义 | **离线套件不编译 `presentation/state/notifiers.dart`**（它依赖 Flutter），所以 800+ 条断言全绿也拦不住这个编译错误 |

**修法**：① `reload()` 里接上 `polishedAdvices` 并加缓存（报告页每次下拉刷新都会重跑 `reload()`，
没有缓存就会对**完全相同的输入**反复推理）；② 提示词第 1 条改为「原样抄写，一个都不能改」；
③ 补 import。

**遗留的方法论问题（值得单独记）**：这次暴露的是**测试盲区**，不是测试不够多 ——
`polishedAdvices` 被 8 条断言覆盖、`ReportView.of` 被 3 条覆盖，但**没有任何测试断言
"这一层被接上了"**。同类缺口本仓已出现过一次（`ADR-24`：没有任何测试 pump 过 `AppShell` 本身）。
因此凡新增一层"可选增强"，都应补一条**接线断言**（哪怕只是"装配后该层 enabled 且被调用"），
否则 800 条断言也给不出"它真的在工作"的证据。

---

**现状：`.so` 与权重全部就位，但 APK 打包在这一台机器上做不了。**

根因是**沙箱禁止带管道 stdio 的子进程**。Flutter 工具在启动时（`flutterUsage` 初始化、
`os.dart:_WindowsUtils.name`）会执行：

```dart
_processManager.runSync(<String>['ver'], runInShell: true)
// 实际命令：cmd.exe /c ver
// 抛：ProcessException: 拒绝访问 (CreateFile failed 5)
```

它发生在**命令行参数解析之前**，所以没有任何 `flutter build` 参数能绕过。
直接调 Gradle 也不行 —— `:app:compileFlutterBuildRelease` 仍然会 fork `flutter.bat`，
同样以 255 失败。

> 对照：本机的 `clang`、`gradlew`、`llama-cli` 都能跑，因为它们使用**继承的** stdio。
> 只有"用管道捕获另一个程序输出"这种形态被拒。

**你那边只需要一条命令**（前提：`app/android/key.properties` 已配置 release 签名）：

```powershell
flutter build apk --release --target-platform android-arm64
```

产物预计 **≈540 MB**（权重 507.8 MB + `.so` 4.87 MB + 现有 25 MB）。

⚠️ 若要在**模拟器**（x86_64）上验证，`--target-platform android-arm64` 会**过滤掉** x86_64 的 `.so`
（Flutter 的该参数不过滤第三方 AAR 的原生库，但 `jniLibs` 的 ABI 仍受 `abiFilters` 控制）。
两种做法：加 `--android-project-arg=acoudietAbis=arm64-v8a,x86_64`，或先用 arm64 真机验证。

---

## 8. 顺序建议（**已被 §7.2 / §7.4 的实测改写**）

原计划是"第 0 步先做，最便宜、能直接否决后面所有工作"。这次的执行顺序**反了**：
先把制品做出来了，才做第 0 步的语言判据，于是把"制品能跑"和"能不能交付"两件事混在了一起。

### 8.1 现在的正确顺序

1. **不要往 APK 里塞任何权重。** 已实测两个独立阻断项：
   Gemma 词条下是"不会中文"，Qwen3.5-0.8B 词条下是"没有可改的内容"。
   两者都会得到同一个结果：**体积涨 500 MB，用户看到的改变是零**。
2. 若仍要做"报告页由模型润色"，**先修设计而不是换模型**：见 §8.2。
3. P0 三判据（中文 / 不编数字 / 优于纯规则基线）**必须通过之后**，
   才值得启动 §5.1 的 NDK 编译与 §5.2 的打包。
4. 全程许可未清（归属文档 §3 的 L1/L2）→ **不产出对外分发的 Release APK**。

### 8.2 若要做，需要先决定的设计问题（**不是换模型能解决的**）

**✅ 已拍板：走「甲」——见 `ADR-26`。** 判据已实现并实测。

| 路 | 做法 | 代价 |
|---|---|---|
| **甲：让数字句可改写** ✅**已采纳** | 护栏从"禁止数字"改成"**数字序列必须与原文完全相等**"（个数/顺序/逐字） | **实测通过率 3/4**：Qwen3.5-0.8B 在 4 条真实建议上 3 条正确保留数字，1 条把「有 3 次进食发生在晚间」改写成「…睡前 1 小时」（**凭空多出数字**）→ 该条被护栏拦下并回落。代价是同一份报告里可能两种句子风格并存 |
| 乙：改成定性优先的模板（**未采纳**） | 建议正文不含数字，数字作为**附加数据**展示（由 UI 而非文案承载） | 要改 `SPEC-A-02` 的模板表与全部逐字断言，属**契约变更** |

**换更大的模型（2B/4B/9B）不解决"有没有东西可改"** —— 那是设计问题，已由 ADR-26 解决。
但它**可能**改善"改得好不好"（P0-3，仍未做）。

### 8.3 本机已跑通的部分（可复现）

虽然结论是"停"，但**转换链路本身已经在本机跑通了**，换基座后可以复用：

| 脚本 | 作用 |
|---|---|
| `tool/fetch_llama_cpp_binary.py` | 从 GitHub Releases 拉 Windows CPU 版二进制（走 Python 的 TLS） |
| `tool/setup_gguf_env.py` | 装便携版 Python 3.11 + 转换依赖 |
| `tool/convert_nia_to_gguf.py` | safetensors → GGUF，含两处针对"无 `tokenizer.model`"的补丁 |

⚠️ **本机网络的一个真实特性**（踩了一路，值得记下来）：
Windows **Schannel 的 TLS 凭证链是坏的**（`schannel: AcquireCredentialsHandle failed:
SEC_E_NO_CREDENTIALS`），所以 **PowerShell 的 `Invoke-WebRequest`、`curl.exe`、`git` 全部连不上 HTTPS**；
但 **Python 的 OpenSSL 正常**（实测 2–4 MB/s，pip 走的是清华镜像）。
因此本机所有下载都必须由 Python 完成，不能用系统工具。
