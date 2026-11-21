using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("Erodyne Backup")]
[assembly: AssemblyProduct("Erodyne Backup")]
[assembly: AssemblyCompany("Erodyne")]
[assembly: AssemblyDescription("Backup delle cartelle su disco esterno o di rete")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0")]
[assembly: System.Runtime.InteropServices.DefaultDllImportSearchPaths(System.Runtime.InteropServices.DllImportSearchPath.System32)]

public static class Program {
    public const string Version = "1.0.0";
    public const string RunMutex = "Erodyne.Backup.Run";

    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool SetDllDirectory(string path);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);

    [STAThread]
    static int Main(string[] args) {
        try { SetDllDirectory(""); } catch { }
        App.Name = "Erodyne Backup"; App.Folder = "ErodyneBackup"; App.Version = Version;
        App.Description = "Backup delle cartelle su disco esterno o di rete";
        Setup.PerUser = true; Setup.Key = "ErodyneBackup"; Setup.ExeName = "ErodyneBackup.exe";
        Setup.AfterInstall = () => { if (Schedule.On) Schedule.Apply(); };
        Setup.OnUninstall = () => Tasks.Delete(Schedule.TaskName);
        Th.C1 = Color.FromArgb(0x22, 0xD3, 0xEE); Th.C2 = Color.FromArgb(0x3B, 0x82, 0xF6);
        Th.LogoMark = LogoMark;
        AppDomain.CurrentDomain.UnhandledException += (s, e) => App.Log(e.ExceptionObject);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool silent = App.Has(args, "/S") || App.Has(args, "--silenzioso");
        try {
            if (App.Has(args, "--disinstalla")) { Setup.Uninstall(silent); return 0; }
            if (App.Has(args, "--installa") || App.Has(args, "/S")) return Setup.Install(silent) ? 0 : 1;
            if (App.Has(args, "--auto")) return Auto();
            if (Setup.OfferInstall()) return 0;
            Engine.ImportFromMultiTool();
            bool first;
            using (var m = new Mutex(true, "Erodyne.Backup.App", out first)) {
                if (!first) {
                    var h = FindWindow(null, App.Name);
                    if (h != IntPtr.Zero) { ShowWindow(h, 9); SetForegroundWindow(h); }
                    return 0;
                }
                Application.ThreadException += (s, e) => { App.Log(e.Exception); MessageBox.Show(e.Exception.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); };
                var f = new MainForm();
                var shot = App.Arg(args, "--prova");
                if (shot != null) Prova.Attach(f, shot);
                Application.Run(f);
            }
        } catch (Exception e) {
            App.Log(e);
            if (!silent) MessageBox.Show(App.Name + " non riesce ad avviarsi:\n\n" + e.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }

    // Avvio dall'attività pianificata: backup se è ora, altrimenti promemoria se il disco manca da troppo
    static int Auto() {
        try {
            Engine.ImportFromMultiTool();
            if (!Schedule.On || !Schedule.Due()) return 0;
            var last = Engine.LastOk;
            if (!Engine.DestReady) {
                int days = last.HasValue ? (int)(DateTime.Now - last.Value).TotalDays : 999;
                if (days >= 7 && Engine.Dest != null)
                    Notify.Show(App.Name, (last.HasValue ? "Nessun backup da " + days + " giorni" : "Non hai ancora fatto un backup") + ": collega il disco di backup (" + Engine.Dest + ").", ToolTipIcon.Warning);
                return 0;
            }
            bool mine;
            using (var m = new Mutex(true, RunMutex, out mine)) {
                if (!mine) return 0;
                var folders = Engine.Folders().Where(x => x.Def).ToList();
                if (folders.Count == 0) return 0;
                string summary = null; bool ok = false;
                Notify.While("Backup in corso…", () => { ok = Engine.RunAll(folders, CancellationToken.None, null, out summary); });
                if (!ok) Notify.Show(App.Name, summary + ". Apri Erodyne Backup per i dettagli.", ToolTipIcon.Warning);
                else if (Store.GetBool("avviso.completato")) Notify.Show(App.Name, summary, ToolTipIcon.Info);
            }
        } catch (Exception e) { App.Log(e); }
        return 0;
    }

    static void LogoMark(Graphics g, RectangleF r) {
        float u = r.Width / 10f;
        using (var pen = new Pen(Color.White, Math.Max(1.2f, 0.75f * u))) {
            pen.LineJoin = LineJoin.Round; pen.StartCap = pen.EndCap = LineCap.Round;
            // vassoio
            g.DrawLines(pen, new[] { new PointF(r.X + 2.4f * u, r.Y + 5.6f * u), new PointF(r.X + 2.4f * u, r.Y + 7.6f * u), new PointF(r.X + 7.6f * u, r.Y + 7.6f * u), new PointF(r.X + 7.6f * u, r.Y + 5.6f * u) });
            // freccia verso l'alto
            g.DrawLine(pen, r.X + 5f * u, r.Y + 6.1f * u, r.X + 5f * u, r.Y + 2.4f * u);
            g.DrawLines(pen, new[] { new PointF(r.X + 3.5f * u, r.Y + 3.9f * u), new PointF(r.X + 5f * u, r.Y + 2.4f * u), new PointF(r.X + 6.5f * u, r.Y + 3.9f * u) });
        }
    }
}

// Notifiche accanto all'orologio per l'avvio automatico (senza finestra)
public static class Notify {
    public static void Show(string title, string text, ToolTipIcon icon) {
        using (var ni = new NotifyIcon { Visible = true, Text = App.Name }) {
            try { ni.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { ni.Icon = SystemIcons.Information; }
            ni.BalloonTipClicked += (s, e) => { Proc.Open(Setup.Installed ? Setup.Exe : Application.ExecutablePath); Application.ExitThread(); };
            ni.BalloonTipClosed += (s, e) => Application.ExitThread();
            var t = new System.Windows.Forms.Timer { Interval = 15000 };
            t.Tick += (s, e) => { t.Stop(); Application.ExitThread(); };
            t.Start();
            ni.ShowBalloonTip(10000, title, text, icon);
            Application.Run();
            t.Dispose();
            ni.Visible = false;
        }
    }
    // icona accanto all'orologio mentre lavora: si vede che il backup è in corso
    public static void While(string tip, Action work) {
        using (var ni = new NotifyIcon { Visible = true, Text = App.Name + ": " + tip }) {
            try { ni.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { ni.Icon = SystemIcons.Information; }
            var th = new Thread(() => { try { work(); } catch (Exception e) { App.Log(e); } }) { IsBackground = true };
            th.Start();
            while (th.IsAlive) { Application.DoEvents(); Thread.Sleep(200); }
            ni.Visible = false;
        }
    }
}
