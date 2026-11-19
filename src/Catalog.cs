using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;

// Catalogo dei programmi della suite. I repository sono fissi nel codice: un file modificabile
// da qualsiasi programma dell'utente non deve poter decidere cosa viene installato come amministratore.
public enum Hive { Machine, User }

public class AppDef {
    public string Id, Name, Tagline, Glyph, Initials, Repo, AssetPattern, ExeName, SilentArgs, LaunchArgs;
    public string[] Features;
    public Color C1, C2;
    public Hive UninstallHive;
    public string[] UninstallKeys;
    public string[] DefaultDirs;
    public bool AdminInstall;
}

public static class Catalog {
    public const string SuiteRepo = "Erodyne/ErodyneSuite";

    // Chiave pubblica di firma delle release (XML RSA, da Strumenti\Firma-Release.ps1 -NuovaChiave).
    // Vuota: gli installer non firmati partono solo dopo la conferma dell'utente, con impronta visibile.
    // Impostata: parte solo un installer con "<file>.sig" valido; un account GitHub rubato non basta più.
    // La firma copre programma + versione + impronta: non si può spacciare l'installer di un programma
    // per un altro, né ripubblicare una vecchia versione vulnerabile con un numero più alto.
    public const string ReleaseKey = "";
    public static readonly List<AppDef> Apps = new List<AppDef>();

    // dal registro di sistema, non dalle variabili d'ambiente (modificabili dall'utente)
    static string PF { get { return Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles); } }
    static string LAD { get { return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); } }

    static Catalog() {
        Apps.Add(new AppDef {
            Id = "multitool", Name = "MultiTool", Initials = "MT", Glyph = "\uE90F",
            Tagline = "Manutenzione completa del PC",
            Features = new[] {
                "Aggiorna tutti i programmi e Windows con un clic",
                "Installa i tuoi programmi scegliendoli da un elenco",
                "Pulisce, ripara e controlla hardware, sicurezza e rete" },
            C1 = Color.FromArgb(0x7C, 0x5C, 0xFF), C2 = Color.FromArgb(0x22, 0xD3, 0xEE),
            Repo = "Erodyne/MultiTool", AssetPattern = @"^MultiTool-Setup-[0-9A-Za-z._-]{0,40}\.exe$",
            ExeName = "MultiTool.exe", SilentArgs = "/S", AdminInstall = true,
            UninstallHive = Hive.Machine, UninstallKeys = new[] { "MultiTool" },
            DefaultDirs = new[] { Path.Combine(PF, "MultiTool") }
        });
        Apps.Add(new AppDef {
            Id = "remostation", Name = "Remostation", Initials = "RS", Glyph = "\uE7F4",
            Tagline = "Assistenza remota sicura",
            Features = new[] {
                "Controlla un PC a distanza con ID e password",
                "Conferma con ID verificato e avviso anti-truffa",
                "Relay tuo: Windows, Linux o Raspberry" },
            C1 = Color.FromArgb(0x22, 0xD3, 0xEE), C2 = Color.FromArgb(0x34, 0xD3, 0x99),
            Repo = "Erodyne/Remostation", AssetPattern = @"^Remostation-Setup[0-9A-Za-z._-]{0,40}\.exe$",
            ExeName = "remostation.exe", SilentArgs = "/S", AdminInstall = true,
            UninstallHive = Hive.Machine, UninstallKeys = new[] { "Remostation" },
            DefaultDirs = new[] { Path.Combine(PF, "Remostation") }
        });
        Apps.Add(new AppDef {
            Id = "acquisizione", Name = "Acquisizione Video", Initials = "AV", Glyph = "\uE714",
            Tagline = "Cattura video da grabber USB",
            Features = new[] {
                "Registra VHS, console e videocamere dal grabber",
                "Live a bassa latenza, taglio preciso al fotogramma",
                "Restauro VHS, normalizzazione ed esportazione" },
            C1 = Color.FromArgb(0xA7, 0x8B, 0xFA), C2 = Color.FromArgb(0xF8, 0x71, 0x71),
            Repo = "Erodyne/AcquisizioneVideo", AssetPattern = @"^AcquisizioneVideo-Setup[0-9A-Za-z._-]{0,40}\.exe$",
            ExeName = "Acquisizione.exe", SilentArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART", AdminInstall = false,
            UninstallHive = Hive.User, UninstallKeys = new[] { "AcquisizioneVideo", "{6F6B2C1E-3A2D-4C8E-9B57-AC0E5D0F1A06}_is1" },
            DefaultDirs = new[] { Path.Combine(LAD, @"Programs\AcquisizioneVideo") }
        });

    }
}

public static class Settings {
    static readonly Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ErodyneSuite");
    static string FilePath { get { return Path.Combine(Dir, "impostazioni.txt"); } }

    static Settings() {
        try {
            if (!File.Exists(FilePath)) return;
            foreach (var line in File.ReadAllLines(FilePath)) {
                var l = line.Trim();
                if (l.Length == 0 || l[0] == '#') continue;
                int i = l.IndexOf('=');
                if (i > 0) map[l.Substring(0, i).Trim()] = l.Substring(i + 1).Trim();
            }
        } catch { }
    }
    public static string Get(string k) { string v; return map.TryGetValue(k, out v) ? v : null; }
    public static void Set(string k, string v) {
        if (string.IsNullOrEmpty(v)) map.Remove(k); else map[k] = v;
        try {
            Directory.CreateDirectory(Dir);
            var lines = new List<string> { "# Erodyne Suite: path.<id>=percorso dell'exe (solo per i programmi installati per utente)" };
            foreach (var kv in map) lines.Add(kv.Key + "=" + kv.Value);
            File.WriteAllLines(FilePath, lines.ToArray());
        } catch { }
    }
}
