using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("Erodyne Spazio")]
[assembly: AssemblyProduct("Erodyne Spazio")]
[assembly: AssemblyCompany("Erodyne")]
[assembly: AssemblyDescription("Cosa occupa lo spazio sui dischi")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0")]
[assembly: System.Runtime.InteropServices.DefaultDllImportSearchPaths(System.Runtime.InteropServices.DllImportSearchPath.System32)]

public static class Program {
    public const string Version = "1.0.0";
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool SetDllDirectory(string path);

    [STAThread]
    static int Main(string[] args) {
        try { SetDllDirectory(""); } catch { }
        App.Name = "Erodyne Spazio"; App.Folder = "ErodyneSpazio"; App.Version = Version;
        App.Description = "Cosa occupa lo spazio sui dischi";
        Setup.PerUser = true; Setup.Key = "ErodyneSpazio"; Setup.ExeName = "ErodyneSpazio.exe";
        Th.C1 = Color.FromArgb(0xFB, 0xBF, 0x24); Th.C2 = Color.FromArgb(0xF9, 0x73, 0x16);
        Th.LogoMark = LogoMark;
        AppDomain.CurrentDomain.UnhandledException += (s, e) => App.Log(e.ExceptionObject);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool silent = App.Has(args, "/S") || App.Has(args, "--silenzioso");
        try {
            if (App.Has(args, "--disinstalla")) { Setup.Uninstall(silent); return 0; }
            if (App.Has(args, "--installa") || App.Has(args, "/S")) return Setup.Install(silent) ? 0 : 1;
            if (Setup.OfferInstall()) return 0;
            Application.ThreadException += (s, e) => { App.Log(e.Exception); MessageBox.Show(e.Exception.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); };
            var f = new MainForm(App.Arg(args, "--cartella"));
            var shot = App.Arg(args, "--prova");
            if (shot != null) Prova.Attach(f, shot);
            Application.Run(f);
        } catch (Exception e) {
            App.Log(e);
            if (!silent) MessageBox.Show(App.Name + " non riesce ad avviarsi:\n\n" + e.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }

    static void LogoMark(Graphics g, RectangleF r) {
        float u = r.Width / 10f, w = Math.Max(1.2f, 0.75f * u);
        using (var pen = new Pen(Color.White, w) { StartCap = LineCap.Round, EndCap = LineCap.Round }) {
            g.DrawArc(pen, r.X + 2.3f * u, r.Y + 2.3f * u, 5.4f * u, 5.4f * u, 0, 270);
            g.DrawLine(pen, r.X + 5f * u, r.Y + 5f * u, r.X + 5f * u, r.Y + 2.3f * u);
            g.DrawLine(pen, r.X + 5f * u, r.Y + 5f * u, r.X + 7.7f * u, r.Y + 5f * u);
        }
        using (var b = new SolidBrush(Color.White)) g.FillPie(b, r.X + 5.5f * u, r.Y + 1.9f * u, 2.8f * u, 2.8f * u, 270, 90);
    }
}
