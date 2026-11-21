using System; using System.Linq;
public static class T {
    public static void Main(string[] a) {
        foreach (var id in new[] { "video2all", "diskvital" }) {
            var s = new AppState { Def = Catalog.Apps.First(x => x.Id == id) };
            Manager.DetectLocal(s);
            Manager.CheckOnline(s);
            Console.WriteLine(id + " check: ver=" + s.LatestVersion + " asset=" + s.AssetName + " sig=" + (s.SigUrl != null) + " err=" + s.Error);
            if (s.AssetUrl == null) {
                if (id == "video2all") { s.LatestVersion = "6.1.0"; s.AssetName = "Video2All-Setup.exe"; s.AssetUrl = "https://github.com/Erodyne/Video2All/releases/download/v6.1.0/Video2All-Setup.exe"; }
                else { s.LatestVersion = "1.0.0"; s.AssetName = "DiskVital-Setup-1.0.0.exe"; s.AssetUrl = "https://github.com/Erodyne/Diskvital/releases/download/v1.0.0/DiskVital-Setup-1.0.0.exe"; }
                s.SigUrl = s.AssetUrl + ".sig"; s.ShaUrl = s.AssetUrl + ".sha256";
            }
            try {
                using (var p = Manager.Fetch(s.Snapshot(), (x, t) => { })) {
                    Console.WriteLine(id + " firma valida: " + p.Signed);
                    int code = Manager.RunInstaller(s, p);
                    Manager.DetectLocal(s);
                    Console.WriteLine(id + " installer=" + code + " installato=" + s.Installed + " versione=" + s.InstalledVersion + " exe=" + s.ExePath + " disinstalla=" + (s.UninstallCmd != null));
                }
            } catch (Exception e) { Console.WriteLine(id + " ERRORE " + e.Message); }
        }
    }
}
