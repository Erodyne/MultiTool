using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

public class MainForm : AppForm {
    readonly ItemList list = new ItemList { Checks = false, RowH = 54 };
    readonly Treemap map = new Treemap();
    readonly Btn bPick = new Btn { Text = "Scegli cartella…", Glyph = "" };
    readonly Btn bAdmin = new Btn { Text = "Analizza come amministratore", Glyph = "" };
    readonly Btn bNew = new Btn { Text = "Nuova analisi", Glyph = "" };
    readonly Btn bUp = new Btn { Text = "Su", Glyph = "" };
    readonly Btn bStop = new Btn { Kind = BtnKind.Danger, Text = "Interrompi" };
    readonly Btn[] tabs = { new Btn { Text = "Cartelle", Glyph = "" }, new Btn { Text = "File più grandi", Glyph = "" }, new Btn { Text = "Tipi di file", Glyph = "" } };
    int page;        // 0 dischi, 1 scansione, 2 risultati
    int tab;
    Scanner scan;
    Node cur;
    CancellationTokenSource cts;
    List<DriveInfo> drives = new List<DriveInfo>();
    List<RectangleF> driveRects = new List<RectangleF>();
    List<KeyValuePair<Node, RectangleF>> crumbs = new List<KeyValuePair<Node, RectangleF>>();
    int driveHover = -1;
    const int M = 28;
    readonly string startPath;
    static bool Elevated { get { try { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); } catch { return false; } } }

    public MainForm(string start) : base("Erodyne Spazio", "Cosa occupa il disco") {
        startPath = start;
        content.Controls.Add(list); content.Controls.Add(map);
        foreach (var b in new[] { bPick, bAdmin, bNew, bUp, bStop }) content.Controls.Add(b);
        foreach (var b in tabs) content.Controls.Add(b);
        for (int i = 0; i < tabs.Length; i++) { int k = i; tabs[i].Click += (s, e) => SetTab(k); }
        bAdmin.Visible = !Elevated;
        bPick.Click += (s, e) => PickFolder();
        bAdmin.Click += (s, e) => RunAsAdmin();
        bNew.Click += (s, e) => { page = 0; LoadDrives(); UpdateUi(); };
        bUp.Click += (s, e) => { if (cur != null && cur.Parent != null) Navigate(cur.Parent); };
        bStop.Click += (s, e) => { if (cts != null) cts.Cancel(); };
        list.ItemActivated += it => { var n = it.Tag as Node; if (n == null) return; if (n.IsDir) Navigate(n); else if (!n.IsOther) Proc.Explore(n.Path, true); };
        list.ItemMenu += (it, p) => NodeMenu(it.Tag as Node, list, p);
        list.SelectionChanged += () => { };
        map.OpenFolder += Navigate;
        map.Picked += n => { int i = list.Items.FindIndex(x => x.Tag == n); if (i >= 0) { list.Selected = i; list.Invalidate(); } };
        map.Menu += (n, p) => NodeMenu(n, map, p);
        content.Paint += PaintContent;
        content.Resize += (s, e) => Layout_();
        content.MouseMove += (s, e) => {
            int h = -1;
            if (page == 0) for (int i = 0; i < driveRects.Count; i++) if (driveRects[i].Contains(e.Location)) h = i;
            bool crumb = page == 2 && crumbs.Any(c => c.Value.Contains(e.Location));
            content.Cursor = h >= 0 || crumb ? Cursors.Hand : Cursors.Default;
            if (h != driveHover) { driveHover = h; content.Invalidate(); }
        };
        content.MouseClick += (s, e) => {
            if (page == 0) { for (int i = 0; i < driveRects.Count; i++) if (driveRects[i].Contains(e.Location)) { Start(drives[i].RootDirectory.FullName); return; } }
            if (page == 2) foreach (var c in crumbs) if (c.Value.Contains(e.Location)) { Navigate(c.Key); return; }
        };
        KeyDown += (s, e) => {
            if (e.KeyCode == Keys.Back && page == 2 && cur != null && cur.Parent != null) { Navigate(cur.Parent); e.Handled = true; }
            else if (e.KeyCode == Keys.F5 && page == 2 && scan != null) { Start(scan.Root.Path); e.Handled = true; }
            else if (e.KeyCode == Keys.Delete && page == 2 && list.Current != null) { Delete(list.Current.Tag as Node); e.Handled = true; }
        };
        FormClosing += (s, e) => { if (cts != null) cts.Cancel(); };
        Shown += (s, e) => { LoadDrives(); UpdateUi(); if (!string.IsNullOrEmpty(startPath) && Directory.Exists(startPath)) Start(startPath); };
        Prova.Steps.Add(new Prova.Step { Name = "dischi" });
        Prova.Steps.Add(new Prova.Step { Name = "analisi", Do = () => Start(Environment.GetFolderPath(Environment.SpecialFolder.Windows)), Ready = () => page == 2, MaxSec = 600 });
        Prova.Steps.Add(new Prova.Step { Name = "file-grandi", Do = () => SetTab(1) });
        Prova.Steps.Add(new Prova.Step { Name = "tipi", Do = () => SetTab(2) });
        Prova.Steps.Add(new Prova.Step { Name = "sottocartella", Do = () => { SetTab(0); var d = cur == null ? null : cur.Kids.FirstOrDefault(x => x.IsDir); if (d != null) Navigate(d); } });
    }

    void LoadDrives() {
        drives = DriveInfo.GetDrives().Where(d => { try { return d.IsReady && (d.DriveType == DriveType.Fixed || d.DriveType == DriveType.Removable || d.DriveType == DriveType.Network); } catch { return false; } }).ToList();
    }

    void UpdateUi() {
        bool res = page == 2;
        bPick.Visible = page == 0;
        bAdmin.Visible = !Elevated && page != 1;
        bNew.Visible = res; bUp.Visible = res && tab == 0; bUp.Enabled = cur != null && cur.Parent != null;
        bStop.Visible = page == 1;
        foreach (var t in tabs) t.Visible = res;
        for (int i = 0; i < tabs.Length; i++) { tabs[i].Kind = i == tab ? BtnKind.Primary : BtnKind.Ghost; tabs[i].C1 = Th.C1; tabs[i].C2 = Th.C2; }
        list.Visible = res; map.Visible = res && tab == 0;
        Layout_(); content.Invalidate();
    }

    void Layout_() {
        int W = content.Width, H = content.Height;
        if (W < 50) return;
        if (page == 0) {
            int bw = bPick.Measure(); bPick.SetBounds(W - M - bw, 30, bw, 40);
            if (bAdmin.Visible) { int aw = bAdmin.Measure(); bAdmin.SetBounds(bPick.Left - 10 - aw, 30, aw, 40); }
            return;
        }
        if (page == 1) { bStop.SetBounds(W / 2 - 70, H / 2 + 70, 140, 40); return; }
        int x = W - M;
        foreach (var b in new[] { bNew, bAdmin }) { if (!b.Visible) continue; int w = b.Measure(); x -= w; b.SetBounds(x, 20, w, 38); x -= 8; }
        int tx = M;
        foreach (var t in tabs) { int w = t.Measure(); t.SetBounds(tx, 72, w, 36); tx += w + 6; }
        if (bUp.Visible) { int uw = bUp.Measure(); bUp.SetBounds(W - M - uw, 72, uw, 36); }
        int top = 122;
        if (tab == 0) {
            int lw = (int)Math.Max(360, (W - 2 * M) * 0.42);
            list.SetBounds(M - 8, top, lw, H - top - 14);
            map.SetBounds(M + lw + 8, top + 4, W - 2 * M - lw - 8, H - top - 22);
        } else list.SetBounds(M - 8, top, W - 2 * M + 8, H - top - 14);
    }

    // ---------- scansione ----------
    void Start(string path) {
        if (cts != null) cts.Cancel();
        cts = new CancellationTokenSource();
        var ct = cts.Token;
        var s = new Scanner();
        scan = null; cur = null;
        page = 1; UpdateUi();
        Progress = 2; Status = "Analizzo " + path + "…";
        var sw = Stopwatch.StartNew();
        var tm = new System.Windows.Forms.Timer { Interval = 50 };
        tm.Tick += (o, e) => { Status = s.FilesSeen.ToString("N0") + " file · " + s.DirsSeen.ToString("N0") + " cartelle · " + s.Current; content.Invalidate(); };
        tm.Start();
        scanning = s;
        ThreadPool.QueueUserWorkItem(_ => {
            try { s.Run(path, ct); } catch (Exception e) { App.Log(e); }
            Ui(() => {
                tm.Stop(); tm.Dispose();
                if (scanning != s) return;
                scanning = null;
                Progress = -1;
                if (ct.IsCancellationRequested && s.Root.Kids.Count == 0) { page = 0; Status = "Analisi interrotta"; UpdateUi(); return; }
                scan = s; page = 2; tab = 0;
                Status = (ct.IsCancellationRequested ? "Analisi interrotta (risultati parziali): " : "") + Fmt.Size(s.Root.Size) + " in " + s.FilesSeen.ToString("N0") + " file · " + sw.Elapsed.TotalSeconds.ToString("0") + " s" +
                    (s.Denied > 0 ? " · " + s.Denied + " cartelle non leggibili" + (Elevated ? "" : " (prova come amministratore)") : "");
                Navigate(s.Root);
            });
        });
    }
    Scanner scanning;

    void Navigate(Node n) {
        if (n == null || !n.IsDir) return;
        cur = n;
        if (tab != 0) tab = 0;
        Fill();
        map.Show(n);
        UpdateUi();
    }

    void SetTab(int t) { tab = t; Fill(); UpdateUi(); }

    void Fill() {
        list.Reset();
        if (scan == null) return;
        if (tab == 0 && cur != null) {
            list.Headers = new[] { "DIMENSIONE", "FILE" }; list.ColW = new[] { 100, 90 }; list.StatusW = 0;
            long max = cur.Kids.Count > 0 ? Math.Max(1, cur.Kids.Max(k => k.Size)) : 1;
            foreach (var k in cur.Kids) {
                double pct = cur.Size > 0 ? k.Size * 100.0 / cur.Size : 0;
                list.Items.Add(new ListItem { Tag = k, Title = k.Name, Glyph = k.IsDir ? "" : k.IsOther ? "" : "", Accent = Treemap.ColorOf(k),
                    Bar = (float)(k.Size / (double)max), Sub = pct.ToString(pct < 10 ? "0.0" : "0") + "%" + (k.Denied ? " · non leggibile" : ""),
                    Cols = new[] { Fmt.Size(k.Size), k.IsDir || k.IsOther ? k.Files.ToString("N0") : "" } });
            }
            list.EmptyTitle = "Cartella vuota"; list.EmptyText = cur.Denied ? "Windows non permette di leggerla: prova come amministratore." : "";
        } else if (tab == 1) {
            list.Headers = new[] { "DIMENSIONE", "MODIFICATO" }; list.ColW = new[] { 100, 120 }; list.StatusW = 0;
            foreach (var f in scan.Biggest.Take(500))
                list.Items.Add(new ListItem { Tag = f, Title = f.Name, Sub = Path.GetDirectoryName(f.Path), Glyph = "", Accent = Treemap.ColorOf(f), Cols = new[] { Fmt.Size(f.Size), f.Modified.ToString("dd/MM/yyyy") } });
            list.EmptyTitle = "Nessun file";
        } else {
            list.Headers = new[] { "DIMENSIONE", "FILE" }; list.ColW = new[] { 100, 100 }; list.StatusW = 0;
            var ex = scan.Ext.Values.Where(x => x.Size > 0).OrderByDescending(x => x.Size).Take(300).ToList();
            long max = ex.Count > 0 ? Math.Max(1, ex[0].Size) : 1;
            foreach (var e in ex) {
                double pct = scan.Root.Size > 0 ? e.Size * 100.0 / scan.Root.Size : 0;
                list.Items.Add(new ListItem { Title = e.Ext, Glyph = "", Accent = Treemap.ColorOf(new Node { Name = "x" + e.Ext }), Bar = (float)(e.Size / (double)max),
                    Sub = pct.ToString(pct < 10 ? "0.0" : "0") + "% · " + TypeName(e.Ext), Cols = new[] { Fmt.Size(e.Size), e.Count.ToString("N0") } });
            }
            list.EmptyTitle = "Nessun file";
        }
        list.Refresh_();
    }

    static string TypeName(string ext) {
        switch (ext) {
            case ".jpg": case ".jpeg": case ".png": case ".heic": case ".gif": case ".bmp": case ".raw": case ".cr2": case ".nef": case ".webp": return "foto e immagini";
            case ".mp4": case ".mkv": case ".avi": case ".mov": case ".wmv": case ".m4v": case ".ts": return "video";
            case ".mp3": case ".flac": case ".wav": case ".m4a": case ".aac": case ".ogg": return "musica e audio";
            case ".pdf": case ".doc": case ".docx": case ".xls": case ".xlsx": case ".ppt": case ".pptx": case ".odt": case ".txt": return "documenti";
            case ".zip": case ".rar": case ".7z": case ".tar": case ".gz": return "archivi compressi";
            case ".iso": case ".img": case ".vhd": case ".vhdx": case ".vmdk": return "immagini disco e macchine virtuali";
            case ".exe": case ".msi": case ".dll": case ".sys": return "programmi e componenti";
            case ".pst": case ".ost": return "posta di Outlook";
            case ".tmp": case ".log": case ".etl": case ".dmp": return "temporanei, registri e dump";
            case ".cab": case ".esd": case ".wim": case ".msp": return "aggiornamenti e installazione di Windows";
        }
        return "file " + ext.TrimStart('.').ToUpperInvariant();
    }

    // ---------- azioni ----------
    void NodeMenu(Node n, Control c, Point p) {
        if (n == null) return;
        var m = DarkMenu.New();
        if (n.IsDir) DarkMenu.Add(m, "Apri qui dentro", () => Navigate(n));
        DarkMenu.Add(m, "Mostra in Esplora risorse", () => Proc.Explore(n.Path, !n.IsDir && !n.IsOther));
        DarkMenu.Add(m, "Copia il percorso", () => { try { Clipboard.SetText(n.Path); Status = "Percorso copiato"; } catch { } });
        DarkMenu.Sep(m);
        DarkMenu.Add(m, "Elimina (nel Cestino)…", () => Delete(n), !n.IsOther && n != scan.Root && !Protected(n.Path));
        m.Show(c, p);
    }

    static bool Protected(string p) {
        var win = Environment.GetFolderPath(Environment.SpecialFolder.Windows).TrimEnd('\\');
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles).TrimEnd('\\');
        var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86).TrimEnd('\\');
        var users = Path.GetDirectoryName(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd('\\'));
        var prof = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd('\\');
        var pd = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData).TrimEnd('\\');
        p = p.TrimEnd('\\');
        if (p.Length <= 3) return true;
        foreach (var x in new[] { win, pf, pf86, users, prof, pd }) if (!string.IsNullOrEmpty(x) && string.Equals(p, x, StringComparison.OrdinalIgnoreCase)) return true;
        if (p.StartsWith(win + "\\", StringComparison.OrdinalIgnoreCase)) return true;     // dentro Windows: mai a mano
        var name = Path.GetFileName(p).ToLowerInvariant();
        return name == "pagefile.sys" || name == "hiberfil.sys" || name == "swapfile.sys" || name == "system volume information" || name == "$recycle.bin";
    }

    void Delete(Node n) {
        if (n == null || n.IsOther || scan == null || n == scan.Root) return;
        if (Protected(n.Path)) { MessageBox.Show("Questo elemento fa parte di Windows o dei programmi: non si elimina da qui.\n\nPer liberare spazio di sistema usa la pulizia di MultiTool.", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        bool net = n.Path.StartsWith(@"\\");
        var msg = (n.IsDir ? "Eliminare la cartella \"" + n.Name + "\" con tutto il contenuto (" + Fmt.Size(n.Size) + ")?" : "Eliminare \"" + n.Name + "\" (" + Fmt.Size(n.Size) + ")?") +
            (net ? "\n\nÈ su una cartella di rete: verrà eliminato DEFINITIVAMENTE, senza Cestino." : "\n\nVa nel Cestino: puoi recuperarlo finché non lo svuoti.");
        if (MessageBox.Show(msg, App.Name, MessageBoxButtons.YesNo, net ? MessageBoxIcon.Warning : MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        try {
            var opt = Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin;
            if (n.IsDir) Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(n.Path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, opt);
            else Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(n.Path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, opt);
            scan.Remove(n);
            Status = n.Name + " eliminato · " + Fmt.Size(n.Size) + " liberati";
            if (cur == n || IsUnder(cur, n)) cur = n.Parent;
            Fill(); map.Show(cur); UpdateUi();
        } catch (OperationCanceledException) { }
        catch (Exception e) { App.Log(e); MessageBox.Show("Non riesco a eliminarlo:\n" + e.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }
    static bool IsUnder(Node x, Node anc) { for (var p = x; p != null; p = p.Parent) if (p == anc) return true; return false; }

    void PickFolder() {
        using (var d = new FolderBrowserDialog { Description = "Cartella da analizzare", ShowNewFolderButton = false }) {
            if (d.ShowDialog(this) == DialogResult.OK) Start(d.SelectedPath);
        }
    }
    void RunAsAdmin() {
        var path = scan != null ? scan.Root.Path : "";
        try {
            Process.Start(new ProcessStartInfo(Application.ExecutablePath, path.Length > 0 ? "--cartella \"" + path.TrimEnd('\\') + (path.EndsWith(":\\") ? "\\\\" : "") + "\"" : "") { UseShellExecute = true, Verb = "runas" });
            Close();
        } catch (System.ComponentModel.Win32Exception) { }
        catch (Exception e) { App.Log(e); }
    }

    // ---------- disegno ----------
    void PaintContent(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        int W = content.Width, H = content.Height;
        if (page == 0) {
            using (var f = Th.F(20f, FontStyle.Bold)) Th.Text_(g, "Cosa analizzo?", f, Th.Text, new RectangleF(M, 26, W - 2 * M, 40));
            using (var f = Th.F(10f)) Th.Text_(g, "Scegli un disco o una cartella: vedrai cosa occupa più spazio, cartella per cartella.", f, Th.Dim, new RectangleF(M, 64, W - 2 * M - 400, 24));
            driveRects.Clear();
            float cw = 300, ch = 132, gap = 18, y = 110;
            int cols = Math.Max(1, (int)((W - 2 * M + gap) / (cw + gap)));
            cw = (W - 2 * M - gap * (cols - 1)) / cols;
            for (int i = 0; i < drives.Count; i++) {
                var d = drives[i];
                var r = new RectangleF(M + (i % cols) * (cw + gap), y + (i / cols) * (ch + gap), cw, ch);
                driveRects.Add(r);
                using (var p = Th.Round(r, 18)) {
                    using (var b = new SolidBrush(driveHover == i ? Th.Surface2 : Th.Surface)) g.FillPath(b, p);
                    using (var pen = new Pen(driveHover == i ? Th.C1 : Th.Border)) g.DrawPath(pen, p);
                }
                long tot = 0, free = 0; string label = "";
                try { tot = d.TotalSize; free = d.AvailableFreeSpace; label = d.VolumeLabel; } catch { }
                var tile = new RectangleF(r.X + 18, r.Y + 18, 42, 42);
                using (var p = Th.Round(tile, 12)) using (var b = Th.Grad(tile, Th.C1, Th.C2)) g.FillPath(b, p);
                using (var f = Th.G(17f)) if (Th.HasGlyphs) Th.Text_(g, d.DriveType == DriveType.Network ? "" : d.DriveType == DriveType.Removable ? "" : "", f, Color.White, tile, StringAlignment.Center);
                using (var f = Th.F(12f, FontStyle.Bold)) Th.Text_(g, d.Name.TrimEnd('\\') + "  " + (string.IsNullOrEmpty(label) ? (d.DriveType == DriveType.Removable ? "Disco rimovibile" : "Disco locale") : label), f, Th.Text, new RectangleF(r.X + 72, r.Y + 18, r.Width - 90, 24));
                using (var f = Th.F(9f)) Th.Text_(g, Fmt.Size(free) + " liberi di " + Fmt.Size(tot), f, Th.Dim, new RectangleF(r.X + 72, r.Y + 42, r.Width - 90, 20));
                var br = new RectangleF(r.X + 18, r.Bottom - 40, r.Width - 36, 8);
                double used = tot > 0 ? 1 - free / (double)tot : 0;
                using (var p = Th.Round(br, 4)) using (var b = new SolidBrush(Th.Surface3)) g.FillPath(b, p);
                var ur = new RectangleF(br.X, br.Y, (float)(br.Width * used), br.Height);
                if (ur.Width > 4) using (var p = Th.Round(ur, 4)) using (var b = used > 0.9 ? (Brush)new SolidBrush(Th.Red) : Th.Grad(ur, Th.C1, Th.C2)) g.FillPath(b, p);
                using (var f = Th.F(8.5f)) Th.Text_(g, (used * 100).ToString("0") + "% occupato" + (used > 0.9 ? " · quasi pieno" : ""), f, used > 0.9 ? Th.Red : Th.Faint, new RectangleF(br.X, br.Bottom + 4, br.Width, 18));
            }
            return;
        }
        if (page == 1) {
            var s = scanning;
            float cx = W / 2f, cy = H / 2f - 40;
            double t = Environment.TickCount / 1000.0;
            using (var pen = new Pen(Th.Surface3, 8)) g.DrawEllipse(pen, cx - 44, cy - 44, 88, 88);
            using (var pen = new Pen(new LinearGradientBrush(new RectangleF(cx - 44, cy - 44, 88, 88), Th.C1, Th.C2, 45f), 8) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                g.DrawArc(pen, cx - 44, cy - 44, 88, 88, (float)(t * 240 % 360), 100);
            using (var f = Th.F(14f, FontStyle.Bold)) Th.Text_(g, "Analisi in corso…", f, Th.Text, new RectangleF(0, cy + 58, W, 28), StringAlignment.Center);
            if (s != null) using (var f = Th.F(9.5f)) Th.Text_(g, s.FilesSeen.ToString("N0") + " file letti", f, Th.Dim, new RectangleF(0, cy + 86, W, 22), StringAlignment.Center);
            return;
        }
        // risultati: percorso cliccabile
        crumbs.Clear();
        if (cur != null && tab == 0) {
            var chain = new List<Node>(); for (var n = cur; n != null; n = n.Parent) chain.Insert(0, n);
            float x = M;
            using (var f = Th.F(12f, FontStyle.Bold)) using (var fs = Th.F(12f))
                for (int i = 0; i < chain.Count; i++) {
                    var name = i == 0 ? chain[i].Path.TrimEnd('\\') : chain[i].Name;
                    bool last = i == chain.Count - 1;
                    var w = g.MeasureString(name, last ? f : fs).Width;
                    if (x + w > bNew.Left - 20 && !last) { name = "…"; w = g.MeasureString(name, fs).Width; }
                    var r = new RectangleF(x, 20, w + 2, 38);
                    Th.Text_(g, name, last ? f : fs, last ? Th.Text : Th.Dim, r);
                    if (!last) crumbs.Add(new KeyValuePair<Node, RectangleF>(chain[i], r));
                    x += w + 4;
                    if (!last) { using (var fg = Th.F(12f)) Th.Text_(g, "›", fg, Th.Faint, new RectangleF(x, 20, 16, 38)); x += 18; }
                    if (x > bNew.Left - 20) break;
                }
            using (var f = Th.F(9f)) Th.Text_(g, Fmt.Size(cur.Size) + " · " + cur.Files.ToString("N0") + " file", f, Th.Dim, new RectangleF(tabs[2].Right + 20, 72, Math.Max(0, bUp.Left - tabs[2].Right - 30), 36));
        } else if (scan != null) {
            using (var f = Th.F(12f, FontStyle.Bold)) Th.Text_(g, scan.Root.Path.TrimEnd('\\'), f, Th.Text, new RectangleF(M, 20, bNew.Left - M - 20, 38));
            using (var f = Th.F(9f)) Th.Text_(g, tab == 1 ? "I " + Math.Min(500, scan.Biggest.Count) + " file più grandi" : "Spazio per tipo di file", f, Th.Dim, new RectangleF(tabs[2].Right + 20, 72, 400, 36));
        }
    }
}
