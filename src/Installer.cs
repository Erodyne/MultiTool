using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

// Un solo exe: al primo avvio si installa da solo per l'utente (senza permessi di amministratore),
// crea i collegamenti e la voce in "App installate", poi si riapre dalla cartella installata.
// Avviato di nuovo (anche una versione più nuova) aggiorna l'installazione. "--portatile" lo usa senza installarlo.
public static class SelfInstall {
    const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ErodyneSuite";
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\ErodyneSuite");
    public static readonly string Exe = Path.Combine(Dir, "ErodyneSuite.exe");
    static string Me { get { return Path.GetFullPath(Assembly.GetExecutingAssembly().Location); } }
    static string StartLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Erodyne Suite.lnk"); } }
    static string DesktopLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Erodyne Suite.lnk"); } }

    public static bool IsInstalledCopy { get { return string.Equals(Me, Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase); } }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool DeleteFile(string path);

    // true = il chiamante deve chiudersi (l'installazione ha riaperto la copia installata)
    public static bool Handle(string[] args) {
        try { File.Delete(Exe + ".old"); } catch { } // resto di un aggiornamento precedente
        if (Array.IndexOf(args, "--portatile") >= 0 || IsInstalledCopy) return false;

        var installed = InstalledVersion();
        bool newer = installed == null || Ver.Newer(Program.Version, installed);
        bool same = installed != null && !newer && !Ver.Newer(installed, Program.Version);
        if (installed != null && !newer && !same && File.Exists(Exe)) {
            // è installata una versione più recente di questa: si apre quella
            Start(Exe); return true;
        }
        if (same && File.Exists(Exe)) { Start(Exe); return true; }

        if (!CloseRunning("installare la versione " + Program.Version)) return true;
        try {
            Install();
        } catch (Exception e) {
            Program.Log(e);
            return MessageBox.Show("Installazione non riuscita:\n" + e.Message + "\n\nUsare Erodyne Suite senza installarlo?",
                "Erodyne Suite", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes;
        }
        Start(Exe, installed == null ? "--benvenuto" : "--aggiornato");
        return true;
    }

    static void Install() {
        Directory.CreateDirectory(Dir);
        var tmp = Exe + ".new";
        File.Copy(Me, tmp, true);
        DeleteFile(tmp + ":Zone.Identifier"); // già aperto una volta dall'utente: niente secondo avviso di Windows
        if (File.Exists(Exe)) {
            // la copia installata può essere aperta: un exe in uso si può rinominare, non sovrascrivere
            try { File.Delete(Exe + ".old"); } catch { }
            File.Move(Exe, Exe + ".old");
        }
        File.Move(tmp, Exe);
        try { File.Delete(Exe + ".old"); } catch { }

        Shortcut(StartLnk); Shortcut(DesktopLnk);

        using (var k = Registry.CurrentUser.CreateSubKey(KeyPath)) {
            k.SetValue("DisplayName", "Erodyne Suite");
            k.SetValue("DisplayVersion", Program.Version);
            k.SetValue("Publisher", "Erodyne");
            k.SetValue("DisplayIcon", Exe + ",0");
            k.SetValue("InstallLocation", Dir);
            k.SetValue("UninstallString", "\"" + Exe + "\" --disinstalla");
            k.SetValue("QuietUninstallString", "\"" + Exe + "\" --disinstalla --silenzioso");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            k.SetValue("EstimatedSize", (int)Math.Max(1, new FileInfo(Exe).Length / 1024), RegistryValueKind.DWord);
            k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
    [DllImport("user32.dll")] static extern IntPtr PostMessage(IntPtr h, int m, IntPtr w, IntPtr l);

    // La versione installata è aperta: va chiusa, altrimenti la nuova si riaprirebbe come la vecchia
    static bool CloseRunning(string why, bool ask = true) {
        System.Threading.Mutex m;
        if (!System.Threading.Mutex.TryOpenExisting(Program.MutexName, out m)) return true;
        m.Dispose();
        if (ask && MessageBox.Show("Erodyne Suite è aperto. Chiuderlo per " + why + "?", "Erodyne Suite",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return false;
        var h = FindWindow(null, "Erodyne Suite");
        if (h != IntPtr.Zero) PostMessage(h, 0x10, IntPtr.Zero, IntPtr.Zero); // WM_CLOSE: se sta installando chiede conferma
        for (int i = 0; i < 120; i++) {
            System.Threading.Thread.Sleep(250);
            if (!System.Threading.Mutex.TryOpenExisting(Program.MutexName, out m)) return true;
            m.Dispose();
        }
        if (ask) MessageBox.Show("Erodyne Suite non si è chiuso. Chiudilo e riprova.", "Erodyne Suite", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return false;
    }

    static string InstalledVersion() {
        try {
            using (var k = Registry.CurrentUser.OpenSubKey(KeyPath)) {
                var v = k == null ? null : k.GetValue("DisplayVersion") as string;
                return File.Exists(Exe) ? v : null;
            }
        } catch { return null; }
    }

    // Collegamento .lnk tramite WScript.Shell (presente in ogni Windows)
    static void Shortcut(string lnk) {
        try {
            var t = Type.GetTypeFromProgID("WScript.Shell");
            object sh = Activator.CreateInstance(t);
            try {
                object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { lnk });
                var st = sc.GetType();
                st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { Exe });
                st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { Dir });
                st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { Exe + ",0" });
                st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "Installa, aggiorna e avvia i programmi Erodyne" });
                st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
                Marshal.FinalReleaseComObject(sc);
            } finally { Marshal.FinalReleaseComObject(sh); }
        } catch (Exception e) { Program.Log(e); }
    }

    public static void Uninstall(bool silent) {
        if (!silent && MessageBox.Show("Disinstallare Erodyne Suite?\n\nI programmi installati con la suite (MultiTool, Remostation, Acquisizione Video) restano.",
                "Erodyne Suite", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        if (!CloseRunning("disinstallarlo", !silent)) return;
        try { File.Delete(StartLnk); } catch { }
        try { File.Delete(DesktopLnk); } catch { }
        try { Registry.CurrentUser.DeleteSubKeyTree(KeyPath, false); } catch { }
        try { Directory.Delete(Settings.Dir, true); } catch { }
        // l'exe in uso si cancella da solo dopo la chiusura
        try {
            var cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
            Process.Start(new ProcessStartInfo(cmd, "/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"" + Dir + "\"") {
                WindowStyle = ProcessWindowStyle.Hidden, CreateNoWindow = true, UseShellExecute = false, WorkingDirectory = Path.GetTempPath() });
        } catch { }
        if (!silent) MessageBox.Show("Erodyne Suite è stato disinstallato.", "Erodyne Suite", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    static void Start(string exe, string args = "") {
        Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = true, WorkingDirectory = Dir });
    }
}
