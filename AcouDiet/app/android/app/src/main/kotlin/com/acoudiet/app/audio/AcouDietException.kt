package com.acoudiet.app.audio

/**
 * AcouDiet unified error type for the native (L1) layer.
 *
 * Codes come from the single registry in API-00 section 3.5; nothing here may invent a
 * new code without registering it there first (SPEC-M-04 echoes codes back to the
 * operator, so the discipline is observable in the field).
 */
class AcouDietException(
    val code: String,
    message: String,
    val detail: Map<String, Any?>? = null,
    val retryable: Boolean = false,
) : Exception(message) {

    companion object {
        // ---- permission (ACD-PERM) ----
        fun permDenied() = AcouDietException(
            "ACD-PERM-001", "需要录音权限才能开始检测", null, false,
        )

        fun permPermanentlyDenied() = AcouDietException(
            "ACD-PERM-002", "录音权限已被永久拒绝，请到系统设置中开启", null, false,
        )

        // ---- session lifecycle (ACD-SESS) ----
        fun sessionNotFound(sessionId: String) = AcouDietException(
            "ACD-SESS-001", "检测会话不存在或已结束",
            mapOf("sessionId" to sessionId), false,
        )

        fun illegalTransition(from: String, to: String) = AcouDietException(
            "ACD-SESS-002", "当前状态不允许该操作",
            mapOf("from" to from, "to" to to), false,
        )

        // ---- audio device (ACD-AUD) ----
        fun audioRecordInitFailed(reason: String?) = AcouDietException(
            "ACD-AUD-001", "麦克风初始化失败，请重试",
            mapOf("reason" to reason), true,
        )

        fun audioDeviceBusy() = AcouDietException(
            "ACD-AUD-002", "麦克风被其他应用占用，请关闭其他录音应用", null, false,
        )

        // ---- feature computation (ACD-MEL) ----
        fun frameCountMismatch(expected: Int, actual: Int) = AcouDietException(
            "ACD-MEL-001", "音频特征计算失败，请重新开始检测",
            mapOf("expectedFrames" to expected, "actualFrames" to actual), false,
        )

        fun sampleCountMismatch(expected: Int, actual: Int) = AcouDietException(
            "ACD-MEL-002", "音频输入长度不符",
            mapOf("expectedSamples" to expected, "actualSamples" to actual), false,
        )

        // ---- configuration (ACD-CFG) ----
        fun cfgMismatch(field: String, expected: Any?, actual: Any?) = AcouDietException(
            "ACD-CFG-001", "配置不一致，请更新应用",
            mapOf("field" to field, "expected" to expected, "actual" to actual), false,
        )

        // ---- demo (ACD-DEMO) ----
        fun injectionFailed(reason: String) = AcouDietException(
            "ACD-DEMO-001", "示例音频不可用",
            mapOf("reason" to reason), false,
        )

        // ---- database (ACD-DB) ----
        // These four codes are already registered in the Dart registry (`Errors.Codes`) and are
        // what the HOST layer's SQLite channel reports, so an Android-side database failure
        // arrives in Dart as the same code the FFI backend would have produced.
        //
        // NOTE the deliberate omission of a "unique constraint" factory: like the FFI backend,
        // the SQLite engine's own message text is carried through (it contains `UNIQUE`), and
        // the repository layer is what maps that to `ACD-DB-002`. Translating here would break
        // that single mapping point.
        fun dbOpenFailed(reason: String?) = AcouDietException(
            "ACD-DB-001", "数据库打开失败",
            mapOf("reason" to reason), true,
        )

        fun dbStatementFailed(reason: String?) = AcouDietException(
            "ACD-DB-003", "数据保存失败，请重试",
            mapOf("reason" to reason), true,
        )

        fun dbInvalidArgument(reason: String?) = AcouDietException(
            "ACD-DB-004", "请求参数非法",
            mapOf("reason" to reason), false,
        )
    }
}
