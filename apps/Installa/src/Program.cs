using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("Erodyne Installa")]
[assembly: AssemblyProduct("Erodyne Installa")]
[assembly: AssemblyCompany("Erodyne")]
[assembly: AssemblyDescription("Installa i programmi di un PC nuovo con winget")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0")]
[assembly: System.Runtime.InteropServices.DefaultDllImportSearchPaths(System.Runtime.InteropServices.DllImportSearchPath.System32)]

public static class Program {
    public const string Version = "1.0.0";
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool SetDllDirectory(string path);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);

    [STAThread]
    static int Main(string[] args) {
        try { SetDllDirectory(""); } catch { }
        App.Name = "Erodyne Installa"; App.Folder = "ErodyneInstalla"; App.Version = Version;
        App.Description = "Installa i programmi di un PC nuovo con winget";
        Setup.PerUser = false; Setup.Key = "ErodyneInstalla"; Setup.ExeName = "ErodyneInstalla.exe";
        Th.C1 = Color.FromArgb(0x7C, 0x5C, 0xFF); Th.C2 = Color.FromArgb(0xEC, 0x48, 0x99);
        Th.LogoMark = LogoMark;
        AppDomain.CurrentDomain.UnhandledException += (s, e) => App.Log(e.ExceptionObject);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool silent = App.Has(args, "/S") || App.Has(args, "--silenzioso");
        try {
            if (App.Has(args, "--disinstalla")) { Setup.Uninstall(silent); return 0; }
            if (App.Has(args, "--installa") || App.Has(args, "/S")) return Setup.Install(silent) ? 0 : 1;
            if (Setup.OfferInstall()) return 0;
            bool first;
            using (var m = new Mutex(true, "Erodyne.Installa.App", out first)) {
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

    static void LogoMark(Graphics g, RectangleF r) {
        float u = r.Width / 10f;
        using (var pen = new Pen(Color.White, Math.Max(1.2f, 0.75f * u))) {
            pen.LineJoin = LineJoin.Round; pen.StartCap = pen.EndCap = LineCap.Round;
            g.DrawLines(pen, new[] { new PointF(r.X + 2.4f * u, r.Y + 5.6f * u), new PointF(r.X + 2.4f * u, r.Y + 7.6f * u), new PointF(r.X + 7.6f * u, r.Y + 7.6f * u), new PointF(r.X + 7.6f * u, r.Y + 5.6f * u) });
            g.DrawLine(pen, r.X + 5f * u, r.Y + 2.4f * u, r.X + 5f * u, r.Y + 6.1f * u);
            g.DrawLines(pen, new[] { new PointF(r.X + 3.5f * u, r.Y + 4.6f * u), new PointF(r.X + 5f * u, r.Y + 6.1f * u), new PointF(r.X + 6.5f * u, r.Y + 4.6f * u) });
        }
    }
}
