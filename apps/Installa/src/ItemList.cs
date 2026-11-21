using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class ListItem {
    public bool Checked, Checkable = true;
    public string Glyph, Title, Sub, Status;
    public string[] Cols = new string[0];
    public Color StatusColor = Th.Dim;
    public Color? Accent;          // colore del simbolo
    public float Bar = -1;         // barra sotto il nome (0..1), -1 = nessuna
    public object Tag;
}

// Elenco disegnato a mano: casella di spunta, simbolo, nome e dettaglio, colonne a destra, esito.
public class ItemList : Canvas, IWheel {
    public readonly List<ListItem> Items = new List<ListItem>();
    public string[] Headers = new string[0];   // intestazioni delle colonne a destra (Cols)
    public int[] ColW = new int[0];
    public int StatusW = 190;
    public bool Checks = true;
    public string EmptyTitle = "Niente da mostrare", EmptyText = "";
    public int RowH = 58;
    public int Selected = -1;
    public event Action<ListItem> ItemActivated;      // doppio clic o Invio
    public event Action<ListItem, Point> ItemMenu;    // clic destro
    public event Action CheckChanged;
    public event Action SelectionChanged;
    int scroll, hover = -1;
    bool dragThumb; int dragY, dragScroll;
    const int HeadH = 34;

    public ItemList() {
        TabStop = true;
        BackColor = Th.Bg;
        MouseMove += (s, e) => {
            if (dragThumb) { int track = Height - HeadH; int max = MaxScroll; if (track > 0 && max > 0) SetScroll(dragScroll + (int)((e.Y - dragY) * (double)(max + track) / track)); return; }
            int h = HitRow(e.Location); if (h != hover) { hover = h; Invalidate(); }
            Cursor = h >= 0 ? Cursors.Hand : Cursors.Default;
        };
        MouseLeave += (s, e) => { hover = -1; Invalidate(); };
        MouseDown += (s, e) => {
            Focus();
            if (e.Button == MouseButtons.Left && ThumbRect.Contains(e.Location)) { dragThumb = true; dragY = e.Y; dragScroll = scroll; return; }
            int i = HitRow(e.Location);
            if (i < 0) return;
            SetSelected(i);
            if (e.Button == MouseButtons.Right) { if (ItemMenu != null) ItemMenu(Items[i], e.Location); return; }
            if (e.Clicks == 2) { if (ItemActivated != null) ItemActivated(Items[i]); return; }
            if (Checks && Items[i].Checkable) Toggle(i);
        };
        MouseUp += (s, e) => dragThumb = false;
        Resize += (s, e) => SetScroll(scroll);
    }

    public void Reset() { Items.Clear(); scroll = 0; hover = -1; Selected = -1; Invalidate(); }
    public void Refresh_() { SetScroll(scroll); Invalidate(); }
    public ListItem Current { get { return Selected >= 0 && Selected < Items.Count ? Items[Selected] : null; } }

    void Toggle(int i) { Items[i].Checked = !Items[i].Checked; Invalidate(); if (CheckChanged != null) CheckChanged(); }
    void SetSelected(int i) { if (i == Selected) return; Selected = i; Invalidate(); if (SelectionChanged != null) SelectionChanged(); }
    int MaxScroll { get { return Math.Max(0, Items.Count * RowH + 12 - (Height - HeadH)); } }
    void SetScroll(int v) { int n = Math.Max(0, Math.Min(MaxScroll, v)); if (n != scroll) { scroll = n; Invalidate(); } }
    public void OnWheel(int delta) { SetScroll(scroll - delta / 120 * RowH); }
    int HitRow(Point p) {
        if (p.Y < HeadH || p.X > Width - 12) return -1;
        int i = (p.Y - HeadH + scroll) / RowH;
        return i >= 0 && i < Items.Count ? i : -1;
    }
    RectangleF ThumbRect {
        get {
            int track = Height - HeadH, total = Items.Count * RowH + 12;
            if (total <= track || track <= 0) return RectangleF.Empty;
            float h = Math.Max(30, track * (float)track / total), y = HeadH + (track - h) * scroll / (float)MaxScroll;
            return new RectangleF(Width - 9, y, 6, h);
        }
    }
    void EnsureVisible(int i) {
        int top = i * RowH, view = Height - HeadH;
        if (top < scroll) SetScroll(top); else if (top + RowH > scroll + view) SetScroll(top + RowH - view);
    }

    protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || k == Keys.Space || k == Keys.Enter || k == Keys.Home || k == Keys.End || base.IsInputKey(k); }
    protected override void OnKeyDown(KeyEventArgs e) {
        if (Items.Count == 0) { base.OnKeyDown(e); return; }
        int s = Selected;
        if (e.KeyCode == Keys.Down) s = Math.Min(Items.Count - 1, s + 1);
        else if (e.KeyCode == Keys.Up) s = Math.Max(0, s - 1);
        else if (e.KeyCode == Keys.Home) s = 0;
        else if (e.KeyCode == Keys.End) s = Items.Count - 1;
        else if (e.KeyCode == Keys.Space && s >= 0 && Checks && Items[s].Checkable) { Toggle(s); e.Handled = true; return; }
        else if (e.KeyCode == Keys.Enter && s >= 0) { if (ItemActivated != null) ItemActivated(Items[s]); e.Handled = true; return; }
        else if (e.KeyCode == Keys.Apps && s >= 0) { if (ItemMenu != null) ItemMenu(Items[s], new Point(80, HeadH + s * RowH - scroll + RowH / 2)); e.Handled = true; return; }
        else { base.OnKeyDown(e); return; }
        if (s < 0) s = 0;
        SetSelected(s); EnsureVisible(s); e.Handled = true;
    }
    protected override void OnGotFocus(EventArgs e) { if (Selected < 0 && Items.Count > 0) Selected = 0; Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    int ColsWidth { get { int w = StatusW; foreach (var c in ColW) w += c; return w; } }

    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        int W = Width - 14;
        float x0 = Checks ? 52 : 18;
        // intestazione
        using (var f = Th.F(7.5f, FontStyle.Bold)) {
            float cx = W - ColsWidth;
            for (int c = 0; c < ColW.Length; c++) {
                if (c < Headers.Length) Th.Text_(g, Headers[c], f, Th.Faint, new RectangleF(cx, 0, ColW[c] - 12, HeadH), StringAlignment.Far);
                cx += ColW[c];
            }
            if (StatusW > 0) Th.Text_(g, "ESITO", f, Th.Faint, new RectangleF(cx + 12, 0, StatusW - 12, HeadH));
            Th.Text_(g, "NOME", f, Th.Faint, new RectangleF(x0 + 44, 0, 200, HeadH));
        }
        using (var p = new Pen(Th.Border)) g.DrawLine(p, 12, HeadH - 1, W, HeadH - 1);
        if (Items.Count == 0) {
            using (var f = Th.F(13f, FontStyle.Bold)) Th.Text_(g, EmptyTitle, f, Th.Dim, new RectangleF(0, HeadH + 40, Width, 30), StringAlignment.Center);
            using (var f = Th.F(9.5f)) Th.Text_(g, EmptyText, f, Th.Faint, new RectangleF(40, HeadH + 74, Width - 80, 60), StringAlignment.Center, StringAlignment.Near, true);
            return;
        }
        g.SetClip(new Rectangle(0, HeadH, Width, Height - HeadH));
        int first = Math.Max(0, scroll / RowH), last = Math.Min(Items.Count - 1, (scroll + Height) / RowH);
        using (var fT = Th.F(10f, FontStyle.Bold)) using (var fS = Th.F(8.5f)) using (var fC = Th.F(9f)) using (var fG = Th.G(15f)) using (var fK = Th.G(10f))
            for (int i = first; i <= last; i++) {
                var it = Items[i];
                var r = new RectangleF(8, HeadH + i * RowH - scroll + 3, W - 8, RowH - 6);
                bool sel = i == Selected, hov = i == hover;
                if (sel || hov) using (var p = Th.Round(r, 12)) using (var b = new SolidBrush(sel ? Th.Surface2 : Th.Surface)) g.FillPath(b, p);
                if (sel && Focused) using (var p = Th.Round(r, 12)) using (var pen = new Pen(Color.FromArgb(120, Th.C1))) g.DrawPath(pen, p);
                if (Checks && it.Checkable) {
                    var cb = new RectangleF(r.X + 14, r.Y + r.Height / 2 - 10, 20, 20);
                    using (var p = Th.Round(cb, 6)) {
                        if (it.Checked) { using (var b = Th.Grad(cb, Th.C1, Th.C2)) g.FillPath(b, p); }
                        else using (var pen = new Pen(Th.Surface3, 1.5f)) g.DrawPath(pen, p);
                    }
                    if (it.Checked) using (var pen = new Pen(Color.White, 2f)) { pen.StartCap = pen.EndCap = LineCap.Round; g.DrawLines(pen, new[] { new PointF(cb.X + 5, cb.Y + 10.5f), new PointF(cb.X + 8.5f, cb.Y + 14), new PointF(cb.X + 15, cb.Y + 6.5f) }); }
                }
                var gr = new RectangleF(r.X + x0 - 8, r.Y + r.Height / 2 - 17, 34, 34);
                using (var p = Th.Round(gr, 10)) using (var b = new SolidBrush(Color.FromArgb(34, it.Accent ?? Th.C1))) g.FillPath(b, p);
                if (Th.HasGlyphs && it.Glyph != null) Th.Text_(g, it.Glyph, fG, it.Accent ?? Th.C1, gr, StringAlignment.Center);
                float tx = r.X + x0 + 36, tw = W - ColsWidth - tx - 8;
                bool hasSub = !string.IsNullOrEmpty(it.Sub) || it.Bar >= 0;
                Th.Text_(g, it.Title, fT, Th.Text, new RectangleF(tx, hasSub ? r.Y + 7 : r.Y, tw, hasSub ? 22 : r.Height));
                if (it.Bar >= 0) {
                    var br = new RectangleF(tx, r.Y + 33, Math.Max(10, Math.Min(tw, 360)), 6);
                    using (var p = Th.Round(br, 3)) using (var b = new SolidBrush(Th.Surface3)) g.FillPath(b, p);
                    float bw = br.Width * Math.Min(1, it.Bar);
                    if (bw > 3) { var bb = new RectangleF(br.X, br.Y, bw, br.Height); using (var p = Th.Round(bb, 3)) using (var b = Th.Grad(bb, it.Accent ?? Th.C1, Th.C2)) g.FillPath(b, p); }
                    if (!string.IsNullOrEmpty(it.Sub)) Th.Text_(g, it.Sub, fS, Th.Dim, new RectangleF(br.Right + 10, r.Y + 27, Math.Max(0, tx + tw - br.Right - 10), 18));
                } else if (hasSub) Th.Text_(g, it.Sub, fS, Th.Dim, new RectangleF(tx, r.Y + 28, tw, 18));
                float cx = W - ColsWidth;
                for (int c = 0; c < ColW.Length; c++) {
                    if (c < it.Cols.Length) Th.Text_(g, it.Cols[c], fC, Th.Dim, new RectangleF(cx, r.Y, ColW[c] - 12, r.Height), StringAlignment.Far);
                    cx += ColW[c];
                }
                if (StatusW > 0 && !string.IsNullOrEmpty(it.Status)) {
                    using (var b = new SolidBrush(it.StatusColor)) g.FillEllipse(b, cx + 12, r.Y + r.Height / 2 - 3.5f, 7, 7);
                    Th.Text_(g, it.Status, fS, it.StatusColor == Th.Dim ? Th.Dim : Th.Text, new RectangleF(cx + 26, r.Y, StatusW - 28, r.Height));
                }
            }
        g.ResetClip();
        var th = ThumbRect;
        if (!th.IsEmpty) using (var p = Th.Round(th, 3)) using (var b = new SolidBrush(dragThumb ? Th.Dim : Th.Surface3)) g.FillPath(b, p);
    }
}
