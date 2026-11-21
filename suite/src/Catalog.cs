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
    public string[] LegacyExes;   // installazioni col vecchio nome: risultano installate, l'aggiornamento le sostituisce
    public string LegacyId;       // vecchio id per le impostazioni salvate (path.<id>)
    public bool AdminInstall;
}

public static class Catalog {
    public const string SuiteRepo = "Erodyne/ErodyneSuite";

    // Chiave pubblica di firma delle release (XML RSA, da Strumenti\Firma-Release.ps1 -NuovaChiave).
    // Impostata: parte solo un installer con "<file>.sig" valido; un account GitHub rubato non basta più.
    // La firma copre programma + versione + impronta: non si può spacciare l'installer di un programma
    // per un altro, né ripubblicare una vecchia versione vulnerabile con un numero più alto.
    public const string ReleaseKey = "<RSAKeyValue><Modulus>kN5wgU/5hGfVfGBzNs1Yfl5NaSm2Gdl3is6hIbFiQmKtexFYBdQUK3H3ovgUHWUe4bIBaQpCmvG/Ytu46u1jdE6u9SZCt8pqjl5C0aZ/EM94Wde/jtQlCTiEfwtAQWVYi+ojGbs4uW3EAcQWC+Ss8bLlnJoWs17WE9RgXkdluBlmo58MIxRtJ3QzqYFPryoRi+IwVdtESw9+gqt3C0+elczn3mamt1qhGNQ3J8MDZq3+M3nEQnjQbyMTtskPfl2HMCDhjj6Q7A/LHUKqQZkSn++MkWIS0nhjv7lw4D/0mvbwjQ5/zJRC3h7nC9MuRfjfvx4atW37ZoB8THCIBdkCL7SXngMKXuj3t2/OVj/hSCul50BCrRLos+1zAbtiiAIlYBUbUu8ceHQS0oxwYXpGferQw44bzCaxsBKGIkZQDDeV2TNmpESQoFIUmGTxCp+Ni3KeHzVcGHhsYdZZHJDklV6EIdjp5PJ3qdVVpaREGdM9UbigYlYY7dhxrTsLp+Zx</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>";
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
                "Pulisce, ripara e ottimizza avvio, servizi e privacy",
                "Controlla hardware, sicurezza e rete; prepara la consegna" },
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
            Id = "video2all", LegacyId = "acquisizione", Name = "Video2All", Initials = "V2", Glyph = "\uE714",
            Tagline = "Video per tutto: cattura dal grabber USB",
            Features = new[] {
                "Registra VHS, console e videocamere dal grabber",
                "Live a bassa latenza, taglio preciso al fotogramma",
                "Restauro VHS, normalizzazione ed esportazione" },
            C1 = Color.FromArgb(0xA7, 0x8B, 0xFA), C2 = Color.FromArgb(0xF8, 0x71, 0x71),
            Repo = "Erodyne/Video2All", AssetPattern = @"^Video2All-Setup[0-9A-Za-z._-]{0,40}\.exe$",
            ExeName = "Video2All.exe", SilentArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART", AdminInstall = false,
            // prima il nuovo nome, poi le voci della vecchia "Acquisizione Video"
            UninstallHive = Hive.User, UninstallKeys = new[] { "Video2All", "Video2All_is1", "AcquisizioneVideo", "{6F6B2C1E-3A2D-4C8E-9B57-AC0E5D0F1A06}_is1" },
            DefaultDirs = new[] { Path.Combine(LAD, @"Programs\Video2All") },
            LegacyExes = new[] { Path.Combine(LAD, @"Programs\AcquisizioneVideo\Acquisizione.exe") }
        });
        Apps.Add(new AppDef {
            Id = "diskvital", Name = "DiskVital", Initials = "DV", Glyph = "\uEDA2",
            Tagline = "Salute dei dischi S.M.A.R.T.",
            Features = new[] {
                "Stato di dischi SATA, NVMe e USB, attributo per attributo",
                "Giudizio chiaro con motivo e consiglio",
                "Storico, avvisi accanto all'orologio e rapporto" },
            C1 = Color.FromArgb(0x34, 0xD3, 0x99), C2 = Color.FromArgb(0x7C, 0x5C, 0xFF),
            Repo = "Erodyne/DiskVital", AssetPattern = @"^DiskVital-Setup-[0-9A-Za-z._-]{0,40}\.exe$",
            ExeName = "DiskVital.exe", SilentArgs = "/S", AdminInstall = true,
            UninstallHive = Hive.Machine, UninstallKeys = new[] { "DiskVital" },
            DefaultDirs = new[] { Path.Combine(PF, "DiskVital") }
        });
        Apps.Add(new AppDef {
            Id = "installa", Name = "Installa", Initials = "IN", Glyph = "\uE7B8",
            Tagline = "Programmi per un PC nuovo",
            Features = new[] {
                "Programmi consigliati: spunta e installa",
                "Cerca qualsiasi programma dal catalogo di winget",
                "Profili da riusare su ogni PC che prepari" },
            C1 = Color.FromArgb(0x7C, 0x5C, 0xFF), C2 = Color.FromArgb(0xEC, 0x48, 0x99),
            Repo = "Erodyne/Installa", AssetPattern = @"^ErodyneInstalla-Setup-[0-9A-Za-z._-]{0,40}\.exe$",
            ExeName = "ErodyneInstalla.exe", SilentArgs = "/S", AdminInstall = true,
            UninstallHive = Hive.Machine, UninstallKeys = new[] { "ErodyneInstalla" },
            DefaultDirs = new[] { Path.Combine(PF, "ErodyneInstalla") }
        });
        Apps.Add(new AppDef {
            Id = "backup", Name = "Backup", Initials = "BK", Glyph = "\uE753",
            Tagline = "Copie di sicurezza delle tue cartelle",
            Features = new[] {
                "Documenti, foto e preferiti su disco esterno o di rete",
                "Automatico ogni giorno o settimana, recupera quelli saltati",
                "Protezione anti-ransomware e ripristino con un clic" },
            C1 = Color.FromArgb(0x22, 0xD3, 0xEE), C2 = Color.FromArgb(0x3B, 0x82, 0xF6),
            Repo = "Erodyne/Backup", AssetPattern = @"^ErodyneBackup-Setup-[0-9A-Za-z._-]{0,40}\.exe$",
            ExeName = "ErodyneBackup.exe", SilentArgs = "/S", AdminInstall = false,
            UninstallHive = Hive.User, UninstallKeys = new[] { "ErodyneBackup" },
            DefaultDirs = new[] { Path.Combine(LAD, @"Programs\ErodyneBackup") }
        });
        Apps.Add(new AppDef {
            Id = "spazio", Name = "Spazio", Initials = "SP", Glyph = "\uEB05",
            Tagline = "Cosa occupa i dischi",
            Features = new[] {
                "Mappa a riquadri di dischi e cartelle",
                "I file più grandi e lo spazio per tipo di file",
                "Elimina nel Cestino, con le cartelle di Windows protette" },
            C1 = Color.FromArgb(0xFB, 0xBF, 0x24), C2 = Color.FromArgb(0xF9, 0x73, 0x16),
            Repo = "Erodyne/Spazio", AssetPattern = @"^ErodyneSpazio-Setup-[0-9A-Za-z._-]{0,40}\.exe$",
            ExeName = "ErodyneSpazio.exe", SilentArgs = "/S", AdminInstall = false,
            UninstallHive = Hive.User, UninstallKeys = new[] { "ErodyneSpazio" },
            DefaultDirs = new[] { Path.Combine(LAD, @"Programs\ErodyneSpazio") }
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
