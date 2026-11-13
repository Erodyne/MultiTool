using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
[assembly: AssemblyTitle("MultiTool")]
[assembly: AssemblyProduct("MultiTool")]
[assembly: AssemblyDescription("Manutenzione PC")]
[assembly: AssemblyVersion("2026.11.11.2")]
class Program {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr h, string t, string c, uint f);
    static void Msg(string t) { MessageBoxW(IntPtr.Zero, t, "MultiTool", 0x30); }
    static string JoinArgs(string[] a) {
        var r = new System.Text.StringBuilder();
        foreach (var x in a) { if (r.Length > 0) r.Append(' '); r.Append(x.IndexOfAny(new[] { ' ', '\t', '"' }) >= 0 ? "\"" + x.Replace("\"", "\\\"") + "\"" : x); }
        return r.ToString();
    }
    [STAThread]
    static void Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "MultiTool.ps1");
        if (!File.Exists(ps1)) { Msg("MultiTool.ps1 non trovato accanto a MultiTool.exe"); return; }
        bool admin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
        if (!admin) {
            var up = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, JoinArgs(args));
            up.UseShellExecute = true; up.Verb = "runas"; up.WorkingDirectory = dir;
            try { Process.Start(up); } catch (System.ComponentModel.Win32Exception) { }
            return;
        }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        var si = new ProcessStartInfo(ps,
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\" " + JoinArgs(args));
        si.UseShellExecute = false; si.CreateNoWindow = true; si.WorkingDirectory = dir;
        try { Process.Start(si); } catch (Exception e) { Msg(e.Message); }
    }
}
