using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class MainForm : Form {
    readonly List<AppState> states = new List<AppState>();
    int page = -1; // -1 = Home, altrimenti indice del programma
    string status = Program.StartMessage ?? "Pronto";
    double percent = -1;
    string suiteUpdate, suitePage;
    bool queueRunning;
    int checking; // controlli online ancora in corso

    readonly Canvas title = new Canvas(), side = new Canvas(), content = new Canvas(), bar = new Canvas();
    // pulsanti della barra del titolo disegnati a linee (i caratteri —, ▢, ✕ cambiano aspetto da un font all'altro)
    readonly Btn bMin = new Btn { Kind = BtnKind.Caption, Icon = CapIcon.Min, Text = "Riduci a icona", TabStop = false },
                 bMax = new Btn { Kind = BtnKind.Caption, Icon = CapIcon.Max, Text = "Ingrandisci", TabStop = false },
                 bClose = new Btn { Kind = BtnKind.Caption, Icon = CapIcon.Close, Text = "Chiudi", TabStop = false };

    // Home
    readonly Btn hUpdateAll = new Btn { Kind = BtnKind.OnColor, Text = "Aggiorna tutto", Glyph = "" };
    readonly Btn hCheck = new Btn { Kind = BtnKind.OnColor, Text = "Controlla", Glyph = "" };
    readonly List<Btn> cardMain = new List<Btn>(), cardMore = new List<Btn>();
    // Pagina programma
    readonly Btn pMain = new Btn { Kind = BtnKind.Primary, Height = 46 };
    readonly Btn pFolder = new Btn { Text = "Apri cartella", Glyph = "" };
    readonly Btn pGit = new Btn { Text = "Pagina GitHub", Glyph = "" };
    readonly Btn pLocate = new Btn { Kind = BtnKind.Ghost, Text = "Individua…", Glyph = "" };
    readonly Btn pUninst = new Btn { Kind = BtnKind.Danger, Text = "Disinstalla", Glyph = "" };
    readonly RichTextBox notes = new RichTextBox();

    const int TitleH = 46, SideW = 252, BarH = 34;

    public MainForm() {
        Text = "Erodyne Suite";
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Th.Bg; ForeColor = Th.Text;
        // su schermi piccoli la finestra non deve uscire dall'area di lavoro
        var wa = Screen.PrimaryScreen.WorkingArea;
        MinimumSize = new Size(Math.Min(1000, wa.Width), Math.Min(640, wa.Height));
        Size = new Size(Math.Min(1180, wa.Width), Math.Min(760, wa.Height));
        StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;
        Padding = new Padding(1);
        try { Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        foreach (var a in Catalog.Apps) states.Add(new AppState { Def = a });

        title.Height = TitleH; title.Dock = DockStyle.Top; title.BackColor = Th.Side;
        side.Width = SideW; side.Dock = DockStyle.Left; side.BackColor = Th.Side;
        bar.Height = BarH; bar.Dock = DockStyle.Bottom; bar.BackColor = Th.Bg;
        content.Dock = DockStyle.Fill;
        Controls.Add(content); Controls.Add(bar); Controls.Add(side); Controls.Add(title);

        // barra del titolo
        title.Paint += PaintTitle;
        title.MouseDown += (s, e) => {
            if (e.Button != MouseButtons.Left) return;
            if (e.Clicks == 2) ToggleMax(); else DragWindow();
        };
        foreach (var b in new[] { bMin, bMax, bClose }) { b.Size = new Size(46, TitleH - 1); title.Controls.Add(b); }
        bMin.Click += (s, e) => WindowState = FormWindowState.Minimized;
        bMax.Click += (s, e) => ToggleMax();
        bClose.Click += (s, e) => Close();
        title.Resize += (s, e) => { bClose.Left = title.Width - 46; bMax.Left = bClose.Left - 46; bMin.Left = bMax.Left - 46; };

        side.Paint += PaintSide;
        side.MouseMove += (s, e) => { int h = SideHit(e.Location); side.Cursor = h != -99 ? Cursors.Hand : Cursors.Default; if (h != sideHover) { sideHover = h; side.Invalidate(); } };
        side.MouseLeave += (s, e) => { sideHover = -99; side.Invalidate(); };
        side.MouseClick += (s, e) => {
            int h = SideHit(e.Location);
            if (h == -2) RefreshAll(true);
            else if (h == -3 && suitePage != null) Manager.OpenUrl(suitePage);
            else if (h != -99) Go(h);
        };

        bar.Paint += PaintBar;
        content.Paint += PaintContent;
        content.Resize += (s, e) => Layout_();

        hUpdateAll.Click += (s, e) => UpdateAll();
        hCheck.Click += (s, e) => RefreshAll(true);
        content.Controls.Add(hUpdateAll); content.Controls.Add(hCheck);
        for (int i = 0; i < states.Count; i++) {
            int k = i;
            var m = new Btn { Kind = BtnKind.Primary, Height = 40, C1 = states[i].Def.C1, C2 = states[i].Def.C2 };
            var d = new Btn { Kind = BtnKind.Secondary, Height = 40, Text = "Dettagli" };
            m.Click += (s, e) => MainAction(states[k]);
            d.Click += (s, e) => Go(k);
            cardMain.Add(m); cardMore.Add(d);
            content.Controls.Add(m); content.Controls.Add(d);
        }

        pMain.Font = Th.F(11f, FontStyle.Bold);
        pMain.Click += (s, e) => MainAction(Cur);
        pFolder.Click += (s, e) => Manager.OpenFolder(Cur.InstallDir);
        pGit.Click += (s, e) => Manager.OpenUrl(Cur.ReleasePage ?? "https://github.com/" + Cur.Def.Repo + "/releases");
        pLocate.Click += (s, e) => Locate(Cur);
        pUninst.Click += (s, e) => UninstallApp(Cur);
        notes.BorderStyle = BorderStyle.None; notes.ReadOnly = true; notes.BackColor = Th.Surface; notes.ForeColor = Th.Dim;
        notes.Font = Th.F(9.5f); notes.ScrollBars = RichTextBoxScrollBars.Vertical; notes.DetectUrls = true;
        notes.LinkClicked += (s, e) => Manager.OpenUrl(e.LinkText);
        foreach (Control c in new Control[] { pMain, pFolder, pGit, pLocate, pUninst, notes }) content.Controls.Add(c);

        Activated += (s, e) => { if (!AnyBusy) { foreach (var st in states) Manager.DetectLocal(st); RefreshUi(); } };
        Shown += (s, e) => { RefreshAll(true); ThreadPool.QueueUserWorkItem(_ => Manager.CleanStaleDownloads()); };
        foreach (var st in states) Manager.DetectLocal(st);
        Go(-1);
    }

    AppState Cur { get { return page >= 0 ? states[page] : null; } }
    bool AnyBusy { get { return queueRunning || states.Any(x => x.Busy); } }

    // ---------- finestra senza bordi ----------
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    void DragWindow() { try { ReleaseCapture(); SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); } catch { } }
    void ToggleMax() { WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized; }

    protected override CreateParams CreateParams {
        get { var cp = base.CreateParams; cp.Style |= 0x10000 | 0x20000 | 0x40000; return cp; } // WS_MAXIMIZEBOX | WS_MINIMIZEBOX | WS_SIZEBOX
    }
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try { int v = 2; DwmSetWindowAttribute(Handle, 33, ref v, 4); } catch { } // angoli arrotondati su Windows 11
        try { int dark = 1; DwmSetWindowAttribute(Handle, 20, ref dark, 4); } catch { }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x83 && m.WParam != IntPtr.Zero) { // WM_NCCALCSIZE: nessun bordo di sistema
            if (WindowState == FormWindowState.Maximized) {
                // massimizzata, Windows sposta la finestra oltre lo schermo dello spessore del bordo: la riporta nell'area di lavoro
                var wa = Screen.FromHandle(Handle).WorkingArea;
                Marshal.WriteInt32(m.LParam, 0, wa.Left); Marshal.WriteInt32(m.LParam, 4, wa.Top);
                Marshal.WriteInt32(m.LParam, 8, wa.Right); Marshal.WriteInt32(m.LParam, 12, wa.Bottom);
            }
            m.Result = IntPtr.Zero; return;
        }
        if (m.Msg == 0x84) { int h = HitEdge(m.LParam); if (h != 0) { m.Result = (IntPtr)h; return; } }
        // senza bordo di sistema Windows ridisegnerebbe comunque cornice e pulsanti "fantasma" all'attivazione:
        // WM_NCPAINT non disegna nulla, WM_NCACTIVATE conferma senza ridisegnare
        if (m.Msg == 0x85) { m.Result = IntPtr.Zero; return; }
        if (m.Msg == 0x86) { m.Result = (IntPtr)1; return; }
        base.WndProc(ref m);
        if (m.Msg == 0x24) { // WM_GETMINMAXINFO: massimizzata non copre la barra delle applicazioni
            try {
                var sc = Screen.FromHandle(Handle); var wa = sc.WorkingArea; var bd = sc.Bounds;
                Marshal.WriteInt32(m.LParam, 8, wa.Width); Marshal.WriteInt32(m.LParam, 12, wa.Height);
                Marshal.WriteInt32(m.LParam, 16, wa.Left - bd.Left); Marshal.WriteInt32(m.LParam, 20, wa.Top - bd.Top);
            } catch { }
        }
    }

    // Bordi per ridimensionare: valgono anche sopra i pannelli figli (vedi Canvas/Btn, che restituiscono HTTRANSPARENT)
    public int HitEdge(IntPtr lp) {
        if (WindowState != FormWindowState.Normal) return 0;
        long v = lp.ToInt64();
        var p = PointToClient(new Point((short)(v & 0xFFFF), (short)((v >> 16) & 0xFFFF)));
        const int g = 7; bool l = p.X < g, r = p.X >= Width - g, t = p.Y < g, b = p.Y >= Height - g;
        if (t && l) return 13; if (t && r) return 14; if (b && l) return 16; if (b && r) return 17;
        if (l) return 10; if (r) return 11; if (t) return 12; if (b) return 15;
        return 0;
    }
    protected override void OnSizeChanged(EventArgs e) {
        base.OnSizeChanged(e);
        bool mx = WindowState == FormWindowState.Maximized;
        bMax.Icon = mx ? CapIcon.Restore : CapIcon.Max; bMax.Text = mx ? "Ripristina" : "Ingrandisci"; bMax.Invalidate();
    }
    protected override void OnFormClosing(FormClosingEventArgs e) {
        if (AnyBusy && e.CloseReason == CloseReason.UserClosing &&
            MessageBox.Show(this, "È in corso un'installazione. Chiudendo ora non saprai se è andata a buon fine.\n\nChiudere comunque?", "Erodyne Suite",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) e.Cancel = true;
        base.OnFormClosing(e);
    }
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        using (var p = new Pen(Th.Border)) e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); Invalidate(); }

    // ---------- navigazione ----------
    void Go(int p) {
        page = p;
        bool home = p < 0;
        hUpdateAll.Visible = hCheck.Visible = home;
        foreach (var b in cardMain.Concat(cardMore)) b.Visible = home;
        foreach (Control c in new Control[] { pMain, pFolder, pGit, pLocate, pUninst, notes }) c.Visible = !home;
        RefreshUi();
    }

    void RefreshUi() {
        if (InvokeRequired) { BeginInvoke((Action)RefreshUi); return; }
        int upd = states.Count(x => x.UpdateAvailable);
        hUpdateAll.Text = upd > 0 ? "Aggiorna tutto (" + upd + ")" : "Tutto aggiornato";
        hUpdateAll.Enabled = upd > 0 && !AnyBusy && checking == 0;
        hCheck.Enabled = !AnyBusy && checking == 0;
        for (int i = 0; i < states.Count; i++) {
            var s = states[i];
            cardMain[i].Text = ActionText(s);
            cardMain[i].Enabled = ActionEnabled(s);
        }
        var c = Cur;
        if (c != null) {
            pMain.Text = ActionText(c); pMain.Enabled = ActionEnabled(c);
            pMain.C1 = c.Def.C1; pMain.C2 = c.Def.C2;
            pFolder.Visible = c.InstallDir != null && Directory.Exists(c.InstallDir);
            pUninst.Visible = c.Installed && c.UninstallCmd != null;
            pUninst.Enabled = !c.Busy && !queueRunning;
            pLocate.Visible = !c.Installed && !c.Def.AdminInstall; // i programmi da amministratore stanno solo in Programmi
            string txt = string.IsNullOrEmpty(c.Notes)
                ? (c.Checked ? (c.Error ?? "Nessuna nota per questa versione.") : "Controllo della versione su GitHub…")
                : CleanNotes(c.Notes);
            if (notes.Text != txt.Replace("\r\n", "\n")) notes.Text = txt;
        }
        Layout_();
        content.Invalidate(); side.Invalidate(); bar.Invalidate();
    }

    // Markdown delle note di GitHub in testo semplice
    static string CleanNotes(string md) {
        var t = md.Replace("\r\n", "\n");
        t = System.Text.RegularExpressions.Regex.Replace(t, @"!\[[^\]]*\]\([^)]*\)", "");
        t = System.Text.RegularExpressions.Regex.Replace(t, @"\[([^\]]+)\]\((https?://[^)\s]+)\)", "$1 ($2)");
        t = System.Text.RegularExpressions.Regex.Replace(t, @"(?m)^\s{0,3}#{1,6}\s+", "");
        t = System.Text.RegularExpressions.Regex.Replace(t, @"(?m)^(\s*)[*+]\s+", "$1• ");
        t = System.Text.RegularExpressions.Regex.Replace(t, @"(?m)^(\s*)-\s+", "$1• ");
        t = t.Replace("**", "").Replace("__", "").Replace("`", "");
        t = System.Text.RegularExpressions.Regex.Replace(t, @"<!--.*?-->", "", System.Text.RegularExpressions.RegexOptions.Singleline);
        return t.Trim();
    }

    static string ActionText(AppState s) {
        if (s.Busy) return s.Percent >= 0 ? "In corso " + (int)(s.Percent * 100) + "%" : "In corso…";
        if (s.UpdateAvailable) return "Aggiorna";
        if (s.Installed) return "Avvia";
        if (s.CanDownload) return "Installa";
        if (!s.Checked) return "Controllo…";
        return CanRetry(s) ? "Riprova" : "In arrivo";
    }
    // errore di rete o limite di GitHub: si può ricontrollare; release assente: no
    static bool CanRetry(AppState s) { return s.Checked && !s.CanDownload && !s.Installed && s.Error != null && s.Error.IndexOf("Nessuna versione", StringComparison.Ordinal) < 0 && s.Error.IndexOf("non è ancora firmata", StringComparison.Ordinal) < 0; }
    bool ActionEnabled(AppState s) {
        if (s.Busy) return false;
        if (s.Installed && !s.UpdateAvailable) return true;
        if (CanRetry(s)) return !AnyBusy && checking == 0;
        return s.CanDownload && !AnyBusy && checking == 0; // un installer alla volta, mai durante un controllo
    }

    // ---------- azioni ----------
    void MainAction(AppState s) {
        if (s.Busy) return;
        if (s.Installed && !s.UpdateAvailable) {
            try { Manager.Launch(s); SetStatus(s.Def.Name + " avviato", -1); }
            catch (Win32Exception e) { SetStatus(e.NativeErrorCode == 1223 ? "Avvio annullato" : "Avvio non riuscito: " + e.Message, -1); }
            catch (Exception e) { SetStatus("Avvio non riuscito: " + e.Message, -1); }
            return;
        }
        if (CanRetry(s)) { RefreshAll(true); return; }
        if (s.CanDownload && !AnyBusy && checking == 0) Run(s, null);
    }

    void Run(AppState s, Action done) {
        var job = s.Snapshot();
        s.Busy = true; s.Percent = 0; s.Error = null;
        bool update = s.Installed;
        RefreshUi();
        ThreadPool.QueueUserWorkItem(_ => {
            string msg; Manager.Payload file = null;
            try {
                file = Manager.Fetch(job, (p, t) => { s.Percent = p; SetStatus(s.Def.Name + ": " + t, p); RefreshUi(); });
                s.Percent = -1;
                if (!file.Signed && !ConfirmUnsigned(job, file.Hash)) throw new OperationCanceledException();
                SetStatus(s.Def.Name + ": installazione in corso…", -1); RefreshUi();
                int code = Manager.RunInstaller(s, file);
                Manager.DetectLocal(s);
                // l'installer può uscire con 0 senza aver cambiato nulla (es. programma aperto che blocca i file)
                bool stale = update && s.InstalledVersion != null && Ver.Newer(job.LatestVersion, s.InstalledVersion);
                if (code == 0 && s.Installed && !stale)
                    msg = s.Def.Name + (update ? " aggiornato" : " installato") + (s.InstalledVersion != null ? " (" + s.InstalledVersion + ")" : "");
                else if (stale)
                    msg = s.Def.Name + ": aggiornamento non applicato, è ancora la " + s.InstalledVersion + ". Chiudi " + s.Def.Name + " e riprova";
                else msg = s.Def.Name + ": installazione non completata (codice " + code + ")";
            } catch (OperationCanceledException) {
                msg = s.Def.Name + ": installazione annullata";
            } catch (Win32Exception e) {
                msg = e.NativeErrorCode == 1223 ? s.Def.Name + ": installazione annullata" : s.Def.Name + ": " + e.Message;
            } catch (Exception e) {
                msg = s.Def.Name + ": " + e.Message;
                s.Error = e.Message;
            }
            if (file != null) file.Dispose();
            s.Busy = false; s.Percent = -1;
            SetStatus(msg, -1);
            RefreshUi();
            if (done != null) done();
        });
    }

    // Senza firma la suite non può sapere chi ha pubblicato il file: lo dice e mostra l'impronta
    bool ConfirmUnsigned(AppState s, string hash) {
        Func<bool> ask = () => MessageBox.Show(this,
            s.Def.Name + " " + (s.LatestVersion ?? "") + "\n\n" +
            "Origine: github.com/" + s.Def.Repo + "\nFile: " + s.AssetName + "\nSHA-256: " + hash + "\n\n" +
            "Questo installer non è firmato: la suite controlla che arrivi integro da GitHub, ma non può garantire chi l'ha pubblicato." +
            (s.Def.AdminInstall ? "\nVerrà avviato come amministratore." : "") + "\n\nInstallare?",
            "Erodyne Suite", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
        return InvokeRequired ? (bool)Invoke(ask) : ask();
    }

    void UpdateAll() {
        var list = states.Where(x => x.UpdateAvailable && !x.Busy).ToList();
        if (list.Count == 0 || checking > 0) return;
        queueRunning = true;
        int i = 0;
        Action next = null;
        next = () => {
            if (i >= list.Count) { queueRunning = false; SetStatus("Aggiornamenti completati", -1); RefreshUi(); return; }
            Run(list[i++], next);
        };
        next();
    }

    void UninstallApp(AppState s) {
        if (MessageBox.Show(this, "Disinstallare " + s.Def.Name + "?\n\nImpostazioni e dati personali di solito vengono mantenuti.", "Erodyne Suite",
            MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        s.Busy = true; RefreshUi();
        SetStatus(s.Def.Name + ": disinstallazione…", -1);
        ThreadPool.QueueUserWorkItem(_ => {
            string msg;
            try { Manager.Uninstall(s); Manager.DetectLocal(s); msg = s.Installed ? s.Def.Name + ": disinstallazione non completata" : s.Def.Name + " disinstallato"; }
            catch (Win32Exception e) { msg = e.NativeErrorCode == 1223 ? "Disinstallazione annullata" : e.Message; }
            catch (Exception e) { msg = s.Def.Name + ": " + e.Message; }
            s.Busy = false; SetStatus(msg, -1); RefreshUi();
        });
    }

    void Locate(AppState s) {
        if (s.Def.AdminInstall) {
            MessageBox.Show(this, s.Def.Name + " si installa in Programmi: la suite lo cerca solo lì, così nessun altro programma può spacciarsi per lui.\n\nInstallalo con il pulsante Installa.", "Erodyne Suite", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        using (var d = new OpenFileDialog { Title = "Dov'è " + s.Def.ExeName + "?", Filter = s.Def.ExeName + "|" + s.Def.ExeName + "|Programmi (*.exe)|*.exe", FileName = s.Def.ExeName }) {
            if (d.ShowDialog(this) != DialogResult.OK) return;
            Settings.Set("path." + s.Def.Id, d.FileName);
            Manager.DetectLocal(s);
            RefreshUi();
        }
    }

    void RefreshAll(bool online) {
        if (AnyBusy) { SetStatus("Attendi la fine dell'operazione in corso", -1); return; }
        if (online && checking > 0) return;
        foreach (var s in states) Manager.DetectLocal(s);
        RefreshUi();
        if (!online) return;
        SetStatus("Controllo aggiornamenti su GitHub…", -1);
        int left = states.Count;
        checking = left;
        foreach (var s in states) {
            var st = s;
            ThreadPool.QueueUserWorkItem(_ => {
                Manager.CheckOnline(st);
                Interlocked.Decrement(ref checking);
                if (Interlocked.Decrement(ref left) == 0) {
                    int n = states.Count(x => x.UpdateAvailable);
                    var failed = states.Where(x => x.Error != null && !x.Error.StartsWith("Nessuna versione") && x.Error.IndexOf("non è ancora firmata", StringComparison.Ordinal) < 0).ToList();
                    if (states.All(x => !x.Online)) SetStatus("Nessuna connessione a GitHub", -1);
                    else if (n > 0) SetStatus(n == 1 ? "1 aggiornamento disponibile" : n + " aggiornamenti disponibili", -1);
                    else if (failed.Count > 0 && failed.Count == states.Count(x => x.Error != null) && states.All(x => x.Error != null)) SetStatus(failed[0].Error, -1);
                    else if (failed.Count > 0) SetStatus("Controllo completato, con avvisi per: " + string.Join(", ", failed.Select(x => x.Def.Name).ToArray()), -1);
                    else SetStatus(Program.StartMessage != null ? Program.StartMessage + "  ·  tutto aggiornato" : "Tutto aggiornato", -1);
                }
                RefreshUi();
            });
        }
        ThreadPool.QueueUserWorkItem(_ => {
            try {
                var r = Manager.LatestRelease(Catalog.SuiteRepo);
                if (Ver.Newer(r.Version, Program.Version)) { suiteUpdate = r.Version; suitePage = r.Page; RefreshUi(); }
            } catch { }
        });
    }

    void SetStatus(string t, double p) { status = t; percent = p; if (IsHandleCreated) BeginInvoke((Action)(() => bar.Invalidate())); }

    // ---------- disegno: barra del titolo ----------
    void PaintTitle(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        Th.Logo(g, new RectangleF(16, 11, 24, 24));
        using (var f = Th.F(10.5f, FontStyle.Bold)) Th.Text_(g, "Erodyne", f, Th.Text, new RectangleF(48, 0, 80, TitleH));
        using (var f = Th.F(10.5f)) Th.Text_(g, "Suite", f, Th.Dim, new RectangleF(52 + MeasureW(g, "Erodyne", 10.5f, FontStyle.Bold), 0, 60, TitleH));
        using (var p = new Pen(Th.Border)) g.DrawLine(p, 0, TitleH - 1, title.Width, TitleH - 1);
    }
    static float MeasureW(Graphics g, string s, float size, FontStyle st) { using (var f = Th.F(size, st)) return g.MeasureString(s, f).Width - 2; }

    // ---------- disegno: barra laterale ----------
    int sideHover = -99;
    const int ItemH = 58, ItemTop = 70;
    Rectangle ItemRect(int i) { return new Rectangle(12, ItemTop + (i + 1) * (ItemH + 4) + (i >= 0 ? 34 : 0), SideW - 24, ItemH); }
    Rectangle CheckRect { get { return new Rectangle(12, side.Height - 92, SideW - 24, 34); } }
    Rectangle SuiteRect { get { return new Rectangle(12, side.Height - 132, SideW - 24, 34); } }
    int SideHit(Point p) {
        for (int i = -1; i < states.Count; i++) if (ItemRect(i).Contains(p)) return i;
        if (CheckRect.Contains(p)) return -2;
        if (suiteUpdate != null && SuiteRect.Contains(p)) return -3;
        return -99;
    }

    void PaintSide(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        using (var p = new Pen(Th.Border)) g.DrawLine(p, SideW - 1, 0, SideW - 1, side.Height);
        using (var f = Th.F(8f, FontStyle.Bold)) {
            Th.Text_(g, "ESPLORA", f, Th.Faint, new RectangleF(24, ItemTop - 34, 200, 24));
            Th.Text_(g, "LIBRERIA", f, Th.Faint, new RectangleF(24, ItemRect(0).Y - 30, 200, 24));
        }
        for (int i = -1; i < states.Count; i++) {
            var r = ItemRect(i);
            bool sel = page == i, hov = sideHover == i;
            if (sel || hov) using (var p = Th.Round(r, 12)) using (var b = new SolidBrush(sel ? Th.Surface2 : Th.Surface)) g.FillPath(b, p);
            if (sel) using (var p = Th.Round(new RectangleF(r.X, r.Y + 16, 4, r.Height - 32), 2)) using (var b = Th.Grad(new RectangleF(r.X, r.Y + 16, 4, r.Height - 32), Th.A1, Th.A2)) g.FillPath(b, p);
            var tile = new RectangleF(r.X + 14, r.Y + 11, 36, 36);
            if (i < 0) {
                Th.Logo(g, tile);
                using (var f = Th.F(10.5f, FontStyle.Bold)) Th.Text_(g, "Home", f, Th.Text, new RectangleF(r.X + 62, r.Y + 9, 160, 22));
                using (var f = Th.F(8.5f)) Th.Text_(g, "Panoramica della suite", f, Th.Dim, new RectangleF(r.X + 62, r.Y + 29, 160, 18));
                continue;
            }
            var s = states[i];
            Th.AppTile(g, s.Def, tile);
            Color dot; string sub = StatusLine(s, out dot);
            using (var f = Th.F(10.5f, FontStyle.Bold)) Th.Text_(g, s.Def.Name, f, Th.Text, new RectangleF(r.X + 62, r.Y + 9, r.Width - 80, 22));
            using (var b = new SolidBrush(dot)) g.FillEllipse(b, r.X + 62, r.Y + 35, 7, 7);
            using (var f = Th.F(8.5f)) Th.Text_(g, sub, f, Th.Dim, new RectangleF(r.X + 74, r.Y + 29, r.Width - 86, 18));
        }
        if (suiteUpdate != null) {
            var r = SuiteRect;
            using (var p = Th.Round(r, 10)) using (var b = new SolidBrush(Color.FromArgb(sideHover == -3 ? 60 : 36, Th.A1))) g.FillPath(b, p);
            using (var f = Th.F(9f, FontStyle.Bold)) Th.Text_(g, "Nuova Erodyne Suite " + suiteUpdate, f, Th.Text, r, StringAlignment.Center);
        }
        var cr = CheckRect;
        if (sideHover == -2) using (var p = Th.Round(cr, 10)) using (var b = new SolidBrush(Th.Surface)) g.FillPath(b, p);
        using (var f = Th.F(9f, FontStyle.Bold)) Th.Text_(g, "↻  Controlla aggiornamenti", f, sideHover == -2 ? Th.Text : Th.Dim, new RectangleF(cr.X + 12, cr.Y, cr.Width, cr.Height));
        using (var f = Th.F(8f)) Th.Text_(g, "Erodyne Suite " + Program.Version, f, Th.Faint, new RectangleF(24, side.Height - 50, 200, 30));
    }

    static string StatusLine(AppState s, out Color dot) {
        if (s.Busy) { dot = Th.A2; return s.Percent >= 0 ? "In corso " + (int)(s.Percent * 100) + "%" : "Operazione in corso…"; }
        if (s.UpdateAvailable) { dot = Th.Amber; return "Da aggiornare a " + s.LatestVersion; }
        if (s.Installed) { dot = Th.Green; return s.InstalledVersion != null ? "Installato · " + s.InstalledVersion : "Installato"; }
        if (s.CanDownload) { dot = Th.Faint; return "Non installato"; }
        dot = Th.Faint; return !s.Checked ? "Controllo…" : CanRetry(s) ? "Controllo non riuscito" : s.Error != null && s.Error.IndexOf("firmata", StringComparison.Ordinal) >= 0 ? "In attesa di firma" : "Non ancora pubblicato";
    }

    // ---------- disegno: barra di stato ----------
    void PaintBar(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        using (var p = new Pen(Th.Border)) g.DrawLine(p, 0, 0, bar.Width, 0);
        using (var f = Th.F(8.5f)) Th.Text_(g, status, f, Th.Dim, new RectangleF(20, 0, bar.Width - 280, BarH));
        if (percent >= 0 || AnyBusy) {
            var r = new RectangleF(bar.Width - 240, BarH / 2f - 3, 220, 6);
            using (var p = Th.Round(r, 3)) using (var b = new SolidBrush(Th.Surface3)) g.FillPath(b, p);
            float w = percent >= 0 ? (float)(r.Width * percent) : r.Width * 0.3f;
            if (w > 6) { var rr = new RectangleF(r.X, r.Y, w, r.Height); using (var p = Th.Round(rr, 3)) using (var b = Th.Grad(rr, Th.A1, Th.A2)) g.FillPath(b, p); }
        }
    }

    // ---------- disposizione e disegno del contenuto ----------
    const int M = 32;
    RectangleF heroHome, heroApp;
    bool compact;
    List<RectangleF> cards = new List<RectangleF>();

    void Layout_() {
        int W = content.Width, H = content.Height;
        if (W < 10) return;
        if (page < 0) {
            heroHome = new RectangleF(M, 28, W - 2 * M, 196);
            int bw1 = hUpdateAll.Measure(), bw2 = hCheck.Measure();
            hUpdateAll.SetBounds((int)heroHome.X + 36, (int)heroHome.Bottom - 64, bw1, 40);
            hCheck.SetBounds(hUpdateAll.Right + 10, (int)heroHome.Bottom - 64, bw2, 40);
            cards.Clear();
            float top = heroHome.Bottom + 64, gap = 20, cw = (W - 2 * M - gap * (states.Count - 1)) / states.Count;
            compact = cw < 230;
            if (compact) {
                // finestra stretta: schede orizzontali su due colonne
                int cols = 2, rows = (states.Count + 1) / 2;
                float w2 = (W - 2 * M - gap) / cols, h2 = Math.Max(140, Math.Min(150, (H - top - 28 - gap * (rows - 1)) / rows));
                for (int i = 0; i < states.Count; i++) {
                    var r = new RectangleF(M + (i % cols) * (w2 + gap), top + (i / cols) * (h2 + gap), w2, h2);
                    cards.Add(r);
                    cardMore[i].Visible = false;
                    cardMain[i].SetBounds((int)(r.X + 116), (int)(r.Bottom - 16 - 36), (int)Math.Min(160, r.Width - 136), 36);
                }
                return;
            }
            float ch = Math.Max(300, Math.Min(380, H - top - 28));
            for (int i = 0; i < states.Count; i++) {
                var r = new RectangleF(M + i * (cw + gap), top, cw, ch);
                cards.Add(r);
                int bx = (int)r.X + 20, by = (int)r.Bottom - 60, inner = (int)r.Width - 40;
                // schede strette: solo il pulsante principale (i dettagli restano nella barra a sinistra)
                bool narrow = inner < 240;
                cardMore[i].Visible = !narrow;
                cardMain[i].SetBounds(bx, by, narrow ? inner : inner - 112, 40);
                cardMore[i].SetBounds(bx + inner - 102, by, 102, 40);
            }
        } else {
            var s = Cur;
            heroApp = new RectangleF(M, 28, W - 2 * M, 236);
            int y = (int)heroApp.Bottom - 70, x = (int)heroApp.X + 36;
            pMain.SetBounds(x, y, Math.Max(170, pMain.Measure()), 46);
            x = pMain.Right + 12;
            foreach (var b in new[] { pFolder, pGit, pLocate, pUninst }) {
                if (!b.Visible) continue;
                b.SetBounds(x, y + 3, b.Measure(), 40); b.Kind = b == pUninst ? BtnKind.Danger : BtnKind.OnColor; x = b.Right + 10;
            }
            float top = heroApp.Bottom + 24, lw = (W - 2 * M - 20) * 0.42f;
            var nr = new RectangleF(M + lw + 20, top, W - 2 * M - lw - 20, H - top - 24);
            notes.SetBounds((int)nr.X + 22, (int)nr.Y + 58, (int)nr.Width - 36, Math.Max(40, (int)nr.Height - 74));
        }
    }

    void PaintContent(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        if (page < 0) PaintHome(g); else PaintApp(g, Cur);
    }

    static void Banner(Graphics g, RectangleF r, Color c1, Color c2) {
        if (r.Width < 20 || r.Height < 20) return;
        using (var p = Th.Round(r, 20)) {
            using (var b = Th.Grad(r, c1, c2)) g.FillPath(b, p);
            var clip = g.Clip; g.SetClip(p, CombineMode.Intersect);
            using (var b = new SolidBrush(Color.FromArgb(30, 255, 255, 255))) {
                g.FillEllipse(b, r.Right - r.Height * 1.1f, r.Y - r.Height * 0.55f, r.Height * 1.3f, r.Height * 1.3f);
                g.FillEllipse(b, r.Right - r.Height * 0.6f, r.Y + r.Height * 0.35f, r.Height * 0.9f, r.Height * 0.9f);
            }
            var lr = new RectangleF(r.X, r.Y, r.Width * 0.75f, r.Height);
            using (var b = new LinearGradientBrush(new RectangleF(lr.X - 1, lr.Y, lr.Width + 2, lr.Height), Color.FromArgb(150, 11, 13, 18), Color.FromArgb(0, 11, 13, 18), 0f)) g.FillRectangle(b, lr);
            g.Clip = clip;
        }
    }

    void PaintHome(Graphics g) {
        var r = heroHome;
        Banner(g, r, Th.A1, Th.A2);
        using (var f = Th.F(9f, FontStyle.Bold)) Th.Text_(g, "ERODYNE  SUITE", f, Color.FromArgb(210, 255, 255, 255), new RectangleF(r.X + 36, r.Y + 28, 400, 20));
        using (var f = Th.F(24f, FontStyle.Bold)) Th.Text_(g, "I tuoi programmi, in un posto solo", f, Color.White, new RectangleF(r.X + 34, r.Y + 50, r.Width - 60, 46));
        using (var f = Th.F(10.5f)) Th.Text_(g, "Installa, aggiorna e avvia MultiTool, Remostation, Video2All e DiskVital con un clic.", f, Color.FromArgb(225, 255, 255, 255), new RectangleF(r.X + 36, r.Y + 96, r.Width - 60, 24));

        int inst = states.Count(x => x.Installed), upd = states.Count(x => x.UpdateAvailable);
        using (var f = Th.F(13f, FontStyle.Bold)) Th.Text_(g, "Libreria", f, Th.Text, new RectangleF(M, r.Bottom + 20, 300, 30));
        using (var f = Th.F(9f)) Th.Text_(g, inst + " di " + states.Count + " installati" + (upd > 0 ? "  ·  " + upd + (upd == 1 ? " aggiornamento" : " aggiornamenti") : ""), f, Th.Dim,
            new RectangleF(content.Width - M - 400, r.Bottom + 20, 400, 30), StringAlignment.Far);

        for (int i = 0; i < cards.Count && i < states.Count; i++) {
            var c = cards[i]; var s = states[i];
            if (compact) { PaintCompactCard(g, c, s); continue; }
            using (var p = Th.Round(c, 18)) {
                using (var b = new SolidBrush(Th.Surface)) g.FillPath(b, p);
                using (var pen = new Pen(Th.Border)) g.DrawPath(pen, p);
                var clip = g.Clip; g.SetClip(p, CombineMode.Intersect);
                var art = new RectangleF(c.X, c.Y, c.Width, 118);
                using (var b = Th.Grad(art, Color.FromArgb(70, s.Def.C1), Color.FromArgb(30, s.Def.C2))) g.FillRectangle(b, art);
                using (var b = new SolidBrush(Color.FromArgb(20, 255, 255, 255))) g.FillEllipse(b, art.Right - 120, art.Y - 50, 170, 170);
                g.Clip = clip;
            }
            Th.AppTile(g, s.Def, new RectangleF(c.X + 20, c.Y + 26, 66, 66));
            using (var f = Th.F(14f, FontStyle.Bold)) Th.Text_(g, s.Def.Name, f, Th.Text, new RectangleF(c.X + 20, c.Y + 132, c.Width - 40, 28));
            using (var f = Th.F(9.5f)) Th.Text_(g, s.Def.Tagline, f, Th.Dim, new RectangleF(c.X + 20, c.Y + 160, c.Width - 40, 22));
            Color dot; string line = StatusLine(s, out dot);
            float pw; Th.Pill(g, line, dot == Th.Faint ? Th.Dim : dot, new PointF(c.X + 20, c.Y + 192), out pw, c.Width - 40);
            float fy = c.Y + 232;
            using (var f = Th.F(9f)) foreach (var feat in s.Def.Features) {
                float h = g.MeasureString(feat, f, (int)(c.Width - 54)).Height + 6;
                if (fy + h > c.Bottom - 72) break;
                using (var b = new SolidBrush(s.Def.C1)) g.FillEllipse(b, c.X + 22, fy + 7, 5, 5);
                Th.Text_(g, feat, f, Th.Dim, new RectangleF(c.X + 34, fy, c.Width - 54, h), StringAlignment.Near, StringAlignment.Near, true);
                fy += h;
            }
        }
    }

    void PaintCompactCard(Graphics g, RectangleF c, AppState s) {
        using (var p = Th.Round(c, 16)) {
            using (var b = new SolidBrush(Th.Surface)) g.FillPath(b, p);
            var clip = g.Clip; g.SetClip(p, CombineMode.Intersect);
            var art = new RectangleF(c.X, c.Y, 96, c.Height);
            using (var b = Th.Grad(art, Color.FromArgb(70, s.Def.C1), Color.FromArgb(30, s.Def.C2))) g.FillRectangle(b, art);
            g.Clip = clip;
            using (var pen = new Pen(Th.Border)) g.DrawPath(pen, p);
        }
        float ts = Math.Min(56, c.Height - 40);
        Th.AppTile(g, s.Def, new RectangleF(c.X + 20, c.Y + (c.Height - ts) / 2, ts, ts));
        float x = c.X + 116, w = c.Width - 116 - 20;
        using (var f = Th.F(13f, FontStyle.Bold)) Th.Text_(g, s.Def.Name, f, Th.Text, new RectangleF(x, c.Y + 16, w, 26));
        using (var f = Th.F(9f)) Th.Text_(g, s.Def.Tagline, f, Th.Dim, new RectangleF(x, c.Y + 42, w, 20));
        Color dot; string line = StatusLine(s, out dot);
        float pw; Th.Pill(g, line, dot == Th.Faint ? Th.Dim : dot, new PointF(x, c.Y + 70), out pw, w); // riga sua: non si taglia accanto al pulsante
    }

    void PaintApp(Graphics g, AppState s) {
        var r = heroApp;
        Banner(g, r, s.Def.C1, s.Def.C2);
        Th.AppTile(g, s.Def, new RectangleF(r.X + 36, r.Y + 32, 92, 92));
        using (var f = Th.F(26f, FontStyle.Bold)) Th.Text_(g, s.Def.Name, f, Color.White, new RectangleF(r.X + 148, r.Y + 34, r.Width - 180, 48));
        using (var f = Th.F(11f)) Th.Text_(g, s.Def.Tagline, f, Color.FromArgb(230, 255, 255, 255), new RectangleF(r.X + 150, r.Y + 80, r.Width - 180, 24));
        float x = r.X + 150, pw;
        Color dot; string line = StatusLine(s, out dot);
        Th.Pill(g, line, Color.White, new PointF(x, r.Y + 110), out pw); x += pw + 8;
        if (s.LatestVersion != null && !s.UpdateAvailable) { Th.Pill(g, "Ultima versione " + s.LatestVersion, Color.White, new PointF(x, r.Y + 110), out pw); x += pw + 8; }
        if (s.Installed && s.UpdateAvailable && s.InstalledVersion != null) { Th.Pill(g, "Installata " + s.InstalledVersion, Color.White, new PointF(x, r.Y + 110), out pw); }

        float top = r.Bottom + 24, lw = (content.Width - 2 * M - 20) * 0.42f, H = content.Height - top - 24;
        var lr = new RectangleF(M, top, lw, H);
        var nr = new RectangleF(M + lw + 20, top, content.Width - 2 * M - lw - 20, H);
        foreach (var box in new[] { lr, nr }) using (var p = Th.Round(box, 18)) {
            using (var b = new SolidBrush(Th.Surface)) g.FillPath(b, p);
            using (var pen = new Pen(Th.Border)) g.DrawPath(pen, p);
        }
        using (var f = Th.F(12f, FontStyle.Bold)) {
            Th.Text_(g, "Cosa fa", f, Th.Text, new RectangleF(lr.X + 22, lr.Y + 18, lr.Width - 44, 28));
            Th.Text_(g, s.LatestVersion != null ? "Novità della versione " + s.LatestVersion : "Novità", f, Th.Text, new RectangleF(nr.X + 22, nr.Y + 18, nr.Width - 44, 28));
        }
        float fy = lr.Y + 62;
        using (var f = Th.F(10f)) foreach (var feat in s.Def.Features) {
            var cr = new RectangleF(lr.X + 22, fy + 2, 22, 22);
            using (var p = Th.Round(cr, 7)) using (var b = new SolidBrush(Color.FromArgb(40, s.Def.C1))) g.FillPath(b, p);
            using (var pen = new Pen(s.Def.C1, 2f)) g.DrawLines(pen, new[] { new PointF(cr.X + 6, cr.Y + 11.5f), new PointF(cr.X + 9.5f, cr.Y + 15), new PointF(cr.X + 16, cr.Y + 8) });
            var tr = new RectangleF(lr.X + 56, fy, lr.Width - 78, 44);
            Th.Text_(g, feat, f, Th.Text, tr, StringAlignment.Near, StringAlignment.Near, true);
            fy += 50;
        }
        using (var f = Th.F(8.5f)) {
            float iy = lr.Bottom - 74;
            if (iy > fy) {
                Th.Text_(g, "Cartella", f, Th.Faint, new RectangleF(lr.X + 22, iy, 90, 20));
                Th.Text_(g, s.InstallDir ?? "—", f, Th.Dim, new RectangleF(lr.X + 110, iy, lr.Width - 132, 20));
                Th.Text_(g, "Origine", f, Th.Faint, new RectangleF(lr.X + 22, iy + 24, 90, 20));
                Th.Text_(g, "github.com/" + s.Def.Repo, f, Th.Dim, new RectangleF(lr.X + 110, iy + 24, lr.Width - 132, 20));
            }
        }
    }
}
