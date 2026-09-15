# PLAN-C-06 云端智能的隐私与合规

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-C-06 |
| 负责 | C（主责）；B 协助静态闸门与 `agent_tests` 的运行时断言；A 协助归档与证据截图 |
| 目标日 | v2.0-第 1 日 ～ v2.0-第 4 日（第 4 日必须完成两风味取证） |
| 前置依赖 | `SPEC-C-06` §4.3 同意门文案定稿（`SPEC-U-07` §4.3 同源常量）；`SPEC-G-01` 的凭据存储与 `clear()`；`PLAN-C-01` 的 `aapt` 取证流程 |
| 预估工时 | 28 人时 |

## 1. 交付物（Deliverables）
| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/lib/data/agent/agent_consent_store.dart` | 同意记录读写（§4.1 五字段），损坏按 `unconsented` 处理 |
| 2 | `app/lib/data/agent/agent_consent.dart` | `AgentConsentState` 枚举与 `revoke()`（含删除凭据） |
| 3 | `tool/check_audio_egress.py` | 静态闸门：网络层不得引用音频类型；`--selftest` 负控 |
| 4 | `app/tool/agent_tests.dart` | 运行时断言：请求体纯结构化 JSON + 无长度 ≥ 1024 的数值数组；撤回删凭据 |
| 5 | `tool/archive_agent_evidence.py` | 两风味 `aapt` 取证 + 两份 `sha256` 归档 |
| 6 | `records/compliance/C-06/consent_copy_v2.0.md`、`gate_screenshot.png` | 同意门文案逐字副本（含 §4.2/§4.3 两张清单与四条损失）与同意门截图 |
| 7 | `records/compliance/C-06/aapt_offline_v2.0.txt`、`aapt_agent_v2.0.txt`、`apk_sha256_offline.txt`、`apk_sha256_agent.txt` | 两风味权限声明输出与两 APK 的 `sha256` |
| 8 | `records/compliance/C-06/README.md` | 归档索引与复核命令清单 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 同意记录模型与读写（含 `gateCopyHash`） | 交付物 1/2 | 4h | 文案定稿 |
| 2 | 撤回语义：取消请求 + 删除凭据 + 留痕 | 交付物 2 | 3h | 1 |
| 3 | 静态闸门与负控 | 交付物 3 | 4h | — |
| 4 | 运行时请求体断言与负控 | 交付物 4 | 4h | 3 |
| 5 | 两风味取证脚本 | 交付物 5 | 4h | `PLAN-C-01` |
| 6 | 归档：文案副本、截图、`aapt`、`sha256` | 交付物 6~8 | 4h | 1,5 |
| 7 | 负控实测留痕（#1/#2/#6 各跑红一次） | 记录写入交付物 8 | 3h | 3,4 |
| 8 | §7 判据全量复核 | 复核清单 | 2h | 全部 |

## 3. 技术方案
**同意记录**（载体与凭据同级、模式 `0600`；形状真源是 `API-07` §2 的凭据契约，本域不重复定义）：
```dart
class AgentConsentStore {
  Future<AgentConsentState> read() async {
    try { return _decode(await _file.readAsString()); }
    catch (_) { return AgentConsentState.unconsented; }          // 损坏/缺失 → 未同意，绝不抛
  }
  Future<void> grant(String scopeVersion) async => _write(ConsentRecord(
      consentedAtMs: _nowMs, scopeVersion: scopeVersion, gateCopyHash: _copyHash));  // 哈希见 SPEC §4.1
  Future<void> revoke() async {                                  // SPEC-C-06 §2.4：先删凭据，再落记录
    await _session.cancelCurrentTurn();
    await _credentials.clear();
    await _write(_record.copyWith(revokedAtMs: _nowMs, keyDeletedOnRevoke: true));
  }
}
```
**静态闸门骨架**（`tool/check_audio_egress.py`，白名单目录取 `API-07` §1）：
```python
BANNED = ("Float32List", "Uint8List", "Int16List", "MelFrame", "audioPath")
hits = [m for f in NET_LAYER for m in scan(f, BANNED)]
print(f"hits={len(hits)}"); sys.exit(1 if hits else 0)
```
**运行时断言骨架**（`agent_tests.dart`）：每次构造请求体后走同一个 `_assertStructuredJson(body)`——① `jsonDecode` 成对象；② 无 base64；③ 递归遍历，**任何数值数组长度 ≥ 1024 即失败**；④ 键集合 ⊆ `FF-26d` 七类 + 协议字段。
**取证**：`tool/archive_agent_evidence.py` 对 `dist/*offline*.apk` 与 `dist/*agent*.apk` 各跑一次 `aapt dump badging`，过滤 `uses-permission` 落盘，并写 `sha256`；缺任一 APK 即 `exit 1`。

## 4. 测试与验证
| SPEC §7 # | 测试（命令 / 命名断言） | 类型 | 断言 | 何时跑 |
|---|---|---|---|---|
| 1 | `python tool/check_audio_egress.py --strict` | 静态 | 命中 0；`--selftest` 插入 `Uint8List` 后 `exit 1` | 每次提交 + 发版 |
| 2 | `agent_tests.dart` `every request body is pure structured JSON` | 运行时 | 四项结构断言全过；负控塞 65536 长数组必须失败 | 每次提交 |
| 3 | `tool/archive_agent_evidence.py` + `Test-Path` | 取证 | 4 个文件存在；`offline` 不含 `INTERNET`、`agent` 含；`sha256` hex 长度 64 且与 APK 实算相等 | 每次发版 |
| 4 | `Select-String -Path <SPEC-C-06> -Pattern '只适用于'` | 文档 | 命中 ≥1；含 `SPEC-C-01 §7` | 评审时 |
| 5 | `flutter test test/ui/agent_consent_test.dart` | widget | `enabled == false` 且 `requestCount == 0`；负控置真变红 | 每次提交 |
| 6 | `agent_tests.dart` `revoke deletes the stored credentials` | 运行时 | 撤回后文件不存在、`read() == null`；负控注掉删除必须失败 | 每次提交 |
| 7 | `Get-FileHash -Algorithm SHA256 consent_copy_v2.0.md` | 文档+代码 | 哈希等于 `gateCopyHash`；与 `UiStrings` 逐字符相等 | 评审时 |
| 8 | `Select-String -Path consent_copy_v2.0.md -Pattern '^\| '` | 文档 | 损失小节 **4** 行，且含 `API-05` §10 引用 | 评审时 |
| 9 | 清单行计数 | 文档 | 白名单 7 行、禁止清单 7 行 | 评审时 |
| 10 | `Test-Path gate_screenshot.png` + 人工核对表 | 人工 | 6 项全 ✓ | 发版前 |
| 11 | `dart run app/tool/ui_presenter_tests.dart` | 工具脚本 | 禁用表述命中 0；新文案在采集清单内 | 每次提交 |
| 12 | `rg -n "AccessibilityService\|performGlobalAction" app/android/.../agent/` | 静态 | 命中 0；负控变红 | 每次提交 |
| 13 | `Select-String -Path <SPEC-C-06> -Pattern '完全合规'` | 文档 | 命中 0；§10 #1 含 `API-05` §11 | 评审时 |
| 14 | `rg -n "sk-" records/compliance/C-06/ app/lib/presentation/pages/agent/` | 静态 | 命中 0 | 发版前 |
| 15 | `Get-ChildItem dist/*.apk` | 取证 | ≥2 个，一 `offline` 一 `agent` | 每次发版 |

## 5. 完成定义（DoD）
- [ ] `SPEC-C-06` §7 全部 15 条判据通过；#1/#2/#6/#12 的负控**已实际跑红并留痕**（写入交付物 10）。
- [ ] §7 #3 的两个 `aapt` 输出与两份 `sha256` 均来自**同一次构建**，且 `offline` 输出与 `ADR-44` 之前逐字相等（未退步）。
- [ ] 撤回路径删除凭据已由运行时断言证明；`revoked` + `stored` 组合不存在。
- [ ] `consent_copy_v2.0.md` 的哈希写入 `gateCopyHash`，文档与代码逐字符一致。
- [ ] §8 的「不可主张」四条在 PPT 声明表与同意门文案中均未被违反（**不出现「完全合规」**）。
- [ ] `records/compliance/C-06/README.md` 列出全部复核命令，任何人可照单复算。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 只出一个风味的包 | `dist/` 缺 `*offline*.apk` 或 `*agent*.apk` | **阻断发版**。若时间不足，先保 `offline` 的既有证据链（那是不可交易的），并把 `agent` 的取证挪到次日，**不得**用 `agent` 包冒充 `offline` 证据 |
| 运行时断言被绕过（构造点新增第二处） | `rg -n "chat/completions" app/lib/` 命中 >1 | 立即收敛到唯一构造点；在断言里加「构造点调用计数 == 1」的守卫 |
| 文案与文案副本漂移 | #7 的哈希比对失败 | 重新生成副本并**强制用户重新过门**（`scopeVersion` 递增） |
| 截图含明文 Key | 人工核对表第 6 项失败 | 用未配 Key 的设备重截；归档前跑一次 `sk-` 扫描（#14） |
| 第三方留存条款无法核实 | §10 #2 仍开放 | 同意门文案保持「数据交由该服务商处理」的事实陈述，**删除**任何代其承诺的措辞 |

## 7. 与检查点的关系
本域是 v2.0 的**合规闸门**：CP 前必须产出两份 APK 的 `aapt` 证据与四份归档文件。未完成时 CP 处置为**回退到 `offline` 风味的既有证据链**（`SPEC-C-01` §7 #1a/#2 原判据对 `offline` 继续有效），并把云端智能从「已交付」降级为「后续工作」；**不得**在缺证据的情况下对外主张 `FF-24` 第 8 条。
