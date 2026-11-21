using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Rotellina del mouse: la riceve il pannello sotto il puntatore, anche senza fuoco
public interface IWheel { void OnWheel(int delta); }

// Finestra senza bordi nello stile della Erodyne Suite: barra del titolo disegnata, contenuto, barra di stato con avanzamento.
public class AppForm : Form, IMessageFilter {
    protected readonly Canvas title = new Canvas(), content = new Canvas(), bar = new Canvas();
    readonly Btn bMin = new Btn { Kind = BtnKind.Ghost, Text = "—" }, bMax = new Btn { Kind = BtnKind.Ghost, Text = "▢" }, bClose = new Btn { Kind = BtnKind.Ghost, Text = "✕" };
    protected const int TitleH = 46, BarH = 34;
    string status = "";
    double progress = -1;           // -1 niente, 0..1 avanzamento, 2 in corso senza percentuale
    public string AppTitle, AppSub;

    public string Status { get { return status; } set { status = value ?? ""; if (bar.IsHandleCreated) bar.Invalidate(); } }
    public double Progress { get { return progress; } set { progress = value; if (bar.IsHandleCreated) bar.Invalidate(); } }

    public AppForm(string name, string sub) {
        AppTitle = name; AppSub = sub;
        Text = name;
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Th.Bg; ForeColor = Th.Text;
        var wa = Screen.PrimaryScreen.WorkingArea;
        MinimumSize = new Size(Math.Min(900, wa.Width), Math.Min(600, wa.Height));
        Size = new Size(Math.Min(1180, wa.Width), Math.Min(760, wa.Height));
        StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;
        Padding = new Padding(1);
        KeyPreview = true;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        title.Height = TitleH; title.Dock = DockStyle.Top; title.BackColor = Th.Side;
        bar.Height = BarH; bar.Dock = DockStyle.Bottom;
        content.Dock = DockStyle.Fill;
        Controls.Add(content); Controls.Add(bar); Controls.Add(title);

        title.Paint += PaintTitle;
        title.MouseDown += (s, e) => { if (e.Button != MouseButtons.Left) return; if (e.Clicks == 2) ToggleMax(); else DragWindow(); };
        foreach (var b in new[] { bMin, bMax, bClose }) { b.Size = new Size(46, TitleH); b.Font = Th.F(10f); b.TabStop = false; title.Controls.Add(b); }
        bMin.Click += (s, e) => WindowState = FormWindowState.Minimized;
        bMax.Click += (s, e) => ToggleMax();
        bClose.Click += (s, e) => Close();
        bClose.HoverColor = Th.Red;
        title.Resize += (s, e) => { bClose.Left = title.Width - 46; bMax.Left = bClose.Left - 46; bMin.Left = bMax.Left - 46; };
        bar.Paint += PaintBar;
        Application.AddMessageFilter(this);
    }

    public void Ui(Action a) { try { if (IsHandleCreated && !IsDisposed) BeginInvoke(a); } catch { } }

    void PaintTitle(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        Th.Logo(g, new RectangleF(16, 11, 24, 24));
        using (var f = Th.F(10.5f, FontStyle.Bold)) {
            var w = g.MeasureString(AppTitle, f).Width;
            Th.Text_(g, AppTitle, f, Th.Text, new RectangleF(50, 0, w + 4, TitleH));
            using (var f2 = Th.F(9f)) Th.Text_(g, AppSub, f2, Th.Faint, new RectangleF(54 + w, 0, Math.Max(0, title.Width - 54 - w - 160), TitleH));
        }
    }

    void PaintBar(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        using (var p = new Pen(Th.Border)) g.DrawLine(p, 0, 0, bar.Width, 0);
        bool prog = progress >= 0;
        using (var f = Th.F(8.5f)) Th.Text_(g, status, f, Th.Dim, new RectangleF(20, 0, bar.Width - (prog ? 280 : 40), BarH));
        if (!prog) return;
        var r = new RectangleF(bar.Width - 240, BarH / 2f - 3, 220, 6);
        using (var p = Th.Round(r, 3)) using (var b = new SolidBrush(Th.Surface3)) g.FillPath(b, p);
        float w = progress <= 1 ? (float)(r.Width * progress) : r.Width * 0.3f;
        if (progress > 1) r.X += (float)((Environment.TickCount / 8) % (int)(r.Width * 0.7f));
        if (w > 6) { var rr = new RectangleF(r.X, r.Y, w, r.Height); using (var p = Th.Round(rr, 3)) using (var b = Th.Grad(rr, Th.C1, Th.C2)) g.FillPath(b, p); }
    }

