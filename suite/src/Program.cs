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
[assembly: AssemblyVersion("1.9.1.0")]
[assembly: AssemblyFileVersion("1.9.1.0")]
[assembly: AssemblyInformationalVersion("1.9.1")]

public static class Program {
    public const string Version = "1.9.1";
    public const string MutexName = "ErodyneSuite.SingleInstance";
    public static string StartMessage;

    public static void Log(object e) {
        try {
            var lf = System.IO.Path.Combine(Settings.Dir, "errori.log");
            if (System.IO.File.Exists(lf) && new System.IO.FileInfo(lf).Length > 1024 * 1024) System.IO.File.Delete(lf); // niente file che cresce all'infinito
        } catch { }
        try { System.IO.Directory.CreateDirectory(Settings.Dir); System.IO.File.AppendAllText(System.IO.Path.Combine(Settings.Dir, "errori.log"), DateTime.Now + " " + e + "\r\n"); } catch { }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] static extern bool SetDllDirectory(string path);

    [STAThread]
    static void Main(string[] args) {
        // niente DLL dalla cartella corrente. (Non si limita tutto il processo a System32: le estensioni di Esplora file
        // caricate dalla finestra "Individua…" hanno DLL nelle loro cartelle e smetterebbero di funzionare.)
        try { SetDllDirectory(""); } catch { }
        AppDomain.CurrentDomain.UnhandledException += (s, e) => { Log(e.ExceptionObject); MessageBox.Show("Errore: " + e.ExceptionObject, "Erodyne Suite"); };
        try {
            if (Array.IndexOf(args, "--disinstalla") >= 0) {
                Application.EnableVisualStyles();
                SelfInstall.Uninstall(Array.IndexOf(args, "--silenzioso") >= 0);
                return;
            }
            Application.EnableVisualStyles();
            if (SelfInstall.Handle(args)) return;
            if (Array.IndexOf(args, "--benvenuto") >= 0) StartMessage = "Erodyne Suite installato: lo trovi nel menu Start e sul desktop";
            else if (Array.IndexOf(args, "--aggiornato") >= 0) StartMessage = "Erodyne Suite aggiornato alla versione " + Version;
            Run();
        } catch (Exception e) { Log(e); MessageBox.Show("Erodyne Suite non riesce ad avviarsi:\n\n" + e, "Erodyne Suite", MessageBoxButtons.OK, MessageBoxIcon.Error); }
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
        using (var m = new Mutex(true, MutexName, out first)) {
            if (!first) {
                // appena installato/aggiornato, la vecchia istanza può impiegare un attimo a chiudersi
                if (StartMessage != null) { try { first = m.WaitOne(5000); } catch (AbandonedMutexException) { first = true; } }
                if (!first) { BringExisting(); return; }
            }
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (s, e) => { Log(e.Exception); MessageBox.Show(e.Exception.Message, "Erodyne Suite", MessageBoxButtons.OK, MessageBoxIcon.Warning); };
            Application.Run(new MainForm());
        }
    }
}
