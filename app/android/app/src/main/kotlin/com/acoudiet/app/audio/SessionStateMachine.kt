package com.acoudiet.app.audio

/**
 * L1 session lifecycle state machine -- the authoritative table is API-01 section 4.
 *
 * Only the transitions in that table are legal; everything else raises the registered
 * error code, and there are exactly three illegal cases the acceptance suite checks:
 * resume while not paused (ACD-SESS-002), pause twice (ACD-SESS-002), and any operation on
 * a session that has already ended (ACD-SESS-001).
 *
 * Pure Kotlin: no Android dependency, so `SessionStateMachineTest` runs on the JVM.
 */
class SessionStateMachine {

    enum class State { IDLE, STARTING, RUNNING, PAUSED, ERROR }

    enum class EndReason { USER_STOP, SILENCE_90S, ERROR }

    var state: State = State.IDLE
        private set

    var sessionId: String? = null
        private set

    var endReason: EndReason? = null
        private set

    /** Legal: IDLE -> STARTING. */
    fun startSession(id: String) {
        if (state != State.IDLE) {
            throw AcouDietException.illegalTransition(state.name, State.STARTING.name)
        }
        sessionId = id
        endReason = null
        state = State.STARTING
    }

    /** Legal: STARTING -> RUNNING (AudioRecord started, or an injection session is ready). */
    fun onStarted() {
        if (state != State.STARTING) {
            throw AcouDietException.illegalTransition(state.name, State.RUNNING.name)
        }
        state = State.RUNNING
    }

    /** Legal: STARTING -> ERROR. */
    fun onStartFailed() {
        if (state != State.STARTING) {
            throw AcouDietException.illegalTransition(state.name, State.ERROR.name)
        }
        state = State.ERROR
        endReason = EndReason.ERROR
    }

    /** Legal: ERROR -> IDLE (resources released). */
    fun recover() {
        if (state != State.ERROR) {
            throw AcouDietException.illegalTransition(state.name, State.IDLE.name)
        }
        state = State.IDLE
        sessionId = null
    }

    /** Legal only when [id] names the active session and the state is RUNNING. */
    fun pause(id: String) {
        requireSession(id)
        if (state == State.PAUSED) {
            // PAUSED -> PAUSED is explicitly illegal (API-01 section 4).
            throw AcouDietException.illegalTransition(state.name, State.PAUSED.name)
        }
        if (state != State.RUNNING) {
            throw AcouDietException.illegalTransition(state.name, State.PAUSED.name)
        }
        state = State.PAUSED
    }

    /** Legal only when [id] names the active session and the state is PAUSED. */
    fun resume(id: String) {
        requireSession(id)
        if (state != State.PAUSED) {
            // Includes the "IDLE -> RUNNING via resumeSession" row: illegal, ACD-SESS-002.
            throw AcouDietException.illegalTransition(state.name, State.RUNNING.name)
        }
        state = State.RUNNING
    }

    /** Legal from RUNNING or PAUSED; yields the summary's end reason. */
    fun stop(id: String): EndReason {
        requireSession(id)
        val reason = if (state == State.ERROR) EndReason.ERROR else EndReason.USER_STOP
        endReason = reason
        state = State.IDLE
        sessionId = null
        return reason
    }

    /** Legal from RUNNING or PAUSED (FF-21a silence criterion met). */
    fun endOnSilence(): EndReason {
        if (state != State.RUNNING && state != State.PAUSED) {
            throw AcouDietException.illegalTransition(state.name, State.IDLE.name)
        }
        endReason = EndReason.SILENCE_90S
        state = State.IDLE
        sessionId = null
        return EndReason.SILENCE_90S
    }

    fun isActive(): Boolean = state == State.RUNNING || state == State.PAUSED

    fun endReasonWire(): String? = when (endReason) {
        EndReason.USER_STOP -> "userStop"
        EndReason.SILENCE_90S -> "silence90s"
        EndReason.ERROR -> "error"
        null -> null
    }

    private fun requireSession(id: String) {
        val current = sessionId
        if (current == null || current != id) {
            throw AcouDietException.sessionNotFound(id)
        }
    }
}
