# 放新模型的地方（inbox）

**把一个新交付的 `.tflite` 丢进这个目录**（整包也可以），然后让我跑一条命令就行。

---

## 为什么有这个目录

2026-09-13 的核对结论是：`acoudiet_model_v1.1/` 里的 `models/acoudiet_fp32.tflite` 与 App 里
**已投放**的那份 **逐字节相同**（sha256 `705ffc62…560a`，连 zip 内部的成员哈希也一样），
而那个包的发布说明只列了**打包口径**的改动（正式件定为 fp32、`class_labels.json` 的
`model_name` 更正、I/O 契约不变、不含会话临时文件）——**没有声称重训**。

所以如果模型组**重新训练过**并且要给一份新权重，它需要先落到本机。丢进这个目录即可。

## 我拿到之后会做什么

```powershell
# 1) 先量：它和现在装的那份是不是真的不同（逐字节）
D:\Desktop\Food\_toolchain\dl\python\python.exe ^
    D:\Desktop\Food\AcouDiet\tool\compare_model_delivery.py D:\Desktop\Food\_incoming_model

# 2) 再装：校验形状/类别/帧数/float32 I/O/体积 → 算 sha256 与字节数 → 写模型卡 → 规范命名复制
D:\Desktop\Food\_toolchain\dl\python\python.exe ^
    D:\Desktop\Food\AcouDiet\tool\install_model.py ^
    --tflite D:\Desktop\Food\_incoming_model\<新模型>.tflite --version <版本号>

# 3) 独立复核（制品闸门：卡与文件一致 / 体积上限 / 三 hash 闭环 / parity 实测）
D:\Desktop\Food\_toolchain\dl\python\python.exe D:\Desktop\Food\AcouDiet\tool\verify_artifacts.py
```

我会把 **装前/装后的 sha256** 都贴出来，这样"到底换没换"不靠感觉判断。

> ⚠️ 两点提醒：
> 1. **重训后若前端规格也变了**（`n_fft` / `hop_length` / `n_mels` / `power_to_db_ref` /
>    `normalization` / 帧数等），交付包里会带 `feature_config.json` —— 一并放进来，
>    `compare_model_delivery.py` 会逐键比对；不一致就必须重冻结 SSOT 并重跑
>    `ai/scripts/mel_parity_test.py`，否则 App 喂进去的张量不是模型训练时看到的那种。
> 2. 换模型**不需要改代码**：文件名由 `model_card.json` 的 `name` + `quantization` + `version`
>    推导（`ModelRegistry`），所以本目录里的文件不会被 App 直接加载，必须走第 2 步投放。
