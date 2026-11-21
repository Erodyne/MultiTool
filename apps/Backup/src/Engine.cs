using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

public class BkFolder {
    public string Id, Name, Path;
    public bool Def, Custom;
    public List<BkPart> Parts;     // solo alcuni file da più cartelle (preferiti dei browser)
}
public class BkPart { public string N, P; public string[] F; }

public class BkResult { public int Code; public int Copied = -1; public bool Suspect; public string Error; }

// Copia con robocopy: solo i file nuovi o modificati, non cancella mai nulla nella destinazione.
public static class Engine {
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, out IntPtr path);
    static string Known(string guid, Environment.SpecialFolder fallback) {
        try {
            IntPtr p;
            if (SHGetKnownFolderPath(new Guid(guid), 0, IntPtr.Zero, out p) == 0) {
                var s = Marshal.PtrToStringUni(p); Marshal.FreeCoTaskMem(p);
                if (!string.IsNullOrEmpty(s)) return s;
            }
        } catch { }
        return Environment.GetFolderPath(fallback);
    }

    public static List<BkFolder> Folders() {
        var lad = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var rad = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var list = new List<BkFolder> {
            new BkFolder { Id = "doc", Name = "Documenti", Path = Known("FDD39AD0-238F-46AF-ADB4-6C85480369C7", Environment.SpecialFolder.MyDocuments), Def = true },
            new BkFolder { Id = "desk", Name = "Desktop", Path = Known("B4BFCC3A-DB2C-424C-B029-7FE99A87C641", Environment.SpecialFolder.DesktopDirectory), Def = true },
            new BkFolder { Id = "pic", Name = "Immagini", Path = Known("33E28130-4E1E-4676-835A-98395C3BC3BB", Environment.SpecialFolder.MyPictures), Def = true },
            new BkFolder { Id = "vid", Name = "Video", Path = Known("18989B1D-99B5-455B-841C-AB7C74E4DDFC", Environment.SpecialFolder.MyVideos) },
            new BkFolder { Id = "mus", Name = "Musica", Path = Known("4BD8D571-6D19-48D3-BE97-422220080E43", Environment.SpecialFolder.MyMusic) },
            new BkFolder { Id = "dl", Name = "Download", Path = Known("374DE290-123F-4565-9164-39C4925E467B", Environment.SpecialFolder.UserProfile) },
            new BkFolder { Id = "fav", Name = "Preferiti dei browser", Path = lad, Def = true, Parts = new List<BkPart> {
                new BkPart { N = "Edge", P = Path.Combine(lad, @"Microsoft\Edge\User Data"), F = new[] { "Bookmarks" } },
                new BkPart { N = "Chrome", P = Path.Combine(lad, @"Google\Chrome\User Data"), F = new[] { "Bookmarks" } },
                new BkPart { N = "Firefox", P = Path.Combine(rad, @"Mozilla\Firefox\Profiles"), F = new[] { "places.sqlite", "favicons.sqlite" } } } },
        };
        var dl = list.First(x => x.Id == "dl");
        if (string.Equals(dl.Path, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StringComparison.OrdinalIgnoreCase)) dl.Path = System.IO.Path.Combine(dl.Path, "Downloads");
        foreach (var p in (Store.Get("cartelle.extra") ?? "").Split('|')) {
            if (p.Trim().Length == 0) continue;
            var name = System.IO.Path.GetFileName(p.TrimEnd('\\'));
            if (string.IsNullOrEmpty(name)) name = p.Replace(":", "").Replace("\\", "");
            // nomi doppi: la cartella di destinazione deve essere unica
            var n = name; int k = 2; while (list.Any(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase))) n = name + " (" + k++ + ")";
            list.Add(new BkFolder { Id = "x:" + p, Name = n, Path = p, Def = true, Custom = true });
        }
        var sel = Store.Get("cartelle.sel");
        if (sel != null) { var s = sel.Split('|'); foreach (var f in list) f.Def = s.Contains(f.Id); }
        return list;
    }
    public static void SaveSelection(IEnumerable<string> ids) { Store.Set("cartelle.sel", string.Join("|", ids)); }
    public static void AddCustom(string path) {
        var cur = (Store.Get("cartelle.extra") ?? "").Split('|').Where(x => x.Length > 0).ToList();
        if (!cur.Contains(path, StringComparer.OrdinalIgnoreCase)) cur.Add(path);
        Store.Set("cartelle.extra", string.Join("|", cur));
        var sel = Store.Get("cartelle.sel");
        if (sel != null) Store.Set("cartelle.sel", sel + "|x:" + path);
    }
    public static void RemoveCustom(string path) {
        Store.Set("cartelle.extra", string.Join("|", (Store.Get("cartelle.extra") ?? "").Split('|').Where(x => x.Length > 0 && !x.Equals(path, StringComparison.OrdinalIgnoreCase))));
    }

    public static string Dest { get { return Store.Get("destinazione"); } }
    public static bool DestReady { get { var d = Dest; try { return !string.IsNullOrEmpty(d) && Directory.Exists(d); } catch { return false; } } }
    // compatibile con i backup già fatti da MultiTool: se c'è la sua cartella si continua lì (niente copia doppia)
    public static string Root {
        get {
            var d = Dest; if (string.IsNullOrEmpty(d)) return null;
            var old = System.IO.Path.Combine(d, "MultiTool-Backup", Environment.MachineName);
            return Directory.Exists(old) ? old : System.IO.Path.Combine(d, "Erodyne-Backup", Environment.MachineName);
        }
    }
    public static string Target(BkFolder f) { var r = Root; return r == null ? null : System.IO.Path.Combine(r, f.Name); }

    // dimensione di una cartella senza seguire collegamenti (giunzioni, link simbolici)
    public static long Size(string dir, CancellationToken ct, string[] only = null) {
        long tot = 0;
        var stack = new Stack<DirectoryInfo>();
        try { if (!Directory.Exists(dir)) return 0; stack.Push(new DirectoryInfo(dir)); } catch { return 0; }
        while (stack.Count > 0 && !ct.IsCancellationRequested) {
            var d = stack.Pop();
            try {
                foreach (var e in d.EnumerateFileSystemInfos()) {
                    if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                    var fi = e as FileInfo;
                    if (fi != null) { if (only == null || only.Contains(fi.Name, StringComparer.OrdinalIgnoreCase)) tot += fi.Length; }
                    else stack.Push((DirectoryInfo)e);
                }
            } catch { }
        }
        return tot;
    }
    public static long Size(BkFolder f, CancellationToken ct) {
        if (f.Parts == null) return Size(f.Path, ct);
        long s = 0; foreach (var p in f.Parts) s += Size(p.P, ct, p.F); return s;
    }

    static readonly Regex FilesLine = new Regex(@"(?m)^\s*(File|Files|Fichiers|Dateien|Archivos)\s*:\s*(\d+)\s+(\d+)");

    static BkResult Robo(string src, string dest, string[] files, CancellationToken ct) {
        Directory.CreateDirectory(dest);
        string o;
        if (files == null) {
            // anti-ransomware: se più di metà dei file risulta cambiata tutta insieme, non copio (potrebbero essere cifrati)
            int have = 0;
            try { have = Directory.EnumerateFiles(dest, "*", SearchOption.AllDirectories).Take(5000).Count(); } catch { }
            if (have >= 200) {
                Proc.Run(Proc.Sys("robocopy.exe"), Q(src) + " " + Q(dest) + " /E /XO /FFT /DST /L /R:0 /W:0 /NP /NFL /NDL /XJ /XA:SO", out o, 1800000, ct, null, Proc.Oem);
                var m = FilesLine.Match(o);
                if (m.Success) {
                    int tot = int.Parse(m.Groups[2].Value), chg = int.Parse(m.Groups[3].Value);
                    if (tot >= 200 && chg >= 200 && chg > tot / 2) { App.Log("Backup sospeso: " + chg + " file modificati su " + tot + " in " + src); return new BkResult { Code = 16, Suspect = true }; }
                }
            }
        }
        var a = files != null
            ? Q(src) + " " + Q(dest) + " " + string.Join(" ", files.Select(Q)) + " /S /XO /FFT /DST /R:1 /W:1 /NP /NFL /NDL /XJ /XA:SO"
            : Q(src) + " " + Q(dest) + " /E /XO /FFT /DST /R:1 /W:1 /MT:8 /NP /NFL /NDL /XJ /XA:SO";
        int code = Proc.Run(Proc.Sys("robocopy.exe"), a, out o, 6 * 3600 * 1000, ct, null, Proc.Oem);
        var mm = FilesLine.Match(o);
        return new BkResult { Code = code, Copied = mm.Success ? int.Parse(mm.Groups[3].Value) : -1 };
    }
    static string Q(string s) { return "\"" + s.TrimEnd('\\') + "\""; }

    public static BkResult Backup(BkFolder f, CancellationToken ct) {
        var t = Target(f);
        try {
            if (f.Parts == null) {
                if (!Directory.Exists(f.Path)) return new BkResult { Code = 16, Error = "Cartella non trovata" };
                return Robo(f.Path, t, null, ct);
            }
            var r = new BkResult { Code = 0, Copied = 0 };
            foreach (var p in f.Parts) {
                if (!Directory.Exists(p.P)) continue;
                var x = Robo(p.P, System.IO.Path.Combine(t, p.N), p.F, ct);
                r.Code = Math.Max(r.Code, x.Code); if (x.Copied > 0) r.Copied += x.Copied;
            }
            return r;
        } catch (Exception e) { App.Log(e); return new BkResult { Code = 16, Error = e.Message }; }
    }

    // Ripristino: riporta i file dal backup alla cartella originale, senza sovrascrivere quelli più recenti
    public static BkResult Restore(BkFolder f, CancellationToken ct) {
        var t = Target(f);
        if (t == null || !Directory.Exists(t)) return new BkResult { Code = 16, Error = "Nel backup non c'è questa cartella" };
        if (f.Parts != null) return new BkResult { Code = 16, Error = "I preferiti si ripristinano a mano dalla cartella del backup" };
        string o;
        int code = Proc.Run(Proc.Sys("robocopy.exe"), Q(t) + " " + Q(f.Path) + " /E /XO /FFT /DST /R:1 /W:1 /MT:8 /NP /NFL /NDL /XJ", out o, 6 * 3600 * 1000, ct, null, Proc.Oem);
        var m = FilesLine.Match(o);
        return new BkResult { Code = code, Copied = m.Success ? int.Parse(m.Groups[3].Value) : -1 };
    }

    public static string Describe(BkResult r) {
        if (r.Suspect) return "Sospeso: troppi file cambiati insieme (possibile virus)";
        if (r.Error != null) return r.Error;
        if (r.Code == -2) return "Interrotto";
        if (r.Code < 8) return r.Copied > 0 ? r.Copied + (r.Copied == 1 ? " file copiato" : " file copiati") : r.Copied == 0 ? "Già aggiornato" : "Completato";
        return "Errore di copia (robocopy " + r.Code + ")";
    }
    public static bool Ok(BkResult r) { return !r.Suspect && r.Error == null && r.Code >= 0 && r.Code < 8; }

    // ---------- storico ----------
    static string HistFile { get { return System.IO.Path.Combine(App.DataDir, "storico.txt"); } }
    public static void AddHistory(bool ok, string text) {
        try {
            Directory.CreateDirectory(App.DataDir);
            File.AppendAllText(HistFile, DateTime.Now.ToString("s") + "|" + (ok ? "ok" : "err") + "|" + text.Replace("|", "/").Replace("\r", " ").Replace("\n", " ") + "\r\n");
            var l = File.ReadAllLines(HistFile);
            if (l.Length > 400) File.WriteAllLines(HistFile, l.Skip(l.Length - 300).ToArray());
        } catch (Exception e) { App.Log(e); }
    }
    public static List<Tuple<DateTime, bool, string>> History(int n) {
        var r = new List<Tuple<DateTime, bool, string>>();
        try {
            if (!File.Exists(HistFile)) return r;
            foreach (var l in File.ReadAllLines(HistFile).Reverse()) {
                var p = l.Split(new[] { '|' }, 3); DateTime t;
                if (p.Length == 3 && DateTime.TryParse(p[0], out t)) r.Add(Tuple.Create(t, p[1] == "ok", p[2]));
                if (r.Count >= n) break;
            }
        } catch { }
        return r;
    }
    public static DateTime? LastOk {
        get { DateTime t; var v = Store.Get("ultimo"); return v != null && DateTime.TryParse(v, out t) ? t : (DateTime?)null; }
        set { Store.Set("ultimo", value.HasValue ? value.Value.ToString("s") : null); }
    }

    // Esegue il backup delle cartelle scelte; onStep(indice, cartella, esito o null se inizia)
    public static bool RunAll(List<BkFolder> folders, CancellationToken ct, Action<int, BkFolder, BkResult> onStep, out string summary) {
        int ok = 0, err = 0, copied = 0;
        for (int i = 0; i < folders.Count; i++) {
            if (ct.IsCancellationRequested) break;
            var f = folders[i];
            if (onStep != null) onStep(i, f, null);
            var r = Backup(f, ct);
            if (Ok(r)) { ok++; if (r.Copied > 0) copied += r.Copied; } else err++;
            if (onStep != null) onStep(i, f, r);
        }
        bool done = err == 0 && !ct.IsCancellationRequested && ok > 0;
        summary = ct.IsCancellationRequested ? "Backup interrotto" :
            err == 0 ? "Backup completato: " + copied + (copied == 1 ? " file copiato" : " file copiati") :
            "Backup con " + err + (err == 1 ? " errore" : " errori") + " su " + folders.Count + " cartelle";
        if (done) LastOk = DateTime.Now;
        AddHistory(done, summary);
        return done;
    }

    // ---------- importazione da MultiTool (solo la prima volta) ----------
    public static void ImportFromMultiTool() {
        if (Store.Exists) return;
        try {
            var f = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"MultiTool\Dati\settings.json");
            if (!File.Exists(f)) { Store.Set("creato", DateTime.Now.ToString("s")); return; }
            var js = new System.Web.Script.Serialization.JavaScriptSerializer();
            var d = js.DeserializeObject(File.ReadAllText(f)) as Dictionary<string, object>;
            if (d == null) return;
            object v;
            if (d.TryGetValue("BackupDest", out v) && v is string && ((string)v).Length > 0) Store.Set("destinazione", (string)v);
            if (d.TryGetValue("BackupSel", out v) && v is object[] && ((object[])v).Length > 0) Store.Set("cartelle.sel", string.Join("|", ((object[])v).Select(x => Convert.ToString(x))));
            if (d.TryGetValue("BackupTime", out v) && v is string && Regex.IsMatch((string)v, @"^\d{1,2}:\d{2}$")) Store.Set("ora", (string)v);
            if (d.TryGetValue("LastBackup", out v) && v is string) { DateTime t; if (DateTime.TryParse((string)v, out t)) LastOk = t; }
            if (d.TryGetValue("BackupAuto", out v) && v is bool && (bool)v && Dest != null) { Store.SetBool("automatico", true); Store.Set("frequenza", "giorno"); Schedule.Apply(); }
            Store.Set("importato.multitool", DateTime.Now.ToString("s"));
        } catch (Exception e) { App.Log(e); Store.Set("creato", DateTime.Now.ToString("s")); }
    }
}
