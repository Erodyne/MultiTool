using System;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("Erodyne Suite")]
// DLL di sistema solo da System32: una DLL omonima lasciata in Download accanto all'exe non viene caricata
[assembly: System.Runtime.InteropServices.DefaultDllImportSearchPaths(System.Runtime.InteropServices.DllImportSearchPath.System32)]
[assembly: AssemblyProduct("Erodyne Suite")]
[assembly: AssemblyCompany("Erodyne")]
[assembly: AssemblyDescription("Installa, aggiorna e avvia i programmi Erodyne")]
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]
[assembly: AssemblyInformationalVersion("1.3.0")]

public static class Program {
    public const string Version = "1.3.0";

    public static void Log(object e) {
        try {
            var lf = System.IO.Path.Combine(Settings.Dir, "errori.log");
            if (System.IO.File.Exists(lf) && new System.IO.FileInfo(lf).Length > 1024 * 1024) System.IO.File.Delete(lf); // niente file che cresce all'infinito
        } catch { }
        try { System.IO.Directory.CreateDirectory(Settings.Dir); System.IO.File.AppendAllText(System.IO.Path.Combine(Settings.Dir, "errori.log"), DateTime.Now + " " + e + "\r\n"); } catch { }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] static extern bool SetDefaultDllDirectories(int flags);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] static extern bool SetDllDirectory(string path);

    [STAThread]
    static void Main() {
        // per tutto il processo (anche le DLL caricate da Windows Forms): niente cartella dell'exe né cartella corrente
        try { SetDllDirectory(""); SetDefaultDllDirectories(0x800); } catch { } // LOAD_LIBRARY_SEARCH_SYSTEM32
        AppDomain.CurrentDomain.UnhandledException += (s, e) => { Log(e.ExceptionObject); MessageBox.Show("Errore: " + e.ExceptionObject, "Erodyne Suite"); };
        try { Run(); } catch (Exception e) { Log(e); MessageBox.Show("Erodyne Suite non riesce ad avviarsi:\n\n" + e, "Erodyne Suite", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);

    // Seconda apertura: porta in primo piano la finestra già aperta invece di non fare nulla
    static void BringExisting() {
        try {
            var h = FindWindow(null, "Erodyne Suite");
            if (h == IntPtr.Zero) return;
            if (IsIconic(h)) ShowWindow(h, 9);
            SetForegroundWindow(h);
        } catch { }
    }

    static void Run() {
        bool first;
        using (var m = new Mutex(true, "ErodyneSuite.SingleInstance", out first)) {
            if (!first) { BringExisting(); return; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (s, e) => { Log(e.Exception); MessageBox.Show(e.Exception.Message, "Erodyne Suite", MessageBoxButtons.OK, MessageBoxIcon.Warning); };
            Application.Run(new MainForm());
        }
    }
}