    // l'avanzamento indeterminato si anima da solo
    readonly Timer anim = new Timer { Interval = 40 };
    protected override void OnShown(EventArgs e) {
        anim.Tick += (s, a) => { if (progress > 1) bar.Invalidate(); };
        anim.Start();
        base.OnShown(e);
    }

    // ---------- finestra senza bordi ----------
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    void DragWindow() { try { ReleaseCapture(); SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); } catch { } }
    void ToggleMax() { WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized; }
    protected override CreateParams CreateParams {
        get { var cp = base.CreateParams; cp.Style |= 0x10000 | 0x20000 | 0x40000; return cp; }
    }
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try { int v = 2; DwmSetWindowAttribute(Handle, 33, ref v, 4); } catch { }
        try { int dark = 1; DwmSetWindowAttribute(Handle, 20, ref dark, 4); } catch { }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x83 && m.WParam != IntPtr.Zero) {
            if (WindowState == FormWindowState.Maximized) {
                var wa = Screen.FromHandle(Handle).WorkingArea;
                Marshal.WriteInt32(m.LParam, 0, wa.Left); Marshal.WriteInt32(m.LParam, 4, wa.Top);
                Marshal.WriteInt32(m.LParam, 8, wa.Right); Marshal.WriteInt32(m.LParam, 12, wa.Bottom);
            }
            m.Result = IntPtr.Zero; return;
        }
        if (m.Msg == 0x84) { int h = HitEdge(m.LParam); if (h != 0) { m.Result = (IntPtr)h; return; } }
        if (m.Msg == 0xAE || m.Msg == 0xAF) { m.Result = IntPtr.Zero; return; }
        if (m.Msg == 0x85) { m.Result = IntPtr.Zero; return; }
        if (m.Msg == 0x86) { m.LParam = new IntPtr(-1); base.WndProc(ref m); m.Result = (IntPtr)1; return; }
        if ((m.Msg == 0x0C || m.Msg == 0x80) && IsHandleCreated) {
            int st = GetWindowLong(Handle, -16);
            SetWindowLong(Handle, -16, st & ~0x10000000);
            base.WndProc(ref m);
            SetWindowLong(Handle, -16, st);
            return;
        }
        base.WndProc(ref m);
        if (m.Msg == 0x24) {
            try {
                var sc = Screen.FromHandle(Handle); var wa = sc.WorkingArea; var bd = sc.Bounds;
                Marshal.WriteInt32(m.LParam, 8, wa.Width); Marshal.WriteInt32(m.LParam, 12, wa.Height);
                Marshal.WriteInt32(m.LParam, 16, wa.Left - bd.Left); Marshal.WriteInt32(m.LParam, 20, wa.Top - bd.Top);
            } catch { }
        }
    }
    public int HitEdge(IntPtr lp) {
        if (WindowState != FormWindowState.Normal) return 0;
        long v = lp.ToInt64();
        var p = PointToClient(new Point((short)(v & 0xFFFF), (short)((v >> 16) & 0xFFFF)));
        const int g = 7; bool l = p.X < g, r = p.X >= Width - g, t = p.Y < g, b = p.Y >= Height - g;
        if (t && l) return 13; if (t && r) return 14; if (b && l) return 16; if (b && r) return 17;
        if (l) return 10; if (r) return 11; if (t) return 12; if (b) return 15;
        return 0;
    }
    protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); bMax.Text = WindowState == FormWindowState.Maximized ? "❐" : "▢"; content.Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) { base.OnPaint(e); using (var p = new Pen(Th.Border)) e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1); }
    protected override void OnFormClosed(FormClosedEventArgs e) { Application.RemoveMessageFilter(this); anim.Stop(); base.OnFormClosed(e); }

    public bool PreFilterMessage(ref Message m) {
        if (m.Msg != 0x020A || !Visible || !ContainsFocus && Form.ActiveForm != this) return false;
        var c = GetChildAtPoint(PointToClient(Cursor.Position));
        Control hit = null;
        while (c != null) { hit = c; var p = c.PointToClient(Cursor.Position); var cc = c.GetChildAtPoint(p); if (cc == null) break; c = cc; }
        for (var x = hit; x != null && x != this; x = x.Parent) {
            var w = x as IWheel;
            if (w != null) { w.OnWheel((short)((m.WParam.ToInt64() >> 16) & 0xFFFF)); return true; }
        }
        return false;
    }
}
