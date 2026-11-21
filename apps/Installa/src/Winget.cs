using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

public class WgRow { public string[] Cols; }

// winget: ricerca, elenco installati, installazione (stessa logica collaudata in MultiTool)
public static class Winget {
    static string path;
    public static string Path_ {
        get {
            if (path != null) return path;
            var u = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\winget.exe");
            try {
                var wa = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps");
                var best = Directory.GetDirectories(wa, "Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe")
                    .Select(d => new { d, v = Ver(Path.GetFileName(d).Split('_')[1]) })
                    .Where(x => File.Exists(Path.Combine(x.d, "winget.exe"))).OrderByDescending(x => x.v).FirstOrDefault();
                if (best != null) return path = Path.Combine(best.d, "winget.exe");
            } catch { }
            if (File.Exists(u)) return path = u;
            return null;
        }
    }
    static Version Ver(string s) { Version v; return Version.TryParse(s, out v) ? v : new Version(0, 0); }

    public static int Run(string args, out string output, CancellationToken ct = default(CancellationToken), Action<string> onLine = null, int timeoutMs = 1800000) {
        var w = Path_;
        if (w == null) { output = "winget non trovato"; return -3; }
        return Proc.Run(w, args + " --accept-source-agreements --disable-interactivity", out output, timeoutMs, ct, onLine, Encoding.UTF8);
    }

    // tabelle di winget: colonne allineate sotto una riga di trattini; le righe di avanzamento usano \r
    public static List<WgRow> Table(string text, bool firstOnly = false) {
        var lines = text.Split('\n').Select(l => { var p = l.TrimEnd('\r').Split('\r'); return p[p.Length - 1].TrimEnd(); }).ToList();
        if (firstOnly) {
            int stop = -1; bool seen = false;
            for (int q = 0; q < lines.Count; q++) if (Regex.IsMatch(lines[q], "^-{20,}$")) { if (seen) { stop = q - 2; break; } seen = true; }
            if (stop > 0) lines = lines.Take(stop + 1).ToList();
        }
        var res = new List<WgRow>();
        for (int i = 1; i < lines.Count; i++) {
            if (!Regex.IsMatch(lines[i], "^-{20,}$")) continue;
            var cols = Regex.Matches(lines[i - 1], @"\S+").Cast<Match>().Select(m => m.Index).ToList();
            if (cols.Count < 3) continue;
            for (int j = i + 1; j < lines.Count; j++) {
                var l = lines[j];
                if (string.IsNullOrWhiteSpace(l) || l.Length <= cols[2]) break;
                var cells = new string[cols.Count];
                for (int k = 0; k < cols.Count; k++) {
                    int a = cols[k], b = k + 1 < cols.Count ? cols[k + 1] : -1;
                    cells[k] = a >= l.Length ? "" : (b < 0 || b > l.Length ? l.Substring(a) : l.Substring(a, b - a)).Trim();
                }
                if (!Regex.IsMatch(cells[1], @"^\S+$")) continue;
                res.Add(new WgRow { Cols = cells });
            }
        }
        return res;
    }

