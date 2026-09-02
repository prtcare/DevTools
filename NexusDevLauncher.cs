using System;
using System.Diagnostics;
using System.IO;

class NexusDevLauncher
{
    [STAThread]
    static void Main()
    {
        string appFolder = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(appFolder, "NexusDev.ps1");

        if (!File.Exists(script))
        {
            System.Windows.Forms.MessageBox.Show(
                "NexusDev.ps1 was not found:\n" + script,
                "Nexus Development",
                System.Windows.Forms.MessageBoxButtons.OK,
                System.Windows.Forms.MessageBoxIcon.Error
            );
            return;
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();

        startInfo.FileName = "powershell.exe";

        startInfo.Arguments =
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
            script +
            "\"";

        startInfo.WorkingDirectory = appFolder;

        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.WindowStyle = ProcessWindowStyle.Hidden;

        Process.Start(startInfo);
    }
}