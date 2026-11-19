using System; using System.IO; using System.Linq;
public static class T {
    public static void Main() {
        var s = new AppState { Def = Catalog.Apps.First(a => a.Id == "multitool") };
        Manager.CheckOnline(s);
        Console.WriteLine("check: ver=" + s.LatestVersion + " asset=" + s.AssetName + " err=" + s.Error);
        if (s.AssetUrl == null) { // limite di GitHub sul runner: release nota
            s.AssetName = "MultiTool-Setup-2026.11.15.2.exe";
            s.AssetUrl = "https://github.com/Erodyne/MultiTool/releases/download/v2026.11.15.2/MultiTool-Setup-2026.11.15.2.exe";
        }
        using (var p = Manager.Fetch(s, (x, t) => { })) {
            Console.WriteLine("fetch: " + p.File + " hash=" + p.Hash + " signed=" + p.Signed);
            try { File.WriteAllText(p.File, "x"); Console.WriteLine("SOVRASCRITTO (male)"); } catch (Exception e) { Console.WriteLine("scrittura bloccata: " + e.GetType().Name); }
            try { File.Delete(p.File); Console.WriteLine("CANCELLATO (male)"); } catch (Exception e) { Console.WriteLine("cancellazione bloccata: " + e.GetType().Name); }
            try { Directory.Move(Path.GetDirectoryName(p.File), Path.GetDirectoryName(p.File) + "x"); Console.WriteLine("CARTELLA SPOSTATA (male)"); } catch (Exception e) { Console.WriteLine("spostamento cartella bloccato: " + e.GetType().Name); }
            var f = p.File;
            p.Dispose(); Console.WriteLine("dopo: esiste=" + File.Exists(f));
        }
        Console.WriteLine("protetta ProgramFiles: " + Manager.InProtectedDir(@"C:\Program Files\MultiTool\MultiTool.exe") + " / AppData: " + Manager.InProtectedDir(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) + @"\x.exe") + " / traversal: " + Manager.InProtectedDir(@"C:\Program Files\..\Users\x.exe"));
        Console.WriteLine("url: " + (Manager.SafeUrl("file:///c:/windows/system32/calc.exe") ?? "null") + " " + (Manager.SafeUrl("http://x", true) ?? "null"));
    }
}
