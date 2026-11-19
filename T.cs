using System; using System.IO; using System.Linq; using System.Reflection; using System.Security.AccessControl;
public static class T {
    public static void Main(string[] a) {
        if (a.Length > 0 && a[0] == "acl") { Acl(a[1]); return; }
        var s = new AppState { Def = Catalog.Apps.First(x => x.Id == "multitool") };
        Manager.CheckOnline(s);
        Console.WriteLine("check: ver=" + s.LatestVersion + " sig=" + (s.SigUrl != null) + " err=" + s.Error);
        if (s.AssetUrl == null) {
            s.LatestVersion = "2026.11.15.2"; s.AssetName = "MultiTool-Setup-2026.11.15.2.exe";
            s.AssetUrl = "https://github.com/Erodyne/MultiTool/releases/download/v2026.11.15.2/MultiTool-Setup-2026.11.15.2.exe";
            s.SigUrl = s.AssetUrl + ".sig";
        }
        using (var p = Manager.Fetch(s.Snapshot(), (x, t) => { })) {
            Console.WriteLine("firmato e verificato: " + p.Signed);
            var parent = Path.GetDirectoryName(Path.GetDirectoryName(p.File));
            try { Directory.Move(parent, parent + "_x"); Console.WriteLine("CARTELLA MADRE SPOSTATA (male)"); Directory.Move(parent + "_x", parent); } catch (Exception e) { Console.WriteLine("spostamento cartella madre bloccato: " + e.GetType().Name); }
        }
        var bad = s.Snapshot(); bad.LatestVersion = "2099.1.1";
        try { using (Manager.Fetch(bad, (x, t) => { })) Console.WriteLine("VERSIONE FALSA ACCETTATA (male)"); } catch (Exception e) { Console.WriteLine("versione falsa: " + e.Message); }
        var other = s.Snapshot(); other.Def = Catalog.Apps.First(x => x.Id == "remostation");
        try { using (Manager.Fetch(other, (x, t) => { })) Console.WriteLine("SCAMBIO ACCETTATO (male)"); } catch (Exception e) { Console.WriteLine("installer di un altro programma: " + e.Message); }
        var nosig = s.Snapshot(); nosig.SigUrl = null;
        try { using (Manager.Fetch(nosig, (x, t) => { })) Console.WriteLine("SENZA FIRMA ACCETTATO (male)"); } catch (Exception e) { Console.WriteLine("senza firma: " + e.Message); }
    }
    static void Acl(string root) {
        var dir = Path.Combine(root, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, "Setup.exe");
        using (var w = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
            typeof(Manager).GetMethod("SealDir", BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, new object[] { dir, file });
            w.WriteByte(65); Console.WriteLine("scrittura del download dopo la chiusura: ok");
        }
        Console.WriteLine("utente: " + System.Security.Principal.WindowsIdentity.GetCurrent().Name);
        Try("aggiungere version.dll", () => File.WriteAllText(Path.Combine(dir, "version.dll"), "x"));
        Try("creare sottocartella", () => Directory.CreateDirectory(Path.Combine(dir, "sub")));
        Try("modificare l'installer", () => File.AppendAllText(file, "x"));
        Try("cambiare i permessi", () => { var sec = Directory.GetAccessControl(dir); sec.AddAccessRule(new FileSystemAccessRule("Everyone", FileSystemRights.FullControl, AccessControlType.Allow)); Directory.SetAccessControl(dir, sec); });
        Try("prendere la proprietà", () => { var sec = Directory.GetAccessControl(dir); sec.SetOwner(System.Security.Principal.WindowsIdentity.GetCurrent().User); Directory.SetAccessControl(dir, sec); });
        Try("rinominare l'installer", () => File.Move(file, file + ".old"));
        Try("cancellare (pulizia)", () => { File.Delete(file); Directory.Delete(dir); }, true);
    }
    static void Try(string what, Action a, bool expectOk = false) {
        try { a(); Console.WriteLine(what + ": RIUSCITO" + (expectOk ? " (giusto)" : " (MALE)")); }
        catch (Exception e) { Console.WriteLine(what + ": negato" + (expectOk ? " (MALE)" : "") + " [" + e.GetType().Name + "]"); }
    }
}
