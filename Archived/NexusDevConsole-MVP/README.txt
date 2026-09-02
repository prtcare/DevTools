NEXUS DEVELOPMENT CONSOLE - MVP

1. Copy these files into C:\Personal\DevTools\
   - NexusDev.ps1
   - install-shortcut.ps1
   - config\projects.json

2. Keep your existing files in the same folder:
   - notify.ps1
   - start-dev.ps1

3. Test the console:
   powershell -ExecutionPolicy Bypass -File "C:\Personal\DevTools\NexusDev.ps1"

4. If it works, create the desktop shortcut:
   & "C:\Personal\DevTools\install-shortcut.ps1"

5. Double-click "Nexus Development" on the desktop.

Edit config\projects.json to add or change repositories. For Nexus.Int and Nexus.Web, add the GitHub URL later if desired.
