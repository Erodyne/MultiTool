using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

public class Pkg {
    public string Id, Name, Cat, Source = "winget", Version, Match, LocalFile;
    public bool Installed, Selected, Done;
    public string Status; public System.Drawing.Color StatusColor = Th.Dim;
}

public class Profile {
    public string Name, Description, File, Origin;   // Origin: predefinito, tuo, MultiTool
    public List<string> Winget = new List<string>(), Local = new List<string>();
}

public static class Catalog {
    // programmi consigliati: categoria, ID winget, nome, nome nel registro (per riconoscerli anche se installati senza winget)
    static readonly string[][] Packs = {
        new[] { "Browser", "Google.Chrome", "Google Chrome", "" },
        new[] { "Browser", "Mozilla.Firefox", "Mozilla Firefox", "" },
        new[] { "Browser", "Brave.Brave", "Brave", "" },
        new[] { "Ufficio", "TheDocumentFoundation.LibreOffice", "LibreOffice", "" },
        new[] { "Ufficio", "Adobe.Acrobat.Reader.64-bit", "Adobe Acrobat Reader", @"^Adobe Acrobat( Reader| \(64-bit\)|$)" },
        new[] { "Ufficio", "SumatraPDF.SumatraPDF", "SumatraPDF", "^SumatraPDF" },
        new[] { "Ufficio", "Notepad++.Notepad++", "Notepad++", @"^Notepad\+\+" },
        new[] { "Multimedia", "VideoLAN.VLC", "VLC", "^VLC media player" },
        new[] { "Multimedia", "Spotify.Spotify", "Spotify", @"^Spotify|SpotifyAB\.SpotifyMusic" },
        new[] { "Multimedia", "IrfanSkiljan.IrfanView", "IrfanView", "^IrfanView" },
        new[] { "Multimedia", "Audacity.Audacity", "Audacity", "" },
        new[] { "Multimedia", "OBSProject.OBSStudio", "OBS Studio", "^OBS Studio" },
        new[] { "Comunicazione", "Zoom.Zoom", "Zoom", @"^Zoom( Workplace|$| \()" },
        new[] { "Comunicazione", "Telegram.TelegramDesktop", "Telegram", "^Telegram" },
        new[] { "Comunicazione", "Discord.Discord", "Discord", "" },
        new[] { "Comunicazione", "Mozilla.Thunderbird", "Thunderbird", "^Mozilla Thunderbird" },
        new[] { "Utilità", "7zip.7zip", "7-Zip", "^7-Zip" },
        new[] { "Utilità", "Microsoft.PowerToys", "PowerToys", "^PowerToys" },
        new[] { "Utilità", "Rufus.Rufus", "Rufus", "" },
        new[] { "Utilità", "CPUID.CPU-Z", "CPU-Z", "^CPUID CPU-Z|^CPU-Z" },
        new[] { "Utilità", "REALiX.HWiNFO", "HWiNFO", "^HWiNFO" },
        new[] { "Sicurezza", "Malwarebytes.Malwarebytes", "Malwarebytes", "" },
        new[] { "Sicurezza", "KeePassXCTeam.KeePassXC", "KeePassXC", "" },
        new[] { "Sicurezza", "Bitwarden.Bitwarden", "Bitwarden", "^Bitwarden" },
        new[] { "Assistenza remota", "RustDesk.RustDesk", "RustDesk", "" },
        new[] { "Assistenza remota", "AnyDesk.AnyDesk", "AnyDesk", "" },
        new[] { "Assistenza remota", "TeamViewer.TeamViewer", "TeamViewer", "^TeamViewer" },
        new[] { "Componenti", "Microsoft.VCRedist.2015+.x64", "Visual C++ 2015-2022 (x64)", @"^Microsoft Visual C\+\+ 20(15|17|19|22).*x64" },
        new[] { "Componenti", "Microsoft.DotNet.DesktopRuntime.8", ".NET Desktop Runtime 8", @"Windows Desktop Runtime - 8\." },
        new[] { "Componenti", "Oracle.JavaRuntimeEnvironment", "Java", @"^Java( \d| SE|\(TM\))" },
        new[] { "Giochi", "Valve.Steam", "Steam", "" },
        new[] { "Giochi", "EpicGames.EpicGamesLauncher", "Epic Games Launcher", "^Epic Games Launcher" },
    };

    public static List<Pkg> Recommended() {
        return Packs.Select(p => new Pkg { Cat = p[0], Id = p[1], Name = p[2], Match = p[3].Length > 0 ? p[3] : "^" + Regex.Escape(p[2]) }).ToList();
    }

