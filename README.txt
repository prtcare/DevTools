NEXUS DEVELOPMENT CONSOLE - V2

WHAT'S NEW
- Project cards show branch, Git status, and AGENTS.md presence.
- Start DeepSeek directly in each repository.
- Open a repository terminal or VS Code.
- Run Git Status.
- Verify: git status + diff summary + dotnet build + dotnet test when applicable.
- Checkpoint: only creates a Git checkpoint tag when the repository is healthy and clean.
- Test mobile notifications.
- Refresh repository state without restarting the console.

INSTALL / UPDATE
1. Copy these files into C:\Personal\DevTools\
   - NexusDev.ps1
   - checkpoint.ps1
   - verify.ps1
   - install-shortcut.ps1
   - config\projects.json

2. KEEP your existing:
   - notify.ps1
   - start-dev.ps1
   - deepcode configuration

3. Test:
   powershell -ExecutionPolicy Bypass -File "C:\Personal\DevTools\NexusDev.ps1"

4. If needed, recreate desktop shortcut:
   & "C:\Personal\DevTools\install-shortcut.ps1"

IMPORTANT
- checkpoint.ps1 refuses to create a checkpoint if uncommitted changes exist.
- verify.ps1 does not modify code; it reports Git changes and runs build/tests where detected.
- Edit config\projects.json to add GitHub URLs later.