    // ID esatti dei programmi installati (winget export non tronca gli ID come la tabella di "list")
    public static Dictionary<string, string> Installed() {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var f = Path.Combine(Path.GetTempPath(), "erodyne-export-" + Guid.NewGuid().ToString("N") + ".json");
        try {
            string o;
            Run("export -o \"" + f + "\" --include-versions", out o, default(CancellationToken), null, 240000);
            if (File.Exists(f)) {
                var js = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = int.MaxValue };
                var root = js.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                object srcs;
                if (root != null && root.TryGetValue("Sources", out srcs) && srcs is object[])
                    foreach (var s in (object[])srcs) {
                        var sd = s as Dictionary<string, object>; object pk;
                        if (sd == null || !sd.TryGetValue("Packages", out pk) || !(pk is object[])) continue;
                        foreach (var p in (object[])pk) {
                            var pd = p as Dictionary<string, object>; object id, ver;
                            if (pd != null && pd.TryGetValue("PackageIdentifier", out id)) map[Convert.ToString(id)] = pd.TryGetValue("Version", out ver) ? Convert.ToString(ver) : "";
                        }
                    }
            }
        } catch (Exception e) { App.Log(e); }
        finally { try { File.Delete(f); } catch { } }
        return map;
    }

    // nomi dei programmi installati (registro), per riconoscere anche quelli installati senza winget
    public static List<string> InstalledNames() {
        var names = new List<string>();
        foreach (var hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 }) {
                try {
                    using (var b = RegistryKey.OpenBaseKey(hive, view))
                    using (var k = b.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")) {
                        if (k == null) continue;
                        foreach (var sk in k.GetSubKeyNames())
                            using (var e = k.OpenSubKey(sk)) { var n = e == null ? null : e.GetValue("DisplayName") as string; if (!string.IsNullOrEmpty(n)) names.Add(n); }
                    }
                } catch { }
            }
        return names;
    }

    public static string Hex(int code) { return "0x" + code.ToString("X8"); }

    // esito leggibile dei codici di winget e degli installer
    public static bool Describe(int code, out string text) {
        if (code == 0) { text = "Installato"; return true; }
        switch (Hex(code)) {
            case "0x8A15002B": text = "Già aggiornato"; return true;
            case "0x8A150061": case "0x8A15010D": text = "Già installato"; return true;
            case "0x8A150109": case "0x8A15010B": text = "Installato · serve un riavvio"; return true;
            case "0x8A15010E": text = "Già presente una versione più recente"; return true;
            case "0x8A150014": text = "Non trovato"; return false;
            case "0x8A15010A": text = "Serve prima un riavvio"; return false;
            case "0x8A150101": case "0x8A150111": text = "Programma aperto: chiudilo e riprova"; return false;
            case "0x8A150102": text = "Un'altra installazione è in corso"; return false;
            case "0x8A150103": text = "File in uso: chiudi il programma e riprova"; return false;
            case "0x8A150104": text = "Manca un componente richiesto"; return false;
            case "0x8A150105": text = "Disco pieno"; return false;
            case "0x8A150106": text = "Memoria insufficiente"; return false;
            case "0x8A150107": case "0x8A15000F": case "0x8A150044": text = "Connessione a internet assente"; return false;
            case "0x8A15010C": text = "Annullato"; return false;
            case "0x8A15010F": text = "Bloccato dai criteri aziendali"; return false;
            case "0x8A150011": text = "File scaricato non valido"; return false;
            case "0x8A150010": text = "Nessun installer adatto a questo PC"; return false;
            case "0x80004004": text = "Installazione interrotta"; return false;
        }
        if (code == 3010 || code == 1641) { text = "Installato · serve un riavvio"; return true; }
        if (code == -2) { text = "Interrotto"; return false; }
        if (code == -3) { text = "winget non trovato"; return false; }
        text = "Errore " + Hex(code); return false;
    }

    static readonly Regex Dl = new Regex(@"([\d\.,]+)\s*([KMG]B)\s*/\s*([\d\.,]+)\s*([KMG]B)"), Pct = new Regex(@"(\d{1,3})\s*%");
    public static int Install(string id, string source, CancellationToken ct, Action<string> status) {
        var a = "install --id \"" + id + "\" --exact --silent --accept-package-agreements" + (string.IsNullOrEmpty(source) ? "" : " --source " + source);
        Action<string> cb = l => {
            if (status == null) return;
            foreach (var part in l.Split('\r')) {
                var m = Dl.Match(part);
                if (m.Success) {
                    double x = Num(m.Groups[1].Value) * Mul(m.Groups[2].Value), y = Num(m.Groups[3].Value) * Mul(m.Groups[4].Value);
                    if (y > 0) status("Download " + (int)(x / y * 100) + "%");
                } else if (part.IndexOf("nstall", StringComparison.OrdinalIgnoreCase) >= 0 && part.IndexOf("ok", StringComparison.OrdinalIgnoreCase) < 0) status("Installo…");
                else { var p = Pct.Match(part); if (p.Success) status(p.Groups[1].Value + "%"); }
            }
        };
        int code = 0; string o;
        for (int t = 0; t < 3; t++) {
            code = Run(a, out o, ct, cb);
            if (code != unchecked((int)0x80004004) || ct.IsCancellationRequested) break;   // interruzione spuria: riprovo
            if (status != null) status("Nuovo tentativo…");
            Thread.Sleep(5000 * (t + 1));
        }
        return code;
    }
    static double Num(string s) { double v; double.TryParse(s.Replace(',', '.'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v); return v; }
    static double Mul(string u) { return u == "GB" ? 1073741824.0 : u == "MB" ? 1048576.0 : 1024.0; }
}
