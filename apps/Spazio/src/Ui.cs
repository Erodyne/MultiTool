using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

// Tema condiviso della Erodyne Suite: stessi colori di MultiTool, DiskVital e della suite.
public static class Th {
    public static readonly Color Bg = Color.FromArgb(0x0B, 0x0D, 0x12);
    public static readonly Color Side = Color.FromArgb(0x10, 0x13, 0x1B);
    public static readonly Color Surface = Color.FromArgb(0x14, 0x18, 0x23);
    public static readonly Color Surface2 = Color.FromArgb(0x1C, 0x20, 0x30);
    public static readonly Color Surface3 = Color.FromArgb(0x2A, 0x30, 0x42);
    public static readonly Color Border = Color.FromArgb(0x22, 0x27, 0x36);
    public static readonly Color Text = Color.FromArgb(0xE8, 0xEA, 0xF2);
    public static readonly Color Dim = Color.FromArgb(0x9A, 0xA0, 0xB8);
    public static readonly Color Faint = Color.FromArgb(0x6B, 0x72, 0x90);
    public static readonly Color A1 = Color.FromArgb(0x7C, 0x5C, 0xFF);
    public static readonly Color A2 = Color.FromArgb(0x22, 0xD3, 0xEE);
    public static readonly Color Green = Color.FromArgb(0x34, 0xD3, 0x99);
    public static readonly Color Amber = Color.FromArgb(0xFB, 0xBF, 0x24);
    public static readonly Color Red = Color.FromArgb(0xF8, 0x71, 0x71);

