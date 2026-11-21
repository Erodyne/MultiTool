using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

// Dati dell'app (impostati da Program all'avvio)
public static class App {
    public static string Name = "Erodyne", Folder = "Erodyne", Version = "1.0.0", Description = "";
    public static string DataDir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), Folder); } }

    public static void Log(object e) {
        try {
            Directory.CreateDirectory(DataDir);
            var lf = Path.Combine(DataDir, "errori.log");
            if (File.Exists(lf) && new FileInfo(lf).Length > 1024 * 1024) File.Delete(lf);
            File.AppendAllText(lf, DateTime.Now.ToString("s") + " " + e + "\r\n");
        } catch { }
    }
    public static bool Has(string[] a, string s) { foreach (var x in a) if (string.Equals(x, s, StringComparison.OrdinalIgnoreCase)) return true; return false; }
    public static string Arg(string[] a, string s) { for (int i = 0; i < a.Length - 1; i++) if (string.Equals(a[i], s, StringComparison.OrdinalIgnoreCase)) return a[i + 1]; return null; }
}

// Impostazioni chiave=valore in %APPDATA%\<app>\impostazioni.txt
public static class Store {
    static readonly Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    static bool loaded;
    static string FilePath { get { return Path.Combine(App.DataDir, "impostazioni.txt"); } }
    static void Load() {
        if (loaded) return; loaded = true;
        try {
            if (!File.Exists(FilePath)) return;
            foreach (var line in File.ReadAllLines(FilePath, Encoding.UTF8)) {
                var l = line.Trim();
                if (l.Length == 0 || l[0] == '#') continue;
                int i = l.IndexOf('=');
                if (i > 0) map[l.Substring(0, i).Trim()] = l.Substring(i + 1).Trim();
            }
        } catch (Exception e) { App.Log(e); }
    }
    public static bool Exists { get { return File.Exists(FilePath); } }
    public static string Get(string k, string def = null) { lock (map) { Load(); string v; return map.TryGetValue(k, out v) ? v : def; } }
    public static bool GetBool(string k, bool def = false) { var v = Get(k); return v == null ? def : v == "1" || v.Equals("true", StringComparison.OrdinalIgnoreCase); }
    public static void Set(string k, string v) { lock (map) { Load(); if (v == null) map.Remove(k); else map[k] = v.Replace("\r", " ").Replace("\n", " "); Save(); } }
    public static void SetBool(string k, bool v) { Set(k, v ? "1" : "0"); }
    static void Save() {
        try {
            Directory.CreateDirectory(App.DataDir);
            var sb = new StringBuilder("# " + App.Name + "\r\n");
            foreach (var kv in map) sb.Append(kv.Key).Append('=').Append(kv.Value).Append("\r\n");
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, sb.ToString(), Encoding.UTF8);
            if (File.Exists(FilePath)) File.Replace(tmp, FilePath, null); else File.Move(tmp, FilePath);
        } catch (Exception e) { App.Log(e); }
    }
}

public static class Fmt {
    public static string Size(double b) {
        if (b < 0) return "—";
        string[] u = { "B", "KB", "MB", "GB", "TB" };
        int i = 0; while (b >= 1024 && i < u.Length - 1) { b /= 1024; i++; }
        return (i == 0 ? b.ToString("0") : b.ToString(b < 10 ? "0.0" : "0")) + " " + u[i];
    }
    public static string Ago(DateTime t) {
        var d = DateTime.Now - t;
        if (d.TotalMinutes < 2) return "adesso";
        if (d.TotalHours < 1) return (int)d.TotalMinutes + " minuti fa";
        if (d.TotalHours < 24 && t.Date == DateTime.Today) return "oggi alle " + t.ToString("HH:mm");
        if (t.Date == DateTime.Today.AddDays(-1)) return "ieri alle " + t.ToString("HH:mm");
        if (d.TotalDays < 7) return (int)Math.Ceiling(d.TotalDays) + " giorni fa";
        return t.ToString("dd/MM/yyyy");
    }
}

// Programmi esterni (robocopy, winget, schtasks) con l'output letto senza finestra
public static class Proc {
    public static string Sys(string exe) { return Path.Combine(Environment.SystemDirectory, exe); }

    public static int Run(string exe, string args, out string output, int timeoutMs = 600000, CancellationToken ct = default(CancellationToken), Action<string> onLine = null, Encoding enc = null) {
        var sb = new StringBuilder();
        var psi = new ProcessStartInfo(exe, args) {
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Environment.SystemDirectory
        };
        if (enc != null) { psi.StandardOutputEncoding = enc; psi.StandardErrorEncoding = enc; }
        using (var p = new Process { StartInfo = psi }) {
            DataReceivedEventHandler h = (s, e) => {
                if (e.Data == null) return;
                lock (sb) sb.AppendLine(e.Data);
                if (onLine != null) try { onLine(e.Data); } catch { }
            };
            p.OutputDataReceived += h; p.ErrorDataReceived += h;
            p.Start();
            p.BeginOutputReadLine(); p.BeginErrorReadLine();
            var sw = Stopwatch.StartNew();
            while (!p.WaitForExit(200)) {
                if (ct.IsCancellationRequested || sw.ElapsedMilliseconds > timeoutMs) {
                    try { KillTree(p.Id); } catch { }
                    p.WaitForExit(5000);
                    lock (sb) output = sb.ToString();
                    return ct.IsCancellationRequested ? -2 : -1;
                }
            }
            p.WaitForExit();
            lock (sb) output = sb.ToString();
            return p.ExitCode;
        }
    }
    public static void KillTree(int pid) {
        try {
            using (var k = Process.Start(new ProcessStartInfo(Sys("taskkill.exe"), "/PID " + pid + " /T /F") { UseShellExecute = false, CreateNoWindow = true })) k.WaitForExit(10000);
        } catch { }
    }
    public static Encoding Oem {
        get { try { return Encoding.GetEncoding(System.Globalization.CultureInfo.CurrentCulture.TextInfo.OEMCodePage); } catch { return Encoding.Default; } }
    }
    public static void Open(string path, string args = null) {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true, Arguments = args ?? "" }); } catch (Exception e) { App.Log(e); }
    }
    public static void Explore(string path, bool select = false) {
        try {
            var ex = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
            Process.Start(ex, select ? "/select,\"" + path + "\"" : "\"" + path + "\"");
        } catch (Exception e) { App.Log(e); }
    }
}

// Attività pianificate da XML (senza dipendere dai moduli di PowerShell)
public static class Tasks {
    public static int Schtasks(string args) {
        string o; return Proc.Run(Proc.Sys("schtasks.exe"), args, out o, 30000);
    }
    public static bool Exists(string name) { return Schtasks("/Query /TN \"" + name + "\"") == 0; }
    public static void Delete(string name) { Schtasks("/Delete /TN \"" + name + "\" /F"); }
    public static bool Create(string name, string xml) {
        var tmp = Path.Combine(Path.GetTempPath(), "erodyne-" + Guid.NewGuid().ToString("N") + ".xml");
        try {
            File.WriteAllText(tmp, xml, Encoding.Unicode);
            return Schtasks("/Create /F /TN \"" + name + "\" /XML \"" + tmp + "\"") == 0;
        } finally { try { File.Delete(tmp); } catch { } }
    }
}
