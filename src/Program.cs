using System;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("Erodyne Suite")]
[assembly: AssemblyProduct("Erodyne Suite")]
[assembly: AssemblyCompany("Erodyne")]
[assembly: AssemblyDescription("Installa, aggiorna e avvia i programmi Erodyne")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]
[assembly: AssemblyInformationalVersion("1.1.0")]

public static class Program {
    public const string Version = "1.1.0";

    public static void Log(object e) {
        try { System.IO.Directory.CreateDirectory(Settings.Dir); System.IO.File.AppendAllText(System.IO.Path.Combine(Settings.Dir, "errori.log"), DateTime.Now + " " + e + "\r\n"); } catch { }
    }

    [STAThread]
    static void Main() {
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
