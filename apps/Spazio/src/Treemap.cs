using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

// Mappa dello spazio: ogni rettangolo è grande quanto la cartella o il file che rappresenta
public class Treemap : Canvas {
    public Node Folder;
    public event Action<Node> OpenFolder;
    public event Action<Node> Picked;
    public event Action<Node, Point> Menu;
    List<KeyValuePair<Node, RectangleF>> cells = new List<KeyValuePair<Node, RectangleF>>();
    Node hover;
    readonly ToolTip tip = new ToolTip { InitialDelay = 300, ReshowDelay = 100 };

    public Treemap() {
        BackColor = Th.Surface;
        Resize += (s, e) => Rebuild();
        MouseMove += (s, e) => {
            var n = Hit(e.Location);
            if (n == hover) return;
            hover = n; Invalidate();
            Cursor = n != null && n.IsDir ? Cursors.Hand : Cursors.Default;
            tip.SetToolTip(this, n == null ? null : n.Name + "\n" + Fmt.Size(n.Size) + (n.IsDir ? " · " + n.Files.ToString("N0") + " file" : ""));
        };
        MouseLeave += (s, e) => { hover = null; Invalidate(); };
        MouseClick += (s, e) => {
            var n = Hit(e.Location); if (n == null) return;
            if (e.Button == MouseButtons.Right) { if (Menu != null) Menu(n, e.Location); return; }
            if (n.IsDir && OpenFolder != null) OpenFolder(n); else if (Picked != null) Picked(n);
        };
    }
    public void Show(Node folder) { Folder = folder; hover = null; Rebuild(); }
    void Rebuild() {
        cells = Folder == null || Folder.Kids == null ? new List<KeyValuePair<Node, RectangleF>>() : Squarify.Layout(Folder.Kids, new RectangleF(6, 6, Width - 12, Height - 12));
        Invalidate();
    }
    Node Hit(Point p) { foreach (var c in cells) if (c.Value.Contains(p)) return c.Key; return null; }

    static readonly Color[] Palette = {
        Color.FromArgb(0xFB, 0xBF, 0x24), Color.FromArgb(0xF9, 0x73, 0x16), Color.FromArgb(0x7C, 0x5C, 0xFF), Color.FromArgb(0x22, 0xD3, 0xEE),
        Color.FromArgb(0x34, 0xD3, 0x99), Color.FromArgb(0xEC, 0x48, 0x99), Color.FromArgb(0x3B, 0x82, 0xF6), Color.FromArgb(0xA3, 0xE6, 0x35) };
    public static Color ColorOf(Node n) {
        if (n.IsDir) return Th.C1;
        if (n.IsOther) return Th.Faint;
        var e = System.IO.Path.GetExtension(n.Name).ToLowerInvariant();
        int h = 0; foreach (var ch in e) h = h * 31 + ch;
        return Palette[(h & 0x7FFFFFFF) % Palette.Length];
    }

    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        if (cells.Count == 0) {
            using (var f = Th.F(10f)) Th.Text_(g, Folder == null ? "" : "Cartella vuota", f, Th.Faint, new RectangleF(0, 0, Width, Height), StringAlignment.Center);
            return;
        }
        using (var f1 = Th.F(9f, FontStyle.Bold)) using (var f2 = Th.F(8f))
            foreach (var c in cells) {
                var r = c.Value; var n = c.Key;
                var rr = new RectangleF(r.X + 1.5f, r.Y + 1.5f, r.Width - 3, r.Height - 3);
                if (rr.Width < 2 || rr.Height < 2) continue;
                var col = ColorOf(n);
                int alpha = n == hover ? 210 : n.IsDir ? 150 : 120;
                using (var p = Th.Round(rr, Math.Min(8, Math.Min(rr.Width, rr.Height) / 3)))
                using (var b = Th.Grad(rr, Color.FromArgb(alpha, col), Color.FromArgb(alpha - 50, Th.Mix(col, Th.Bg, 0.35f)))) g.FillPath(b, p);
                if (rr.Width > 60 && rr.Height > 34) {
                    Th.Text_(g, n.Name, f1, Color.White, new RectangleF(rr.X + 8, rr.Y + 6, rr.Width - 14, 18));
                    Th.Text_(g, Fmt.Size(n.Size), f2, Color.FromArgb(220, 255, 255, 255), new RectangleF(rr.X + 8, rr.Y + 22, rr.Width - 14, 16));
                }
            }
    }
}
