using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class MainForm : AppForm {
    readonly ItemList list = new ItemList();
    readonly Btn bRun = new Btn { Kind = BtnKind.OnColor, Text = "AVVIA BACKUP", Glyph = "" };
    readonly Btn bDest = new Btn { Kind = BtnKind.OnColor, Text = "Destinazione…", Glyph = "" };
    readonly Btn bOpen = new Btn { Kind = BtnKind.OnColor, Text = "Apri backup", Glyph = "" };
    readonly Btn bAdd = new Btn { Text = "Aggiungi cartella", Glyph = "" };
    readonly Btn bDel = new Btn { Text = "Togli", Glyph = "" };
    readonly Btn bRestore = new Btn { Text = "Ripristina…", Glyph = "" };
    readonly Btn bAuto = new Btn { Text = "Attiva" }, bFreq = new Btn { Text = "Ogni giorno" }, bTime = new Btn { Text = "13:00" };
    List<BkFolder> folders = new List<BkFolder>();
    CancellationTokenSource cts, sizeCts;
    bool busy;
    long freeBytes = -1, totalBytes = -1;
    List<Tuple<DateTime, bool, string>> hist = new List<Tuple<DateTime, bool, string>>();
    const int M = 28, RightW = 320;
    RectangleF hero, side, head;

    public MainForm() : base("Erodyne Backup", "Copie di sicurezza delle tue cartelle") {
        MinimumSize = new Size(Math.Min(980, Screen.PrimaryScreen.WorkingArea.Width), MinimumSize.Height);
        content.Controls.Add(list);
        foreach (var b in new[] { bRun, bDest, bOpen, bAdd, bDel, bRestore, bAuto, bFreq, bTime }) content.Controls.Add(b);
        bRun.Font = Th.F(10f, FontStyle.Bold);
        list.Headers = new[] { "DIMENSIONE", "NEL BACKUP" };
        list.ColW = new[] { 96, 104 };
        list.StatusW = 180;
        list.EmptyTitle = "Nessuna cartella";
        list.CheckChanged += () => { Engine.SaveSelection(folders.Where((f, i) => list.Items[i].Checked).Select(f => f.Id)); UpdateUi(); };
        list.SelectionChanged += UpdateUi;
        list.ItemActivated += it => { var f = it.Tag as BkFolder; if (f != null && Directory.Exists(f.Path)) Proc.Explore(f.Path); };
        list.ItemMenu += (it, p) => {
            var f = it.Tag as BkFolder; if (f == null) return;
            var m = DarkMenu.New();
            DarkMenu.Add(m, "Apri la cartella", () => Proc.Explore(f.Path), Directory.Exists(f.Path));
            var t = Engine.Target(f);
            DarkMenu.Add(m, "Apri la copia nel backup", () => Proc.Explore(t), t != null && Directory.Exists(t));
            DarkMenu.Add(m, "Ripristina dal backup…", Restore, !busy && t != null && Directory.Exists(t) && f.Parts == null);
            if (f.Custom) { DarkMenu.Sep(m); DarkMenu.Add(m, "Togli dall'elenco", RemoveCustom, !busy); }
            m.Show(list, p);
        };
        bRun.Click += (s, e) => { if (busy) { if (cts != null) cts.Cancel(); } else RunBackup(); };
        bDest.Click += (s, e) => ChooseDest();
        bOpen.Click += (s, e) => { var r = Engine.Root; if (r != null && Directory.Exists(r)) Proc.Explore(r); else if (Engine.DestReady) Proc.Explore(Engine.Dest); else Status = "La destinazione del backup non è disponibile"; };
        bAdd.Click += (s, e) => AddCustom();
        bDel.Click += (s, e) => RemoveCustom();
        bRestore.Click += (s, e) => Restore();
        bAuto.Click += (s, e) => ToggleAuto();
        bFreq.Click += (s, e) => FreqMenu();
        bTime.Click += (s, e) => TimeMenu();
        content.Paint += PaintContent;
        content.Resize += (s, e) => Layout_();
        KeyDown += (s, e) => { if (e.KeyCode == Keys.F5 && !busy) { Reload(); e.Handled = true; } };
        FormClosing += (s, e) => {
            if (busy && MessageBox.Show("Il backup è in corso. Interromperlo e chiudere?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) e.Cancel = true;
            else { if (cts != null) cts.Cancel(); if (sizeCts != null) sizeCts.Cancel(); }
        };
        Shown += (s, e) => { Reload(); list.Focus(); };
        Prova.Steps.Add(new Prova.Step { Name = "avvio", Ready = () => !sizing });
        Prova.Steps.Add(new Prova.Step { Name = "backup", Do = RunBackup, Ready = () => !busy && !sizing, MaxSec = 300 });
        Prova.Steps.Add(new Prova.Step { Name = "menu-orari", Do = TimeMenu });
    }

    bool sizing;
    void Reload() {
        folders = Engine.Folders();
        list.Reset();
        foreach (var f in folders) {
            list.Items.Add(new ListItem {
                Tag = f, Title = f.Name, Sub = f.Parts != null ? "Edge, Chrome e Firefox" : f.Path, Checked = f.Def,
                Glyph = f.Custom ? "" : f.Id == "fav" ? "" : f.Id == "pic" ? "" : f.Id == "vid" ? "" : f.Id == "mus" ? "" : f.Id == "dl" ? "" : f.Id == "desk" ? "" : "",
                Cols = new[] { "…", "" }
            });
        }
        list.Refresh_();
        hist = Engine.History(6);
        ReadSpace();
        UpdateUi();
        if (sizeCts != null) sizeCts.Cancel();
        sizeCts = new CancellationTokenSource();
        var ct = sizeCts.Token; var items = list.Items.ToList();
        sizing = true;
        ThreadPool.QueueUserWorkItem(_ => {
            foreach (var it in items) {
                if (ct.IsCancellationRequested) break;
                var f = (BkFolder)it.Tag;
                long sz = Engine.Size(f, ct);
                var t = Engine.DestReady ? Engine.Target(f) : null;
                long bs = t != null && Directory.Exists(t) ? Engine.Size(t, ct) : -1;
                Ui(() => { it.Cols = new[] { Fmt.Size(sz), bs >= 0 ? Fmt.Size(bs) : "—" }; list.Invalidate(); UpdateSummary(); });
            }
            Ui(() => { sizing = false; UpdateSummary(); });
        });
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetDiskFreeSpaceEx(string dir, out ulong freeForUser, out ulong total, out ulong free);
    void ReadSpace() {
        freeBytes = totalBytes = -1;
        if (!Engine.DestReady) return;
        ulong a, t, f;
        try { if (GetDiskFreeSpaceEx(Engine.Dest, out a, out t, out f)) { freeBytes = (long)a; totalBytes = (long)t; } } catch { }
    }

    long SelectedSize() {
        long s = 0;
        foreach (var it in list.Items) if (it.Checked && it.Cols.Length > 0) s += ParseSize(it.Cols[0]);
        return s;
    }
    static long ParseSize(string s) {
        if (string.IsNullOrEmpty(s)) return 0;
        var p = s.Split(' '); double v;
        if (p.Length != 2 || !double.TryParse(p[0], out v)) return 0;
        int i = Array.IndexOf(new[] { "B", "KB", "MB", "GB", "TB" }, p[1]);
        return i < 0 ? 0 : (long)(v * Math.Pow(1024, i));
    }
    string summary = "";
    void UpdateSummary() {
        int n = list.Items.Count(x => x.Checked);
        summary = n + " di " + list.Items.Count + " cartelle scelte" + (sizing ? "" : " · " + Fmt.Size(SelectedSize()));
        content.Invalidate(Rectangle.Round(head));
    }

    void UpdateUi() {
        bRun.Text = busy ? "INTERROMPI" : "AVVIA BACKUP";
        bRun.Glyph = busy ? "" : "";
        bRun.Enabled = busy || list.Items.Any(x => x.Checked);
        foreach (var b in new[] { bDest, bAdd, bAuto, bFreq, bTime }) b.Enabled = !busy;
        var cur = list.Current == null ? null : list.Current.Tag as BkFolder;
        bDel.Enabled = !busy && cur != null && cur.Custom;
        var t = cur == null ? null : Engine.Target(cur);
        bRestore.Enabled = !busy && cur != null && cur.Parts == null && t != null && Directory.Exists(t);
        bOpen.Enabled = Engine.DestReady;
        bAuto.Text = Schedule.On ? "Disattiva" : "Attiva";
        bAuto.Kind = Schedule.On ? BtnKind.Secondary : BtnKind.Primary;
        bAuto.C1 = Th.C1; bAuto.C2 = Th.C2;
        bFreq.Text = Schedule.Weekly ? "Ogni " + Schedule.DayName(Schedule.Day) : "Ogni giorno";
        bTime.Text = "alle " + new DateTime(Schedule.Time.Ticks).ToString("HH:mm");
        bFreq.Visible = bTime.Visible = Schedule.On;
        UpdateSummary();
        Layout_();
        content.Invalidate();
    }

    void Layout_() {
        int W = content.Width, H = content.Height;
        if (W < 50) return;
        hero = new RectangleF(M, 22, W - 2 * M, 170);
        int x = (int)hero.X + 30, y = (int)hero.Bottom - 62;
        bRun.SetBounds(x, y, Math.Max(190, bRun.Measure()), 42); x = bRun.Right + 10;
        bDest.SetBounds(x, y + 2, bDest.Measure(), 38); x = bDest.Right + 10;
        bOpen.SetBounds(x, y + 2, bOpen.Measure(), 38);
        side = new RectangleF(W - M - RightW, hero.Bottom + 20, RightW, H - hero.Bottom - 20 - 20);
        head = new RectangleF(M, hero.Bottom + 20, side.X - 20 - M, 44);
        int bx = (int)head.Right;
        foreach (var b in new[] { bRestore, bDel, bAdd }) { int w = b.Measure(); bx -= w; b.SetBounds(bx, (int)head.Y + 2, w, 38); bx -= 8; }
        list.SetBounds(M - 8, (int)head.Bottom + 6, (int)(head.Width + 8), (int)(H - head.Bottom - 6 - 16));
        int sy = (int)side.Y + 92;
        bAuto.SetBounds((int)side.X + 20, sy, 110, 38);
        bFreq.SetBounds(bAuto.Right + 8, sy, (int)side.Right - 20 - bAuto.Right - 8, 38);
        bTime.SetBounds((int)side.X + 20, sy + 46, (int)side.Width - 40, 38);
    }

    void PaintContent(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        // banner con lo stato
        using (var p = Th.Round(hero, 20)) {
            using (var b = Th.Grad(hero, Th.C1, Th.C2)) g.FillPath(b, p);
            var clip = g.Clip; g.SetClip(p, CombineMode.Intersect);
            using (var b = new SolidBrush(Color.FromArgb(28, 255, 255, 255))) g.FillEllipse(b, hero.Right - hero.Height * 1.2f, hero.Y - hero.Height * 0.6f, hero.Height * 1.4f, hero.Height * 1.4f);
            var lr = new RectangleF(hero.X, hero.Y, hero.Width * 0.8f, hero.Height);
            using (var b = new LinearGradientBrush(new RectangleF(lr.X - 1, lr.Y, lr.Width + 2, lr.Height), Color.FromArgb(140, 11, 13, 18), Color.FromArgb(0, 11, 13, 18), 0f)) g.FillRectangle(b, lr);
            g.Clip = clip;
        }
        var last = Engine.LastOk;
        int days = last.HasValue ? (int)(DateTime.Now - last.Value).TotalDays : -1;
        string big = busy ? "Backup in corso…" : !last.HasValue ? "Nessun backup ancora" : "Ultimo backup " + Fmt.Ago(last.Value);
        using (var f = Th.F(8.5f, FontStyle.Bold)) Th.Text_(g, days >= 7 ? "ATTENZIONE: BACKUP VECCHIO" : "BACKUP", f, Color.FromArgb(215, 255, 255, 255), new RectangleF(hero.X + 32, hero.Y + 20, 400, 20));
        using (var f = Th.F(21f, FontStyle.Bold)) Th.Text_(g, big, f, Color.White, new RectangleF(hero.X + 30, hero.Y + 40, hero.Width - 60, 40));
        string dl;
        if (Engine.Dest == null) dl = "Scegli dove salvare il backup: un disco esterno, una chiavetta o una cartella di rete.";
        else if (!Engine.DestReady) dl = "Destinazione non collegata: " + Engine.Dest + " · collega il disco per fare il backup.";
        else dl = "Su " + Engine.Dest + (freeBytes >= 0 ? " · " + Fmt.Size(freeBytes) + " liberi di " + Fmt.Size(totalBytes) : "") + " · copia solo i file nuovi o modificati, non cancella nulla";
        using (var f = Th.F(10f)) Th.Text_(g, dl, f, Color.FromArgb(230, 255, 255, 255), new RectangleF(hero.X + 32, hero.Y + 80, hero.Width - 64, 24));

        // intestazione dell'elenco
        using (var f = Th.F(13f, FontStyle.Bold)) Th.Text_(g, "Cartelle", f, Th.Text, new RectangleF(head.X, head.Y, 200, 26));
        using (var f = Th.F(8.5f)) Th.Text_(g, summary, f, Th.Dim, new RectangleF(head.X, head.Y + 24, Math.Max(0, bAdd.Left - head.X - 10), 18));
        if (freeBytes >= 0 && !sizing && SelectedSize() > freeBytes * 1.05) {
            using (var f = Th.F(8.5f, FontStyle.Bold)) Th.Text_(g, "Attenzione: le cartelle scelte potrebbero non entrare nella destinazione", f, Th.Amber, new RectangleF(head.X + 210, head.Y, Math.Max(0, bAdd.Left - head.X - 220), 26));
        }

        // pannello a destra
        using (var p = Th.Round(side, 18)) {
            using (var b = new SolidBrush(Th.Surface)) g.FillPath(b, p);
            using (var pen = new Pen(Th.Border)) g.DrawPath(pen, p);
        }
        using (var f = Th.F(12f, FontStyle.Bold)) Th.Text_(g, "Backup automatico", f, Th.Text, new RectangleF(side.X + 20, side.Y + 16, side.Width - 40, 26));
        using (var f = Th.F(9f)) Th.Text_(g, Schedule.On ? Schedule.Describe() + ", e al primo accesso se è stato saltato." : "Disattivato: attivalo per non doverci pensare.", f, Th.Dim, new RectangleF(side.X + 20, side.Y + 44, side.Width - 40, 40), StringAlignment.Near, StringAlignment.Near, true);
        float hy = side.Y + (Schedule.On ? 196 : 150);
        using (var f = Th.F(12f, FontStyle.Bold)) Th.Text_(g, "Ultime copie", f, Th.Text, new RectangleF(side.X + 20, hy, side.Width - 40, 26));
        hy += 34;
        if (hist.Count == 0) using (var f = Th.F(9f)) Th.Text_(g, "Ancora nessuna.", f, Th.Faint, new RectangleF(side.X + 20, hy, side.Width - 40, 20));
        using (var f1 = Th.F(9f, FontStyle.Bold)) using (var f2 = Th.F(8.5f))
            foreach (var h in hist) {
                if (hy + 40 > side.Bottom - 10) break;
                using (var b = new SolidBrush(h.Item2 ? Th.Green : Th.Amber)) g.FillEllipse(b, side.X + 22, hy + 6, 8, 8);
                Th.Text_(g, Fmt.Ago(h.Item1), f1, Th.Text, new RectangleF(side.X + 38, hy, side.Width - 58, 20));
                Th.Text_(g, h.Item3, f2, Th.Dim, new RectangleF(side.X + 38, hy + 18, side.Width - 58, 18));
                hy += 44;
            }
    }

    // ---------- azioni ----------
    void RunBackup() {
        if (!Engine.DestReady) {
            if (Engine.Dest != null && MessageBox.Show("La destinazione " + Engine.Dest + " non è disponibile.\n\nCollega il disco e premi Riprova, oppure Annulla per sceglierne un'altra.", App.Name, MessageBoxButtons.RetryCancel, MessageBoxIcon.Warning) == DialogResult.Retry && Engine.DestReady) { }
            else if (!ChooseDest()) return;
            if (!Engine.DestReady) return;
        }
        var items = list.Items.Where(x => x.Checked).ToList();
        if (items.Count == 0) return;
        bool mine;
        var mx = new Mutex(true, Program.RunMutex, out mine);
        if (!mine) { mx.Dispose(); MessageBox.Show("È già in corso un backup automatico. Riprova tra poco.", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        busy = true; cts = new CancellationTokenSource();
        foreach (var it in items) { it.Status = "In attesa"; it.StatusColor = Th.Dim; }
        UpdateUi(); Progress = 0; Status = "Backup in corso…";
        var ct = cts.Token; var fl = items.Select(x => (BkFolder)x.Tag).ToList();
        ThreadPool.QueueUserWorkItem(_ => {
            string sum;
            try {
                Engine.RunAll(fl, ct, (i, f, r) => Ui(() => {
                    var it = items[i];
                    if (r == null) { it.Status = "Copio…"; it.StatusColor = Th.C1; Status = "Copio " + f.Name + " (" + (i + 1) + " di " + fl.Count + ")…"; Progress = i / (double)fl.Count; }
                    else { it.Status = Engine.Describe(r); it.StatusColor = Engine.Ok(r) ? Th.Green : r.Code == -2 ? Th.Dim : Th.Red; Progress = (i + 1) / (double)fl.Count; }
                    list.Invalidate();
                }), out sum);
            } catch (Exception e) { App.Log(e); sum = "Backup non riuscito: " + e.Message; }
            Ui(() => {
                try { mx.ReleaseMutex(); } catch { } mx.Dispose();
                busy = false; Progress = -1; Status = sum;
                Reload();
                foreach (var it in list.Items) { var src = items.FirstOrDefault(x => ((BkFolder)x.Tag).Id == ((BkFolder)it.Tag).Id); if (src != null) { it.Status = src.Status; it.StatusColor = src.StatusColor; } }
                list.Invalidate();
            });
        });
    }

    bool ChooseDest() {
        using (var d = new FolderBrowserDialog { Description = "Dove salvare il backup? Scegli un disco esterno, una chiavetta o una cartella di rete.", ShowNewFolderButton = true }) {
            if (Engine.Dest != null && Directory.Exists(Engine.Dest)) d.SelectedPath = Engine.Dest;
            if (d.ShowDialog(this) != DialogResult.OK) return false;
            var p = d.SelectedPath;
            var sys = Path.GetPathRoot(Environment.SystemDirectory);
            if (p.StartsWith(sys, StringComparison.OrdinalIgnoreCase) &&
                MessageBox.Show("Hai scelto lo stesso disco di Windows (" + sys + ").\n\nSe il disco si guasta o il PC viene rubato perdi anche il backup. Meglio un disco esterno o una cartella di rete.\n\nUsarlo comunque?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return false;
            foreach (var f in folders) if (f.Parts == null && !string.IsNullOrEmpty(f.Path) && (p + "\\").StartsWith(f.Path.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) {
                MessageBox.Show("La destinazione è dentro la cartella " + f.Name + ", che fa parte del backup: scegline un'altra.", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); return false;
            }
            Store.Set("destinazione", p);
            if (Schedule.On) Schedule.Apply();
            Reload();
            Status = "Il backup andrà in " + Engine.Root;
            return true;
        }
    }

    void AddCustom() {
        using (var d = new FolderBrowserDialog { Description = "Cartella da aggiungere al backup", ShowNewFolderButton = false }) {
            if (d.ShowDialog(this) != DialogResult.OK) return;
            var p = d.SelectedPath.TrimEnd('\\');
            if (p.Length <= 3) { MessageBox.Show("Scegli una cartella, non un disco intero.", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
            if (Engine.Dest != null && ((Engine.Dest + "\\").StartsWith(p + "\\", StringComparison.OrdinalIgnoreCase) || (p + "\\").StartsWith(Engine.Dest.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))) {
                MessageBox.Show("Questa cartella contiene la destinazione del backup (o ci sta dentro): non si può aggiungere.", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); return;
            }
            if (folders.Any(f => f.Parts == null && string.Equals(f.Path.TrimEnd('\\'), p, StringComparison.OrdinalIgnoreCase))) { Status = "La cartella è già nell'elenco"; return; }
            Engine.SaveSelection(folders.Where((f, i) => list.Items[i].Checked).Select(f => f.Id));
            Engine.AddCustom(p);
            Reload();
        }
    }
    void RemoveCustom() {
        var f = list.Current == null ? null : list.Current.Tag as BkFolder;
        if (f == null || !f.Custom) return;
        Engine.RemoveCustom(f.Path);
        Reload();
        Status = f.Name + " tolta dall'elenco (la copia già fatta resta nel backup)";
    }

    void Restore() {
        var f = list.Current == null ? null : list.Current.Tag as BkFolder;
        if (f == null || busy) return;
        if (MessageBox.Show("Riportare in " + f.Path + " i file salvati nel backup?\n\nVengono ricopiati i file mancanti o più vecchi; quelli che hai modificato dopo il backup non vengono toccati.", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        var it = list.Current;
        busy = true; cts = new CancellationTokenSource(); UpdateUi();
        it.Status = "Ripristino…"; it.StatusColor = Th.C1; Progress = 2; Status = "Ripristino di " + f.Name + "…";
        var ct = cts.Token;
        ThreadPool.QueueUserWorkItem(_ => {
            var r = Engine.Restore(f, ct);
            Engine.AddHistory(Engine.Ok(r), "Ripristino di " + f.Name + ": " + Engine.Describe(r));
            Ui(() => {
                busy = false; Progress = -1;
                it.Status = Engine.Ok(r) ? (r.Copied > 0 ? r.Copied + " file ripristinati" : "Niente da ripristinare") : Engine.Describe(r);
                it.StatusColor = Engine.Ok(r) ? Th.Green : Th.Red;
                Status = "Ripristino di " + f.Name + ": " + it.Status;
                hist = Engine.History(6); UpdateUi();
            });
        });
    }

    void ToggleAuto() {
        if (!Schedule.On && Engine.Dest == null && !ChooseDest()) return;
        Store.SetBool("automatico", !Schedule.On);
        var err = Schedule.Apply();
        if (err != null) { Store.SetBool("automatico", false); MessageBox.Show(err, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        Status = Schedule.On ? "Backup automatico: " + Schedule.Describe().ToLower() : "Backup automatico disattivato";
        UpdateUi();
    }
    void FreqMenu() {
        var m = DarkMenu.New();
        DarkMenu.Add(m, "Ogni giorno", () => { Store.Set("frequenza", "giorno"); Schedule.Apply(); UpdateUi(); }, true, !Schedule.Weekly);
        DarkMenu.Sep(m);
        foreach (var d in new[] { DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday, DayOfWeek.Thursday, DayOfWeek.Friday, DayOfWeek.Saturday, DayOfWeek.Sunday }) {
            var dd = d;
            DarkMenu.Add(m, "Ogni " + Schedule.DayName(d), () => { Store.Set("frequenza", "settimana"); Store.Set("giorno", ((int)dd).ToString()); Schedule.Apply(); UpdateUi(); }, true, Schedule.Weekly && Schedule.Day == d);
        }
        m.Show(bFreq, new Point(0, bFreq.Height));
    }
    void TimeMenu() {
        var m = DarkMenu.New();
        m.MaximumSize = new Size(300, 420);
        for (int h = 0; h < 24; h++) {
            var t = new TimeSpan(h, 0, 0);
            DarkMenu.Add(m, t.ToString(@"hh\:mm"), () => { Store.Set("ora", t.ToString(@"hh\:mm")); Schedule.Apply(); UpdateUi(); }, true, Schedule.Time == t);
        }
        m.Show(bTime, new Point(0, bTime.Height));
    }
}
