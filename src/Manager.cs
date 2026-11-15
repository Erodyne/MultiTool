using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Microsoft.Win32;

public class AppState {
    public AppDef Def;
    public string InstalledVersion, InstallDir, ExePath, UninstallCmd;
    public string LatestVersion, Notes, AssetUrl, AssetName, ShaUrl, ReleasePage;
    public bool Checked, Online, Busy;
    public string Error, Progress;
    public double Percent = -1;

    public bool Installed { get { return ExePath != null; } }
    public bool CanDownload { get { return AssetUrl != null; } }
    public bool UpdateAvailable {
        get { return Installed && CanDownload && Ver.Newer(LatestVersion, InstalledVersion); }
    }
}

public static class Ver {
    public static long[] Parse(string v) {
        if (string.IsNullOrEmpty(v)) return null;
        var m = Regex.Match(v, @"\d+(\.\d+)*");
        if (!m.Success) return null;
        var p = m.Value.Split('.');
        var r = new long[Math.Max(4, p.Length)];
        for (int i = 0; i < p.Length; i++) long.TryParse(p[i], out r[i]);
        return r;
    }
    public static bool Newer(string remote, string local) {
        var a = Parse(remote); var b = Parse(local);
        if (a == null) return false;
        if (b == null) return true;
        int n = Math.Max(a.Length, b.Length);
        for (int i = 0; i < n; i++) {
            long x = i < a.Length ? a[i] : 0, y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
    public static string Clean(string v) {
        if (v == null) return null;
        var m = Regex.Match(v, @"\d+(\.\d+)*");
        return m.Success ? m.Value : v;
    }
}

public static class Manager {
    static Manager() {
        try { ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072; } catch { }
    }

    // ---------- rilevamento locale ----------
    public static void DetectLocal(AppState s) {
        var d = s.Def;
        s.InstalledVersion = null; s.InstallDir = null; s.ExePath = null; s.UninstallCmd = null;
        foreach (var key in d.UninstallKeys) {
            if (ReadUninstall(s, d.UninstallHive == Hive.Machine ? RegistryHive.LocalMachine : RegistryHive.CurrentUser, key)) break;
            if (ReadUninstall(s, d.UninstallHive == Hive.Machine ? RegistryHive.CurrentUser : RegistryHive.LocalMachine, key)) break;
        }
        var custom = Settings.Get("path." + d.Id);
        var candidates = new List<string>();
        if (!string.IsNullOrEmpty(custom)) candidates.Add(custom);
        if (s.InstallDir != null) candidates.Add(Path.Combine(s.InstallDir, d.ExeName));
        foreach (var dir in d.DefaultDirs) candidates.Add(Path.Combine(dir, d.ExeName));
        foreach (var c in candidates) {
            try {
                if (File.Exists(c)) { s.ExePath = c; if (s.InstallDir == null) s.InstallDir = Path.GetDirectoryName(c); break; }
            } catch { }
        }
        if (s.ExePath != null && s.InstalledVersion == null) {
            try {
                var fv = FileVersionInfo.GetVersionInfo(s.ExePath);
                var v = fv.ProductVersion ?? fv.FileVersion;
                if (!string.IsNullOrEmpty(v) && v != "0.0.0.0") s.InstalledVersion = Ver.Clean(v);
            } catch { }
        }
        if (s.ExePath == null) s.InstalledVersion = null;
    }

    static bool ReadUninstall(AppState s, RegistryHive hive, string name) {
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 }) {
            try {
                using (var b = RegistryKey.OpenBaseKey(hive, view))
                using (var k = b.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + name)) {
                    if (k == null) continue;
                    s.InstalledVersion = Ver.Clean(k.GetValue("DisplayVersion") as string);
                    var loc = (k.GetValue("InstallLocation") as string ?? "").Trim('"', ' ');
                    if (loc.Length > 0) s.InstallDir = loc.TrimEnd('\\');
                    s.UninstallCmd = k.GetValue("QuietUninstallString") as string ?? k.GetValue("UninstallString") as string;
                    if (s.InstallDir == null && s.UninstallCmd != null) {
                        var exe = SplitCommand(s.UninstallCmd)[0];
                        if (exe.Length > 0) s.InstallDir = Path.GetDirectoryName(exe);
                    }
                    return true;
                }
            } catch { }
        }
        return false;
    }

    public static string[] SplitCommand(string cmd) {
        cmd = (cmd ?? "").Trim();
        if (cmd.StartsWith("\"")) {
            int e = cmd.IndexOf('"', 1);
            if (e > 0) return new[] { cmd.Substring(1, e - 1), cmd.Substring(e + 1).Trim() };
        }
        int x = cmd.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        if (x > 0) return new[] { cmd.Substring(0, x + 4), cmd.Substring(x + 4).Trim() };
        int sp = cmd.IndexOf(' ');
        return sp > 0 ? new[] { cmd.Substring(0, sp), cmd.Substring(sp + 1) } : new[] { cmd, "" };
    }

    // ---------- GitHub ----------
    static string HttpGet(string url) {
        var rq = (HttpWebRequest)WebRequest.Create(url);
        rq.UserAgent = "ErodyneSuite/" + Program.Version;
        rq.Accept = "application/vnd.github+json";
        rq.Timeout = 20000; rq.ReadWriteTimeout = 20000;
        using (var rs = (HttpWebResponse)rq.GetResponse())
        using (var sr = new StreamReader(rs.GetResponseStream(), Encoding.UTF8))
            return sr.ReadToEnd();
    }

    public class Release { public string Version, Notes, Page; public List<KeyValuePair<string, string>> Assets = new List<KeyValuePair<string, string>>(); }

    public static Release LatestRelease(string repo) {
        var api = (Environment.GetEnvironmentVariable("ERODYNE_API") ?? "https://api.github.com").TrimEnd('/');
        var json = HttpGet(api + "/repos/" + repo + "/releases/latest");
        var o = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }.DeserializeObject(json) as Dictionary<string, object>;
        if (o == null) throw new Exception("risposta non valida");
        var r = new Release();
        r.Version = Ver.Clean(o["tag_name"] as string);
        object body; if (o.TryGetValue("body", out body)) r.Notes = body as string;
        object page; if (o.TryGetValue("html_url", out page)) r.Page = page as string;
        object assets;
        if (o.TryGetValue("assets", out assets) && assets is IEnumerable) {
            foreach (var a in (IEnumerable)assets) {
                var d = a as Dictionary<string, object>;
                if (d == null) continue;
                r.Assets.Add(new KeyValuePair<string, string>(d["name"] as string, d["browser_download_url"] as string));
            }
        }
        return r;
    }

    public static void CheckOnline(AppState s) {
        s.Error = null;
        try {
            var r = LatestRelease(s.Def.Repo);
            s.LatestVersion = r.Version; s.Notes = r.Notes; s.ReleasePage = r.Page;
            s.AssetUrl = s.AssetName = s.ShaUrl = null;
            var rx = new Regex(s.Def.AssetPattern, RegexOptions.IgnoreCase);
            foreach (var a in r.Assets) if (rx.IsMatch(a.Key)) { s.AssetName = a.Key; s.AssetUrl = a.Value; break; }
            if (s.AssetName != null) {
                foreach (var a in r.Assets) {
                    var n = a.Key.ToLowerInvariant();
                    if (n == s.AssetName.ToLowerInvariant() + ".sha256" || n == "sha256sums.txt" || n == "sha256sums") { s.ShaUrl = a.Value; break; }
                }
            }
            s.Online = true;
        } catch (WebException e) {
            var hr = e.Response as HttpWebResponse;
            s.Online = hr != null;
            s.LatestVersion = null; s.AssetUrl = null;
            s.Error = hr != null && hr.StatusCode == HttpStatusCode.NotFound
                ? "Nessuna versione pubblicata su GitHub (" + s.Def.Repo + ")"
                : "Impossibile contattare GitHub";
        } catch (Exception e) {
            s.Error = "Controllo non riuscito: " + e.Message;
        }
        s.Checked = true;
    }

    // ---------- download e installazione ----------
    public static string Download(AppState s, Action<double, string> progress) {
        var dir = Path.Combine(Path.GetTempPath(), "ErodyneSuite");
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, Path.GetFileName(s.AssetName));
        var rq = (HttpWebRequest)WebRequest.Create(s.AssetUrl);
        rq.UserAgent = "ErodyneSuite/" + Program.Version;
        rq.Timeout = 30000; rq.ReadWriteTimeout = 60000;
        string hash;
        using (var rs = rq.GetResponse())
        using (var inp = rs.GetResponseStream())
        using (var outp = File.Create(file))
        using (var sha = SHA256.Create()) {
            long total = rs.ContentLength, done = 0;
            var buf = new byte[81920]; int n; var last = DateTime.MinValue;
            while ((n = inp.Read(buf, 0, buf.Length)) > 0) {
                outp.Write(buf, 0, n); sha.TransformBlock(buf, 0, n, null, 0); done += n;
                if ((DateTime.Now - last).TotalMilliseconds > 120) {
                    last = DateTime.Now;
                    progress(total > 0 ? (double)done / total : -1,
                        "Download " + Mb(done) + (total > 0 ? " di " + Mb(total) : ""));
                }
            }
            sha.TransformFinalBlock(buf, 0, 0);
            hash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
        }
        if (s.ShaUrl != null) {
            progress(-1, "Verifica dell'impronta SHA-256");
            var list = HttpGet(s.ShaUrl);
            string expected = null;
            foreach (var line in list.Split('\n')) {
                var m = Regex.Match(line, @"\b([0-9a-fA-F]{64})\b");
                if (!m.Success) continue;
                if (expected == null || line.IndexOf(s.AssetName, StringComparison.OrdinalIgnoreCase) >= 0) {
                    expected = m.Groups[1].Value.ToLowerInvariant();
                    if (line.IndexOf(s.AssetName, StringComparison.OrdinalIgnoreCase) >= 0) break;
                }
            }
            if (expected != null && expected != hash) {
                try { File.Delete(file); } catch { }
                throw new Exception("il file scaricato non corrisponde all'impronta pubblicata");
            }
        }
        return file;
    }

    static string Mb(long b) { return (b / 1048576.0).ToString("0.0") + " MB"; }

    public static int RunInstaller(AppState s, string file) {
        var si = new ProcessStartInfo(file, s.Def.SilentArgs) { UseShellExecute = true };
        if (s.Def.AdminInstall) si.Verb = "runas";
        using (var p = Process.Start(si)) { p.WaitForExit(); return p.ExitCode; }
    }

    public static void Uninstall(AppState s) {
        if (string.IsNullOrEmpty(s.UninstallCmd)) throw new Exception("disinstallazione non trovata: usa App installate di Windows");
        var c = SplitCommand(s.UninstallCmd);
        var args = c[1];
        var exe = Path.GetFileName(c[0]).ToLowerInvariant();
        if (exe.StartsWith("unins") && args.IndexOf("SILENT", StringComparison.OrdinalIgnoreCase) < 0) args = (args + " /SILENT").Trim();
        var si = new ProcessStartInfo(c[0], args) { UseShellExecute = true };
        if (s.Def.UninstallHive == Hive.Machine) si.Verb = "runas";
        using (var p = Process.Start(si)) {
            // gli uninstaller NSIS si copiano in %TEMP% e tornano subito: attende che il programma sparisca
            p.WaitForExit();
        }
        for (int i = 0; i < 120 && File.Exists(s.ExePath ?? ""); i++) System.Threading.Thread.Sleep(500);
    }

    public static void Launch(AppState s) {
        var si = new ProcessStartInfo(s.ExePath, s.Def.LaunchArgs ?? "") { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(s.ExePath) };
        Process.Start(si);
    }

    public static void Open(string target) {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
    }
}
