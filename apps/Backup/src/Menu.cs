using System;
using System.Drawing;
using System.Windows.Forms;

// Menu a comparsa scuro, nello stile della suite
public static class DarkMenu {
    class Colors : ProfessionalColorTable {
        public override Color ToolStripDropDownBackground { get { return Th.Surface; } }
        public override Color MenuBorder { get { return Th.Border; } }
        public override Color MenuItemBorder { get { return Th.Surface3; } }
        public override Color MenuItemSelected { get { return Th.Surface2; } }
        public override Color MenuItemSelectedGradientBegin { get { return Th.Surface2; } }
        public override Color MenuItemSelectedGradientEnd { get { return Th.Surface2; } }
        public override Color ImageMarginGradientBegin { get { return Th.Surface; } }
        public override Color ImageMarginGradientMiddle { get { return Th.Surface; } }
        public override Color ImageMarginGradientEnd { get { return Th.Surface; } }
        public override Color SeparatorDark { get { return Th.Border; } }
        public override Color SeparatorLight { get { return Th.Border; } }
        public override Color CheckBackground { get { return Th.Surface3; } }
        public override Color CheckSelectedBackground { get { return Th.Surface3; } }
    }
    class Renderer : ToolStripProfessionalRenderer {
        public Renderer() : base(new Colors()) { RoundedEdges = false; }
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            e.TextColor = e.Item.Enabled ? Th.Text : Th.Faint;
            base.OnRenderItemText(e);
        }
        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
            var r = e.ImageRectangle;
            using (var pen = new Pen(Th.C2, 2f)) e.Graphics.DrawLines(pen, new[] { new PointF(r.X + 3, r.Y + r.Height / 2f), new PointF(r.X + r.Width / 2.5f, r.Bottom - 4), new PointF(r.Right - 3, r.Y + 4) });
        }
    }
    public static ContextMenuStrip New() {
        var m = new ContextMenuStrip { Renderer = new Renderer(), Font = Th.F(9.5f), ShowImageMargin = true };
        return m;
    }
    public static ToolStripMenuItem Add(ContextMenuStrip m, string text, Action a, bool enabled = true, bool check = false) {
        var it = new ToolStripMenuItem(text) { Enabled = enabled, Checked = check, Padding = new Padding(4, 6, 4, 6) };
        it.Click += (s, e) => a();
        m.Items.Add(it);
        return it;
    }
    public static void Sep(ContextMenuStrip m) { m.Items.Add(new ToolStripSeparator()); }
}
