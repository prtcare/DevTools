// CommandConcurrencyGuard.cs — busy / double-click protection (Part 13).
//
// While one governed command is running, a second invocation must be refused. The
// backend is idempotency-aware, but the UI must also avoid accidental repeated
// invocation (double reservation / double completion / double verification launch).
// This tiny pure guard is shared by the UI and the tests.
namespace DevBridge.Engine;

public sealed class CommandConcurrencyGuard
{
    private readonly object _lock = new();
    private string? _activeCommandId;

    /// <summary>Try to begin running <paramref name="commandId"/>. Returns false
    /// when another command is already running.</summary>
    public bool TryBegin(string commandId)
    {
        lock (_lock)
        {
            if (_activeCommandId is not null) return false;
            _activeCommandId = commandId;
            return true;
        }
    }

    public string? ActiveCommandId
    {
        get { lock (_lock) { return _activeCommandId; } }
    }

    public void End(string commandId)
    {
        lock (_lock)
        {
            if (_activeCommandId == commandId) _activeCommandId = null;
        }
    }
}
