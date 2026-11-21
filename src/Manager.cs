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
using System.Security.AccessControl;
using System.Security.Principal;

public class AppState {
    public AppDef Def;
    public string InstalledVersion, InstallDir, ExePath, UninstallCmd;
    public string LatestVersion, Notes, AssetUrl, AssetName, ShaUrl, SigUrl, ReleasePage;
    public bool Checked, Online, Busy;
    public string Error, Progress;
    public double Percent = -1;

    // Copia dei dati della release al momento del clic: un controllo che finisce durante
    // il download non può cambiare file, impronta o firma a metà installazione.
    public AppState Snapshot() {
        return new AppState { Def = Def, LatestVersion = LatestVersion, AssetUrl = AssetUrl, AssetName = AssetName, ShaUrl = ShaUrl, SigUrl = SigUrl, ExePath = ExePath, InstalledVersion = InstalledVersion };
    }

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
        // proxy aziendali che chiedono l'accesso di Windows
        try { if (WebRequest.DefaultWebProxy != null) WebRequest.DefaultWebProxy.Credentials = CredentialCache.DefaultNetworkCredentials; } catch { }
    }

    // ---------- rilevamento locale ----------
    public static void DetectLocal(AppState s) {
        var d = s.Def;
        s.InstalledVersion = null; s.InstallDir = null; s.ExePath = null; s.UninstallCmd = null;
        // Solo il ramo giusto del registro: una voce finta in HKCU (scrivibile da qualsiasi programma)
        // non deve poter far avviare o disinstallare "come amministratore" un exe estraneo.
        foreach (var key in d.UninstallKeys)
            if (ReadUninstall(s, d.UninstallHive == Hive.Machine ? RegistryHive.LocalMachine : RegistryHive.CurrentUser, key)) break;
        var custom = Settings.Get("path." + d.Id);
        var candidates = new List<string>();
        if (!string.IsNullOrEmpty(custom)) candidates.Add(custom);
        if (s.InstallDir != null) candidates.Add(Path.Combine(s.InstallDir, d.ExeName));
        foreach (var dir in d.DefaultDirs) candidates.Add(Path.Combine(dir, d.ExeName));
        foreach (var c in candidates) {
            try {
                if (d.AdminInstall && !InProtectedDir(c)) continue; // programmi da amministratore: solo da Programmi
                if (File.Exists(c)) { s.ExePath = Path.GetFullPath(c); s.InstallDir = Path.GetDirectoryName(s.ExePath); break; }
            } catch { }
        }
        if (s.ExePath != null && s.InstalledVersion == null) {
            try {
                var fv = FileVersionInfo.GetVersionInfo(s.ExePath);
                var v = fv.ProductVersion ?? fv.FileVersion;
                if (!string.IsNullOrEmpty(v) && v != "0.0.0.0") s.InstalledVersion = Ver.Clean(v);
            } catch { }
        }
        if (s.ExePath == null) { s.InstalledVersion = null; s.InstallDir = null; }
    }

    // Cartelle scrivibili solo dagli amministratori
    public static bool InProtectedDir(string path) {
        try {
            var full = Path.GetFullPath(path).TrimEnd('\\') ;
            foreach (var v in new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 }) {
                var root = Environment.GetFolderPath(v);
                if (string.IsNullOrEmpty(root)) continue;
                root = Path.GetFullPath(root).TrimEnd('\\') + "\\";
                if (full.StartsWith(root, StringComparison.OrdinalIgnoreCase) && full.IndexOf("..", StringComparison.Ordinal) < 0) return true;
            }
        } catch { }
        return false;
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
        if (SafeUrl(url, true) == null) throw new Exception("indirizzo non sicuro");
        var rq = (HttpWebRequest)WebRequest.Create(url);
        rq.UserAgent = "ErodyneSuite/" + Program.Version;
        rq.Accept = "application/vnd.github+json";
        rq.Timeout = 20000; rq.ReadWriteTimeout = 20000;
        using (var rs = (HttpWebResponse)rq.GetResponse()) {
            if (rs.ResponseUri.Scheme != Uri.UriSchemeHttps) throw new Exception("risposta non protetta (http)");
            using (var sr = new StreamReader(rs.GetResponseStream(), Encoding.UTF8)) {
                var buf = new char[2 * 1024 * 1024 + 1];
                int n = 0, k;
                while (n < buf.Length && (k = sr.Read(buf, n, buf.Length - n)) > 0) n += k;
                if (n >= buf.Length) throw new Exception("risposta troppo grande");
                return new string(buf, 0, n);
            }
        }
    }

    public class Release { public string Version, Notes, Page; public List<KeyValuePair<string, string>> Assets = new List<KeyValuePair<string, string>>(); }

    public static Release LatestRelease(string repo) {
        var json = HttpGet("https://api.github.com/repos/" + repo + "/releases/latest");
        var o = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }.DeserializeObject(json) as Dictionary<string, object>;
        if (o == null) throw new Exception("risposta non valida");
        var r = new Release();
        object tag; o.TryGetValue("tag_name", out tag);
        r.Version = Ver.Clean(tag as string);
        if (string.IsNullOrEmpty(r.Version)) throw new Exception("release senza numero di versione");
        object body; if (o.TryGetValue("body", out body)) r.Notes = body as string;
        object page; if (o.TryGetValue("html_url", out page)) r.Page = page as string;
        object assets;
        if (o.TryGetValue("assets", out assets) && assets is IEnumerable) {
            foreach (var a in (IEnumerable)assets) {
                var d = a as Dictionary<string, object>;
                if (d == null) continue;
                object n, u; d.TryGetValue("name", out n); d.TryGetValue("browser_download_url", out u);
                if (n is string && u is string) r.Assets.Add(new KeyValuePair<string, string>((string)n, (string)u));
            }
        }
        return r;
    }

    public static void CheckOnline(AppState s) {
        string ver = null, notes = null, page = null, asset = null, url = null, sha = null, sig = null, err = null;
        bool online = false;
        try {
            var r = LatestRelease(s.Def.Repo);
            ver = r.Version; notes = r.Notes; page = SafeUrl(r.Page);
            var rx = new Regex(s.Def.AssetPattern, RegexOptions.IgnoreCase);
            foreach (var a in r.Assets) if (rx.IsMatch(a.Key) && SafeUrl(a.Value, true) != null) { asset = a.Key; url = a.Value; break; }
            if (asset != null) {
                foreach (var a in r.Assets) {
                    var n = a.Key.ToLowerInvariant();
                    if (SafeUrl(a.Value, true) == null) continue;
                    if (n == asset.ToLowerInvariant() + ".sha256") { sha = a.Value; }
                    else if ((n == "sha256sums.txt" || n == "sha256sums") && (sha == null || !sha.EndsWith(".sha256"))) sha = a.Value;
                    else if (n == asset.ToLowerInvariant() + ".sig") sig = a.Value;
                }
            }
            if (url != null && sig == null && !string.IsNullOrEmpty(Catalog.ReleaseKey)) {
                url = null; // senza firma non si installa: inutile proporlo
                err = "La versione " + ver + " non è ancora firmata: sarà installabile appena firmata";
            }
            online = true;
        } catch (WebException e) {
            var hr = e.Response as HttpWebResponse;
            online = hr != null;
            if (hr == null) err = "Impossibile contattare GitHub";
            else if (hr.StatusCode == HttpStatusCode.NotFound) err = "Nessuna versione pubblicata su GitHub (" + s.Def.Repo + ")";
            else if ((int)hr.StatusCode == 403 || (int)hr.StatusCode == 429) err = "Troppi controlli verso GitHub: riprova tra qualche minuto";
            else err = "GitHub ha risposto con errore " + (int)hr.StatusCode;
        } catch (Exception e) {
            online = true;
            err = "Controllo non riuscito: " + e.Message;
        }
        // tutto insieme, così l'interfaccia non vede stati a metà
        s.LatestVersion = ver; s.Notes = notes; s.ReleasePage = page;
        s.AssetName = asset; s.ShaUrl = sha; s.SigUrl = sig; s.AssetUrl = url;
        s.Error = err; s.Online = online; s.Checked = true;
    }

    // Solo indirizzi web: niente file://, script o altri protocolli dalle note di rilascio
    public static string SafeUrl(string u, bool httpsOnly = false) {
        Uri x;
        if (string.IsNullOrEmpty(u) || !Uri.TryCreate(u, UriKind.Absolute, out x)) return null;
        if (x.Scheme == Uri.UriSchemeHttps) return x.AbsoluteUri;
        return !httpsOnly && x.Scheme == Uri.UriSchemeHttp ? x.AbsoluteUri : null;
    }

    // ---------- download e installazione ----------
    // Installer scaricato e bloccato in sola lettura fino alla fine dell'installazione:
    // nessun altro programma può sostituirlo tra la verifica e l'avvio come amministratore.
    public class Payload : IDisposable {
        public string File, Hash; public bool Signed; public FileStream Lock;
        public void Dispose() { if (Lock != null) Lock.Dispose(); Lock = null; TryDelete(File); }
    }

    public static Payload Fetch(AppState s, Action<double, string> progress) {
        var file = Download(s, progress);
        var p = new Payload { File = file };
        try {
            p.Lock = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
            using (var sha = SHA256.Create()) p.Hash = Hex(sha.ComputeHash(p.Lock));
            p.Lock.Position = 0;
            if (p.Hash != lastHash) throw new Exception("il file è stato modificato dopo il download");
            p.Signed = VerifySignature(s, p.Hash, progress);
            if (p.Signed && s.InstalledVersion != null && Ver.Newer(s.InstalledVersion, s.LatestVersion))
                throw new Exception("la release è più vecchia della versione installata: installazione bloccata");
        } catch { p.Dispose(); throw; }
        return p;
    }

    [ThreadStatic] static string lastHash;
    static string Hex(byte[] b) { return BitConverter.ToString(b).Replace("-", "").ToLowerInvariant(); }

    // Firma RSA-SHA256 dell'impronta, in "<file>.sig" (Base64). Obbligatoria se Catalog.ReleaseKey è impostata.
    static bool VerifySignature(AppState s, string hash, Action<double, string> progress) {
        if (string.IsNullOrEmpty(Catalog.ReleaseKey)) return false;
        if (s.SigUrl == null) throw new Exception("la release non è firmata: installazione bloccata");
        progress(-1, "Verifica della firma");
        byte[] sig;
        try { sig = Convert.FromBase64String(HttpGet(s.SigUrl).Trim()); } catch (FormatException) { throw new Exception("firma non leggibile"); }
        var h = SignedMessageHash(s.Def.Id, s.LatestVersion, hash);
        using (var rsa = new RSACryptoServiceProvider()) {
            rsa.FromXmlString(Catalog.ReleaseKey);
            if (!rsa.VerifyHash(h, CryptoConfig.MapNameToOID("SHA256"), sig)) throw new Exception("firma NON valida: il file non viene dal suo autore");
        }
        return true;
    }

    // L'installer parte come amministratore dalla cartella del download: se un altro programma dell'utente
    // ci aggiungesse una DLL, l'installer potrebbe caricarla con i diritti di amministratore.
    // La cartella diventa di sola lettura anche per il suo proprietario (OWNER RIGHTS): l'utente può solo
    // leggere e cancellare, non aggiungere file né cambiare i permessi. Gli amministratori restano liberi.
    static void SealDir(string dir, string onlyFile) {
        var inh = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        var sec = new DirectorySecurity();
        sec.SetAccessRuleProtection(true, false);
        sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, inh, PropagationFlags.None, AccessControlType.Allow));
        sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl, inh, PropagationFlags.None, AccessControlType.Allow));
        var limited = FileSystemRights.ReadAndExecute | FileSystemRights.Delete;
        sec.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User, limited, inh, PropagationFlags.None, AccessControlType.Allow));
        sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-3-4"), limited, inh, PropagationFlags.None, AccessControlType.Allow)); // OWNER RIGHTS
        Directory.SetAccessControl(dir, sec);
        // qualcuno ha fatto in tempo a infilare qualcosa prima della chiusura? allora niente installazione
        foreach (var e in Directory.GetFileSystemEntries(dir))
            if (!string.Equals(e, onlyFile, StringComparison.OrdinalIgnoreCase)) throw new Exception("file estraneo nella cartella del download: installazione bloccata");
    }

    // Messaggio firmato: "erodyne-release-1|<programma>|<versione>|<sha256 del file>"
    public static byte[] SignedMessageHash(string id, string version, string fileHash) {
        var msg = "erodyne-release-1|" + id + "|" + Ver.Clean(version) + "|" + fileHash.ToLowerInvariant();
        using (var sha = SHA256.Create()) return sha.ComputeHash(Encoding.UTF8.GetBytes(msg));
    }

    static string Download(AppState s, Action<double, string> progress) {
        if (SafeUrl(s.AssetUrl, true) == null) throw new Exception("indirizzo di download non sicuro");
        var dir = Path.Combine(Path.Combine(Path.GetTempPath(), "ErodyneSuite"), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, Path.GetFileName(s.AssetName));
        FileStream outp;
        try {
            outp = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            SealDir(dir, file); // da qui nessun programma dell'utente può aggiungere DLL accanto all'installer
        } catch { TryDelete(file); try { Directory.Delete(dir); } catch { } throw; }
        var rq = (HttpWebRequest)WebRequest.Create(s.AssetUrl);
        rq.UserAgent = "ErodyneSuite/" + Program.Version;
        rq.Timeout = 30000; rq.ReadWriteTimeout = 60000;
        string hash;
        try {
        using (outp)
        using (var rs = rq.GetResponse())
        using (var inp = rs.GetResponseStream())
        using (var sha = SHA256.Create()) {
            if (rs.ResponseUri.Scheme != Uri.UriSchemeHttps) throw new Exception("download non protetto (http)");
            long total = rs.ContentLength, done = 0;
            const long Max = 1024L * 1024 * 1024;
            if (total > Max) throw new Exception("file troppo grande");
            var buf = new byte[81920]; int n; var last = DateTime.MinValue;
            while ((n = inp.Read(buf, 0, buf.Length)) > 0) {
                outp.Write(buf, 0, n); sha.TransformBlock(buf, 0, n, null, 0); done += n;
                if (done > Max) throw new Exception("file troppo grande");
                if ((DateTime.Now - last).TotalMilliseconds > 120) {
                    last = DateTime.Now;
                    progress(total > 0 ? (double)done / total : -1,
                        "Download " + Mb(done) + (total > 0 ? " di " + Mb(total) : ""));
                }
            }
            sha.TransformFinalBlock(buf, 0, 0);
            if (total > 0 && done != total) throw new Exception("download interrotto (" + Mb(done) + " di " + Mb(total) + ")");
            if (done == 0) throw new Exception("il file scaricato è vuoto");
            hash = Hex(sha.Hash);
            lastHash = hash;
        }
        } catch { TryDelete(file); throw; }
        if (s.ShaUrl != null) {
            progress(-1, "Verifica dell'impronta SHA-256");
            var list = HttpGet(s.ShaUrl);
            // riga con il nome del file; un .sha256 dedicato può contenere solo l'impronta
            string expected = null, only = null; int count = 0;
            foreach (var line in list.Split('\n')) {
                var m = Regex.Match(line, @"\b([0-9a-fA-F]{64})\b");
                if (!m.Success) continue;
                count++; only = m.Groups[1].Value.ToLowerInvariant();
                var rest = line.Substring(m.Index + 64).Trim().TrimStart('*').Trim();
                if (rest.Equals(s.AssetName, StringComparison.OrdinalIgnoreCase)) { expected = only; break; }
            }
            if (expected == null && count == 1 && s.ShaUrl.EndsWith(".sha256", StringComparison.OrdinalIgnoreCase)) expected = only;
            if (expected == null) {
                TryDelete(file);
                throw new Exception("impronta SHA-256 di " + s.AssetName + " non trovata nella release");
            }
            if (expected != hash) {
                TryDelete(file);
                throw new Exception("il file scaricato non corrisponde all'impronta pubblicata");
            }
        }
        return file;
    }

    // Download rimasti da sessioni interrotte (programma chiuso a forza, PC spento): via dopo un giorno
    public static void CleanStaleDownloads() {
        try {
            var root = Path.Combine(Path.GetTempPath(), "ErodyneSuite");
            if (!Directory.Exists(root)) return;
            foreach (var d in Directory.GetDirectories(root)) {
                try {
                    if (DateTime.UtcNow - Directory.GetCreationTimeUtc(d) < TimeSpan.FromDays(1)) continue;
                    foreach (var f in Directory.GetFiles(d)) File.Delete(f);
                    Directory.Delete(d);
                } catch { }
            }
        } catch { }
    }

    public static void TryDelete(string file) {
        try { File.Delete(file); Directory.Delete(Path.GetDirectoryName(file)); } catch { }
    }

    static string Mb(long b) { return (b / 1048576.0).ToString("0.0") + " MB"; }

    public static int RunInstaller(AppState s, Payload p) {
        if (p.Lock == null) throw new Exception("installer non verificato");
        var si = new ProcessStartInfo(p.File, s.Def.SilentArgs) { UseShellExecute = true, WorkingDirectory = Environment.SystemDirectory }; // non dalla cartella temporanea
        if (s.Def.AdminInstall) si.Verb = "runas";
        using (var proc = Process.Start(si)) {
            if (proc == null) throw new Exception("l'installer non è partito");
            proc.WaitForExit(); return proc.ExitCode;
        }
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
            if (p != null) p.WaitForExit();
        }
        // attende finché il programma sparisce o l'uninstaller (copia temporanea Au_.exe di NSIS) è ancora aperto
        for (int i = 0; i < 1200 && File.Exists(s.ExePath ?? ""); i++) {
            if (i >= 20 && !UninstallerRunning()) break;
            System.Threading.Thread.Sleep(500);
        }
    }

    static bool UninstallerRunning() {
        foreach (var p in Process.GetProcesses()) {
            try { var n = p.ProcessName; if (n.StartsWith("Au_") || n.StartsWith("Un_") || n.StartsWith("_iu", StringComparison.OrdinalIgnoreCase) || n.StartsWith("unins", StringComparison.OrdinalIgnoreCase)) return true; }
            catch { } finally { p.Dispose(); }
        }
        return false;
    }

    public static void Launch(AppState s) {
        var si = new ProcessStartInfo(s.ExePath, s.Def.LaunchArgs ?? "") { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(s.ExePath) };
        Process.Start(si);
    }

    public static void Open(string target) {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
    }
    public static void OpenUrl(string url) { url = SafeUrl(url); if (url != null) Open(url); }
    public static void OpenFolder(string dir) {
        if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;
        try { Process.Start("explorer.exe", "\"" + dir + "\""); } catch { }
    }
}
