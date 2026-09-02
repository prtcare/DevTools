// LifecycleStage.cs — the DevBridge governed pipeline as a displayable stage list.
// These stages mirror the DB-M03..DB-M11 workflow. The stage *state* (COMPLETE /
// CURRENT / WAITING / FAILED / BLOCKED) is derived by NextActionEngine from
// state/current-task.json plus evidence artifacts — never guessed.
namespace DevBridge.Engine;

public enum LifecycleStageKey
{
    Idle,            // no task selected
    Preflight,       // DB-M03
    Reservation,     // DB-M04
    ChatGpt,         // DB-M05 handoff + ChatGPT prompt generation
    DeepSeek,        // implementation
    Verification,    // DB-M06
    Claude,          // DB-M07/DB-M08 focused review
    FixLoop,         // DB-M09 (only when Claude requests fixes)
    Completion,      // DB-M10 governed completion
    ControlValidation, // DB-M11 workbook consistency validation
    Done,            // cycle closed, CONTROL_VALIDATED
}

public enum StageState
{
    Complete,
    Current,
    Waiting,
    Failed,
    Blocked,
}

public sealed record LifecycleStageState(LifecycleStageKey Key, string Label, StageState State);