    public static readonly string Family = Pick("Segoe UI Variable Display", "Segoe UI", "DejaVu Sans");
    public static readonly bool HasGlyphs = Exists("Segoe MDL2 Assets") || Exists("Segoe Fluent Icons");
    static readonly string GlyphFamily = Exists("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";

    static bool Exists(string f) {
        try { using (var ff = new FontFamily(f)) return ff.Name.Equals(f, StringComparison.OrdinalIgnoreCase); } catch { return false; }
    }
    static string Pick(params string[] f) { foreach (var x in f) if (Exists(x)) return x; return FontFamily.GenericSansSerif.Name; }

    public static Font F(float size, FontStyle st = FontStyle.Regular) { return new Font(Family, size, st, GraphicsUnit.Point); }
    public static Font G(float size) { return new Font(GlyphFamily, size, FontStyle.Regular, GraphicsUnit.Point); }

    public static GraphicsPath Round(RectangleF r, float rad) {
        var p = new GraphicsPath();
        float d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
        if (d <= 0.5f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    public static Brush Grad(RectangleF r, Color a, Color b) {
        if (r.Width < 1 || r.Height < 1) return new SolidBrush(a);
        return new LinearGradientBrush(r, a, b, 35f);
    }
    public static void Hq(Graphics g) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
    }
    public static Color Mix(Color a, Color b, float t) {
        return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }
    public static void Text_(Graphics g, string s, Font f, Color c, RectangleF r, StringAlignment h = StringAlignment.Near, StringAlignment v = StringAlignment.Center, bool wrap = false) {
        using (var sf = new StringFormat { Alignment = h, LineAlignment = v, Trimming = StringTrimming.EllipsisCharacter })
        using (var b = new SolidBrush(c)) {
            if (!wrap) sf.FormatFlags |= StringFormatFlags.NoWrap;
            g.DrawString(s ?? "", f, b, r, sf);
        }
    }

    // colori e disegno del logo dell'app (impostati da Program)
    public static Color C1 = A1, C2 = A2;
    public static Action<Graphics, RectangleF> LogoMark;
    public static void Logo(Graphics g, RectangleF r) {
        using (var p = Round(r, r.Width * 0.28f))
        using (var br = Grad(r, C1, C2)) g.FillPath(br, p);
        if (LogoMark != null) LogoMark(g, r);
    }

    public static void Pill(Graphics g, string text, Color c, PointF at, out float width, float max = 10000) {
        using (var f = F(8.5f, FontStyle.Bold)) {
            var sz = g.MeasureString(text, f);
            var r = new RectangleF(at.X, at.Y, Math.Min(sz.Width + 22, max), 24);
            using (var p = Round(r, 12))
            using (var b = new SolidBrush(Color.FromArgb(38, c))) g.FillPath(b, p);
            using (var b = new SolidBrush(c)) g.FillEllipse(b, r.X + 9, r.Y + 9, 6, 6);
            Text_(g, text, f, c, new RectangleF(r.X + 18, r.Y, r.Width - 18, r.Height));
            width = r.Width;
        }
    }
}

public enum BtnKind { Primary, Secondary, Ghost, Danger, OnColor }

public class Btn : Control {
    public BtnKind Kind = BtnKind.Secondary;
    public string Glyph;
    public Color? C1, C2, HoverColor;
    bool hover, down;

    public Btn() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor | ControlStyles.Selectable, true);
        BackColor = Color.Transparent;
        TabStop = true;
        AccessibleRole = AccessibleRole.PushButton; // letto come pulsante dai lettori di schermo
        Cursor = Cursors.Hand;
        Font = Th.F(9.5f, FontStyle.Bold);
        Height = 40;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x84 && EdgeHelper.OnEdge(this, m.LParam)) { m.Result = (IntPtr)(-1); return; }
        base.WndProc(ref m);
    }
    public int Measure() {
        using (var g = CreateGraphics()) return (int)g.MeasureString(Text, Font).Width + 36 + (Glyph != null && Th.HasGlyphs ? 22 : 0);
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnTextChanged(EventArgs e) { AccessibleName = Text; Invalidate(); base.OnTextChanged(e); }
    // da tastiera: Tab per spostarsi, Invio o Spazio per premere
    protected override bool IsInputKey(Keys k) { return k == Keys.Enter || k == Keys.Space || base.IsInputKey(k); }
    protected override void OnKeyUp(KeyEventArgs e) {
        if (Enabled && (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)) { e.Handled = true; OnClick(EventArgs.Empty); }
        base.OnKeyUp(e);
    }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        Color fg = Th.Text;
        using (var p = Th.Round(r, 10)) {
            switch (Kind) {
                case BtnKind.Primary:
                    if (!Enabled) { using (var b = new SolidBrush(Th.Surface3)) g.FillPath(b, p); fg = Th.Faint; break; }
                    using (var b = Th.Grad(r, C1 ?? Th.A1, C2 ?? Th.A2)) g.FillPath(b, p);
                    if (hover) using (var b = new SolidBrush(Color.FromArgb(down ? 50 : 28, 255, 255, 255))) g.FillPath(b, p);
                    fg = Color.White;
                    break;
                case BtnKind.OnColor:
                    using (var b = new SolidBrush(Color.FromArgb(!Enabled ? 22 : hover ? 70 : 46, 255, 255, 255))) g.FillPath(b, p);
                    using (var pen = new Pen(Color.FromArgb(Enabled ? 90 : 45, 255, 255, 255))) g.DrawPath(pen, p);
                    fg = Color.FromArgb(Enabled ? 255 : 150, 255, 255, 255);
                    break;
                case BtnKind.Ghost:
                    if (hover && Enabled) using (var b = new SolidBrush(HoverColor ?? Th.Surface2)) g.FillPath(b, p);
                    fg = Enabled ? (hover ? (HoverColor.HasValue ? Color.White : Th.Text) : Th.Dim) : Th.Faint;
                    break;
                case BtnKind.Danger:
                    using (var b = new SolidBrush(hover && Enabled ? Color.FromArgb(46, Th.Red) : Th.Surface2)) g.FillPath(b, p);
                    using (var pen = new Pen(hover && Enabled ? Th.Red : Th.Border)) g.DrawPath(pen, p);
                    fg = Enabled ? Th.Red : Th.Faint;
                    break;
                default:
                    using (var b = new SolidBrush(hover && Enabled ? Th.Surface3 : Th.Surface2)) g.FillPath(b, p);
                    using (var pen = new Pen(Th.Border)) g.DrawPath(pen, p);
                    fg = Enabled ? Th.Text : Th.Faint;
                    break;
            }
        }
        if (Focused && ShowFocusCues) using (var p = Th.Round(new RectangleF(2, 2, Width - 5, Height - 5), 8)) using (var pen = new Pen(Color.FromArgb(200, 255, 255, 255), 1.5f) { DashStyle = DashStyle.Dot }) g.DrawPath(pen, p);
        if (Glyph != null && Th.HasGlyphs) {
            var sz = g.MeasureString(Text, Font);
            float total = sz.Width + 22, x = (Width - total) / 2f;
            using (var gf = Th.G(10.5f)) Th.Text_(g, Glyph, gf, fg, new RectangleF(x, 0, 18, Height), StringAlignment.Center);
            Th.Text_(g, Text, Font, fg, new RectangleF(x + 22, 0, sz.Width + 4, Height));
        } else Th.Text_(g, Text, Font, fg, new RectangleF(0, 0, Width, Height), StringAlignment.Center);
    }
}

// Pannello disegnato a mano, senza sfarfallio
public class Canvas : Panel {
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x84 && EdgeHelper.OnEdge(this, m.LParam)) { m.Result = (IntPtr)(-1); return; }
        base.WndProc(ref m);
    }
    public Canvas() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        BackColor = Th.Bg;
    }
}

// Sui bordi della finestra i controlli figli lasciano passare il mouse alla finestra, che gestisce il ridimensionamento
public static class EdgeHelper {
    public static bool OnEdge(Control c, IntPtr lp) {
        var f = c.FindForm() as AppForm;
        return f != null && f.HitEdge(lp) != 0;
    }
}