    // riconosce i programmi già installati: ID winget esatto oppure nome nel registro
    public static void MarkInstalled(IEnumerable<Pkg> pk, Dictionary<string, string> wg, List<string> names) {
        foreach (var p in pk) {
            string v;
            bool byId = wg.TryGetValue(p.Id, out v);
            bool byName = !byId && p.Match != null && names.Any(n => { try { return Regex.IsMatch(n, p.Match, RegexOptions.IgnoreCase); } catch { return false; } });
            p.Installed = byId || byName;
            if (byId && !string.IsNullOrEmpty(v)) p.Version = v;
        }
    }

    // ---------- profili ----------
    public static string UserDir { get { return Path.Combine(App.DataDir, "Profili"); } }
    public static string MultiToolDir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"MultiTool\Profili"); } }

    static readonly Profile[] BuiltIn = {
        new Profile { Name = "PC nuovo", Description = "Browser, archivi, multimedia e PDF", Origin = "predefinito", Winget = { "Mozilla.Firefox", "Google.Chrome", "7zip.7zip", "VideoLAN.VLC", "Notepad++.Notepad++", "Adobe.Acrobat.Reader.64-bit" } },
        new Profile { Name = "Ufficio", Description = "Suite da ufficio, posta e videochiamate", Origin = "predefinito", Winget = { "TheDocumentFoundation.LibreOffice", "Zoom.Zoom", "Microsoft.Teams", "Mozilla.Thunderbird" } },
        new Profile { Name = "Gaming", Description = "Launcher e chat per giocare", Origin = "predefinito", Winget = { "Valve.Steam", "EpicGames.EpicGamesLauncher", "Discord.Discord" } },
        new Profile { Name = "Sviluppo", Description = "Editor, Git, Python e Node.js", Origin = "predefinito", Winget = { "Microsoft.VisualStudioCode", "Git.Git", "Python.Python.3.13", "OpenJS.NodeJS.LTS", "Microsoft.WindowsTerminal" } },
    };

    public static List<Profile> Profiles() {
        var res = new List<Profile>(BuiltIn);
        foreach (var dir in new[] { UserDir, MultiToolDir }) {
            try {
                if (!Directory.Exists(dir)) continue;
                foreach (var f in Directory.GetFiles(dir, "*.json")) {
                    var p = Read(f);
                    if (p == null) continue;
                    p.Origin = dir == UserDir ? "tuo" : "MultiTool";
                    // i profili di MultiTool con lo stesso nome di quelli predefiniti sono le stesse copie
                    if (p.Origin == "MultiTool" && res.Any(x => x.Name.Equals(p.Name, StringComparison.OrdinalIgnoreCase))) continue;
                    res.Add(p);
                }
            } catch (Exception e) { App.Log(e); }
        }
        return res;
    }

    static Profile Read(string f) {
        try {
            var js = new System.Web.Script.Serialization.JavaScriptSerializer();
            var d = js.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
            if (d == null) return null;
            var p = new Profile { File = f };
            object v;
            p.Name = d.TryGetValue("name", out v) ? Convert.ToString(v) : Path.GetFileNameWithoutExtension(f);
            p.Description = d.TryGetValue("description", out v) ? Convert.ToString(v) : "";
            if (d.TryGetValue("winget", out v) && v is object[]) p.Winget = ((object[])v).Select(Convert.ToString).Where(x => Regex.IsMatch(x, @"^[\w\.\-\+]{2,100}$")).ToList();
            if (d.TryGetValue("local", out v) && v is object[]) p.Local = ((object[])v).Select(Convert.ToString).Where(x => x.Length > 0 && x.IndexOfAny(Path.GetInvalidFileNameChars()) < 0).ToList();
            return p;
        } catch (Exception e) { App.Log(e); return null; }
    }

    public static string Save(string name, string description, IEnumerable<string> ids) {
        Directory.CreateDirectory(UserDir);
        var bn = Regex.Replace(Regex.Replace(name.Trim(), @"[^\w\- ]", ""), @"\s+", "-").Trim('-');
        if (bn.Length == 0) bn = "Profilo-" + DateTime.Now.ToString("yyyyMMdd-HHmm");
        var f = Path.Combine(UserDir, bn + ".json");
        var js = new System.Web.Script.Serialization.JavaScriptSerializer();
        var o = new Dictionary<string, object> { { "name", name.Trim() }, { "description", description ?? "" }, { "winget", ids.ToArray() }, { "local", new string[0] } };
        File.WriteAllText(f, js.Serialize(o), new UTF8Encoding(false));
        return f;
    }

    // installer locali dei profili di MultiTool: solo dalla sua cartella Installers, dove scrive solo un amministratore
    // (Installa lavora da amministratore: un file in una cartella dell'utente non deve poter essere avviato così)
    public static string FindLocal(Profile p, string name) {
        if (p.Origin != "MultiTool") return null;
        var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"MultiTool\Installers");
        try {
            if (!Directory.Exists(d)) return null;
            return Directory.GetFiles(d, name, SearchOption.AllDirectories).FirstOrDefault();
        } catch { return null; }
    }
}
