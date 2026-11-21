using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

public class MainForm : AppForm {
    readonly ItemList list = new ItemList();
    readonly TextBox search = new TextBox { BorderStyle = BorderStyle.None };
    readonly Btn bSearch = new Btn { Kind = BtnKind.OnColor, Text = "Cerca", Glyph = "" };
    readonly Btn bInstall = new Btn { Kind = BtnKind.OnColor, Text = "INSTALLA", Glyph = "" };
    readonly Btn bSave = new Btn { Text = "Salva come profilo…", Glyph = "" };
    readonly Btn bNone = new Btn { Kind = BtnKind.Ghost, Text = "Togli le spunte" };
    readonly Btn[] tabs = { new Btn { Text = "Consigliati", Glyph = "" }, new Btn { Text = "Ricerca", Glyph = "" }, new Btn { Text = "Profili", Glyph = "" } };
    int tab;
    List<Pkg> rec = Catalog.Recommended();
    List<Pkg> found = new List<Pkg>();
    readonly List<Pkg> extra = new List<Pkg>();          // aggiunti da un profilo, non presenti tra i consigliati
    List<Profile> profiles = new List<Profile>();
    Dictionary<string, string> wg = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    List<string> names = new List<string>();
    bool busy, checking, searching;
    string lastQuery = "";
    CancellationTokenSource cts;
    const int M = 28;
    RectangleF hero, searchBox;

    public MainForm() : base("Erodyne Installa", "Programmi per un PC nuovo, dai siti ufficiali") {
        content.Controls.Add(list); content.Controls.Add(search);
        foreach (var b in new[] { bSearch, bInstall, bSave, bNone }) content.Controls.Add(b);
        foreach (var b in tabs) content.Controls.Add(b);
        for (int i = 0; i < tabs.Length; i++) { int k = i; tabs[i].Click += (s, e) => SetTab(k); }
        bInstall.Font = Th.F(10f, FontStyle.Bold);
        search.BackColor = Color.FromArgb(0x1A, 0x14, 0x2C); search.ForeColor = Color.White; search.Font = Th.F(11f);
        search.KeyDown += (s, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; DoSearch(); } };
        search.TextChanged += (s, e) => content.Invalidate(Rectangle.Round(searchBox));
        bSearch.Click += (s, e) => DoSearch();
        bInstall.Click += (s, e) => { if (busy) { if (cts != null) cts.Cancel(); } else Install(); };
        bSave.Click += (s, e) => SaveProfile();
        bNone.Click += (s, e) => { foreach (var p in All()) p.Selected = false; Fill(); };
        list.CheckChanged += () => { foreach (var it in list.Items) { var p = it.Tag as Pkg; if (p != null) p.Selected = it.Checked; } UpdateUi(); };
        list.ItemActivated += it => { var pr = it.Tag as Profile; if (pr != null) UseProfile(pr); };
        list.ItemMenu += (it, pt) => {
            var m = DarkMenu.New();
            var pr = it.Tag as Profile;
            if (pr != null) {
                DarkMenu.Add(m, "Usa questo profilo", () => UseProfile(pr));
                DarkMenu.Add(m, "Elimina il profilo", () => DeleteProfile(pr), pr.Origin == "tuo");
            } else {
                var p = it.Tag as Pkg; if (p == null) return;
                DarkMenu.Add(m, "Copia l'ID winget", () => { try { Clipboard.SetText(p.Id); } catch { } });
                DarkMenu.Add(m, "Pagina del programma su winget.run", () => Proc.Open("https://winget.run/pkg/" + p.Id.Replace('.', '/')), p.Source == "winget" && p.Id.Contains("."));
            }
            m.Show(list, pt);
        };
        content.Paint += PaintContent;
        content.Resize += (s, e) => Layout_();
        KeyDown += (s, e) => {
            if (e.Control && e.KeyCode == Keys.F) { search.Focus(); search.SelectAll(); e.Handled = true; }
            else if (e.KeyCode == Keys.F5 && !busy) { CheckInstalled(); e.Handled = true; }
        };
        FormClosing += (s, e) => {
            if (busy && MessageBox.Show("Sto installando dei programmi. Interrompere e chiudere?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) e.Cancel = true;
            else if (cts != null) cts.Cancel();
        };
        Shown += (s, e) => { profiles = Catalog.Profiles(); Fill(); UpdateUi(); CheckInstalled(); list.Focus(); };
        Prova.Steps.Add(new Prova.Step { Name = "consigliati", Ready = () => !checking, MaxSec = 300 });
        Prova.Steps.Add(new Prova.Step { Name = "ricerca", Do = () => { search.Text = "vlc"; DoSearch(); }, Ready = () => !searching, MaxSec = 120 });
        Prova.Steps.Add(new Prova.Step { Name = "profili", Do = () => SetTab(2) });
        Prova.Steps.Add(new Prova.Step { Name = "installa", Do = () => {
            foreach (var p in All()) p.Selected = false;
            var x = rec.First(p => p.Id == "7zip.7zip"); x.Selected = true; x.Installed = false;
            SetTab(0); Install();
        }, Ready = () => !busy, MaxSec = 600 });
    }

    IEnumerable<Pkg> All() { return rec.Concat(extra).Concat(found); }
    List<Pkg> Chosen() {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return All().Where(p => p.Selected && seen.Add(p.Id)).ToList();
    }

    void CheckInstalled() {
        checking = true; Status = "Controllo i programmi già installati…"; Progress = 2; UpdateUi();
        ThreadPool.QueueUserWorkItem(_ => {
            var w = Winget.Installed(); var n = Winget.InstalledNames();
            Ui(() => {
                wg = w; names = n; checking = false; Progress = -1;
                Catalog.MarkInstalled(All(), wg, names);
                int inst = rec.Count(p => p.Installed);
                Status = Winget.Path_ == null ? "winget non trovato: installa \"Programma di installazione app\" dal Microsoft Store" : inst + " dei " + rec.Count + " programmi consigliati sono già installati";
                Fill(); UpdateUi();
            });
        });
    }

    void SetTab(int t) { tab = t; Fill(); UpdateUi(); }

    void Fill() {
        list.Reset();
        list.Checks = tab != 2;
        if (tab == 2) {
            list.Headers = new[] { "PROGRAMMI", "ORIGINE" }; list.ColW = new[] { 100, 120 }; list.StatusW = 0;
            foreach (var p in profiles)
                list.Items.Add(new ListItem { Tag = p, Title = p.Name, Sub = string.IsNullOrEmpty(p.Description) ? string.Join(", ", p.Winget.Take(4)) : p.Description, Glyph = "", Checkable = false,
                    Cols = new[] { (p.Winget.Count + p.Local.Count).ToString(), p.Origin == "tuo" ? "creato da te" : p.Origin == "MultiTool" ? "da MultiTool" : "predefinito" } });
            list.EmptyTitle = "Nessun profilo";
        } else {
            list.Headers = new[] { tab == 0 ? "CATEGORIA" : "VERSIONE", tab == 0 ? "" : "ORIGINE" }; list.ColW = new[] { 150, tab == 0 ? 10 : 130 }; list.StatusW = 200;
            var src = tab == 0 ? rec.Concat(extra).ToList() : found;
            foreach (var p in src) list.Items.Add(Item(p));
            list.EmptyTitle = tab == 0 ? "Nessun programma" : searching ? "Cerco…" : lastQuery.Length > 0 ? "Nessun risultato per \"" + lastQuery + "\"" : "Cerca un programma";
            list.EmptyText = tab == 1 && lastQuery.Length == 0 ? "Scrivi il nome nella casella in alto e premi Invio: cerco nel catalogo di winget, che scarica dai siti ufficiali." : "";
        }
        list.Refresh_();
    }

    ListItem Item(Pkg p) {
        string st = p.Status; var col = p.StatusColor;
        if (st == null) { st = p.Installed ? "Già installato" + (string.IsNullOrEmpty(p.Version) ? "" : " · " + p.Version) : checking ? "…" : ""; col = p.Installed ? Th.Green : Th.Dim; }
        return new ListItem { Tag = p, Title = p.Name, Sub = p.LocalFile != null ? "Installer locale: " + Path.GetFileName(p.LocalFile) : p.Id, Checked = p.Selected,
            Glyph = p.LocalFile != null ? "" : p.Source == "msstore" ? "" : "",
            Cols = tab == 0 ? new[] { p.Cat ?? "", "" } : new[] { p.Version ?? "", p.Source == "msstore" ? "Microsoft Store" : "winget" },
            Status = st, StatusColor = col };
    }

    void UpdateUi() {
        int n = Chosen().Count;
        bInstall.Text = busy ? "INTERROMPI" : n > 0 ? "INSTALLA " + n : "INSTALLA";
        bInstall.Glyph = busy ? "" : "";
        bInstall.Enabled = busy || n > 0 && Winget.Path_ != null;
        bSave.Enabled = !busy && n > 0; bNone.Enabled = !busy && n > 0;
        bSearch.Enabled = !busy && !searching; search.Enabled = !busy;
        for (int i = 0; i < tabs.Length; i++) { tabs[i].Kind = i == tab ? BtnKind.Primary : BtnKind.Ghost; tabs[i].C1 = Th.C1; tabs[i].C2 = Th.C2; tabs[i].Enabled = !busy || i != 2; }
        tabs[1].Text = found.Count > 0 ? "Ricerca (" + found.Count + ")" : "Ricerca";
        Layout_(); content.Invalidate();
    }

    void Layout_() {
        int W = content.Width, H = content.Height;
        if (W < 50) return;
        hero = new RectangleF(M, 22, W - 2 * M, 178);
        int iw = Math.Max(170, bInstall.Measure());
        bInstall.SetBounds((int)hero.Right - 30 - iw, (int)hero.Y + 30, iw, 46);
        searchBox = new RectangleF(hero.X + 30, hero.Bottom - 62, Math.Min(560, hero.Width - 60 - 120), 42);
        search.SetBounds((int)searchBox.X + 40, (int)(searchBox.Y + (searchBox.Height - search.PreferredHeight) / 2), (int)searchBox.Width - 52, search.PreferredHeight);
        bSearch.SetBounds((int)searchBox.Right + 10, (int)searchBox.Y + 2, bSearch.Measure(), 38);
        int tx = M, ty = (int)hero.Bottom + 18;
        foreach (var t in tabs) { int w = t.Measure(); t.SetBounds(tx, ty, w, 36); tx += w + 6; }
        int bx = W - M;
        foreach (var b in new[] { bSave, bNone }) { int w = b.Measure(); bx -= w; b.SetBounds(bx, ty, w, 36); bx -= 8; }
        list.SetBounds(M - 8, ty + 48, W - 2 * M + 8, H - ty - 48 - 14);
    }

    void PaintContent(object o, PaintEventArgs e) {
        var g = e.Graphics; Th.Hq(g);
        using (var p = Th.Round(hero, 20)) {
            using (var b = Th.Grad(hero, Th.C1, Th.C2)) g.FillPath(b, p);
            var clip = g.Clip; g.SetClip(p, CombineMode.Intersect);
            using (var b = new SolidBrush(Color.FromArgb(26, 255, 255, 255))) g.FillEllipse(b, hero.Right - hero.Height * 1.3f, hero.Y - hero.Height * 0.7f, hero.Height * 1.5f, hero.Height * 1.5f);
            var lr = new RectangleF(hero.X, hero.Y, hero.Width * 0.7f, hero.Height);
            using (var b = new LinearGradientBrush(new RectangleF(lr.X - 1, lr.Y, lr.Width + 2, lr.Height), Color.FromArgb(130, 11, 13, 18), Color.FromArgb(0, 11, 13, 18), 0f)) g.FillRectangle(b, lr);
            g.Clip = clip;
        }
        using (var f = Th.F(8.5f, FontStyle.Bold)) Th.Text_(g, "INSTALLA PROGRAMMI", f, Color.FromArgb(215, 255, 255, 255), new RectangleF(hero.X + 32, hero.Y + 20, 400, 20));
        using (var f = Th.F(19f, FontStyle.Bold)) Th.Text_(g, "Spunta, premi Installa, fatto", f, Color.White, new RectangleF(hero.X + 30, hero.Y + 40, bInstall.Left - hero.X - 50, 38));
        using (var f = Th.F(9.5f)) Th.Text_(g, "Scaricati dai siti ufficiali tramite winget e installati uno dopo l'altro, senza finestre da cliccare.", f, Color.FromArgb(225, 255, 255, 255), new RectangleF(hero.X + 32, hero.Y + 76, bInstall.Left - hero.X - 50, 22));
        using (var p = Th.Round(searchBox, 12)) {
            using (var b = new SolidBrush(search.BackColor)) g.FillPath(b, p);
            using (var pen = new Pen(Color.FromArgb(90, 255, 255, 255))) g.DrawPath(pen, p);
        }
        if (Th.HasGlyphs) using (var f = Th.G(12f)) Th.Text_(g, "", f, Color.FromArgb(200, 255, 255, 255), new RectangleF(searchBox.X + 10, searchBox.Y, 24, searchBox.Height), StringAlignment.Center);
        if (search.Text.Length == 0 && !search.Focused) using (var f = Th.F(11f)) Th.Text_(g, "Cerca un programma (es. GIMP, Thunderbird, WhatsApp)", f, Color.FromArgb(150, 255, 255, 255), new RectangleF(searchBox.X + 40, searchBox.Y, searchBox.Width - 50, searchBox.Height));
    }

    // ---------- ricerca ----------
    void DoSearch() {
        var q = (search.Text ?? "").Replace("\"", "").Trim();
        if (q.Length < 2) { Status = "Scrivi almeno 2 lettere del programma da cercare"; return; }
        if (searching || busy) return;
        searching = true; lastQuery = q;
        found = found.Where(p => p.Selected).ToList();        // le spunte già date restano
        SetTab(1);
        Status = "Cerco \"" + q + "\"…"; Progress = 2;
        ThreadPool.QueueUserWorkItem(_ => {
            string o; int code = Winget.Run("search \"" + q + "\"", out o, default(CancellationToken), null, 120000);
            var rows = Winget.Table(o);
            Ui(() => {
                searching = false; Progress = -1;
                foreach (var r in rows) {
                    var c = r.Cols;
                    string src = c.Length >= 4 && (c[c.Length - 1] == "winget" || c[c.Length - 1] == "msstore") ? c[c.Length - 1] : "";
                    if (c[1].EndsWith("…")) continue;                         // ID troncato: non installabile con certezza
                    if (found.Any(x => x.Id.Equals(c[1], StringComparison.OrdinalIgnoreCase))) continue;
                    var p = new Pkg { Name = c[0], Id = c[1], Version = c[2] == "Unknown" || c[2] == "Sconosciuto" ? "—" : c[2], Source = src.Length > 0 ? src : "winget", Match = null };
                    string v; if (wg.TryGetValue(p.Id, out v)) { p.Installed = true; }
                    found.Add(p);
                }
                if (rows.Count == 0 && code != 0 && Winget.Hex(code) != "0x8A150014") { string t; Winget.Describe(code, out t); Status = "Ricerca non riuscita: " + t; }
                else Status = found.Count + " risultati per \"" + q + "\"";
                Fill(); UpdateUi();
            });
        });
    }

    // ---------- installazione ----------
    void Install() {
        var todo = Chosen();
        if (todo.Count == 0 || busy) return;
        var already = todo.Where(p => p.Installed).ToList();
        if (already.Count > 0 && MessageBox.Show(string.Join(", ", already.Select(p => p.Name)) + (already.Count == 1 ? " risulta già installato." : " risultano già installati.") + "\n\nReinstallare comunque?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) {
            foreach (var p in already) p.Selected = false;
            todo = Chosen();
            Fill(); UpdateUi();
            if (todo.Count == 0) return;
        }
        busy = true; cts = new CancellationTokenSource(); var ct = cts.Token;
        foreach (var p in todo) { p.Status = "In attesa"; p.StatusColor = Th.Dim; }
        if (tab == 2) SetTab(0);
        Fill(); UpdateUi(); Progress = 0;
        ThreadPool.QueueUserWorkItem(_ => {
            int ok = 0, err = 0; bool reboot = false;
            for (int i = 0; i < todo.Count; i++) {
                if (ct.IsCancellationRequested) { Ui(() => { foreach (var p in todo.Where(x => x.Status == "In attesa")) p.Status = "Non installato"; }); break; }
                var pk = todo[i]; int idx = i;
                Ui(() => { pk.Status = "Scarico…"; pk.StatusColor = Th.C1; Status = "Installo " + pk.Name + " (" + (idx + 1) + " di " + todo.Count + ")…"; Progress = idx / (double)todo.Count; Repaint(); });
                int code;
                if (pk.LocalFile != null) code = RunLocal(pk.LocalFile, ct);
                else code = Winget.Install(pk.Id, pk.Source, ct, s => Ui(() => { pk.Status = s; Repaint(); }));
                string text; bool good = Winget.Describe(code, out text);
                if (text.Contains("riavvio")) reboot = true;
                if (good) ok++; else err++;
                Ui(() => {
                    pk.Status = text; pk.StatusColor = good ? Th.Green : code == -2 ? Th.Dim : Th.Red;
                    if (good) { pk.Installed = true; pk.Selected = false; }
                    Progress = (idx + 1) / (double)todo.Count; Repaint();
                });
            }
            Ui(() => {
                busy = false; Progress = -1;
                Status = (ct.IsCancellationRequested ? "Interrotto: " : "Finito: ") + ok + (ok == 1 ? " installato" : " installati") + (err > 0 ? ", " + err + (err == 1 ? " non riuscito" : " non riusciti") : "") + (reboot ? " · riavvia il PC per completare" : "");
                Fill(); UpdateUi();
                ThreadPool.QueueUserWorkItem(__ => { var w = Winget.Installed(); Ui(() => { wg = w; }); });
            });
        });
    }
    void Repaint() {
        foreach (var it in list.Items) { var p = it.Tag as Pkg; if (p != null && p.Status != null) { it.Status = p.Status; it.StatusColor = p.StatusColor; it.Checked = p.Selected; } }
        list.Invalidate();
    }

    static int RunLocal(string file, CancellationToken ct) {
        string o;
        if (file.EndsWith(".msi", StringComparison.OrdinalIgnoreCase))
            return Proc.Run(Proc.Sys("msiexec.exe"), "/i \"" + file + "\" /qn /norestart", out o, 3600000, ct);
        var argsFile = file + ".args";
        var a = File.Exists(argsFile) ? File.ReadAllText(argsFile).Trim() : "";
        return Proc.Run(file, a, out o, 3600000, ct);
    }

    // ---------- profili ----------
    void UseProfile(Profile pr) {
        foreach (var p in All()) p.Selected = false;
        foreach (var id in pr.Winget) {
            var p = rec.Concat(extra).FirstOrDefault(x => x.Id.Equals(id, StringComparison.OrdinalIgnoreCase));
            if (p == null) {
                p = new Pkg { Id = id, Name = id.Contains(".") ? id.Substring(id.IndexOf('.') + 1) : id, Cat = "Profilo " + pr.Name, Source = System.Text.RegularExpressions.Regex.IsMatch(id, "^(9[0-9A-Z]{11}|XP[0-9A-Z]{12})$") ? "msstore" : "winget" };
                string v; if (wg.TryGetValue(id, out v)) { p.Installed = true; p.Version = v; }
                extra.Add(p);
            }
            p.Selected = !p.Installed;
        }
        var missing = new List<string>();
        foreach (var l in pr.Local) {
            var f = Catalog.FindLocal(pr, l);
            if (f == null) { missing.Add(l); continue; }
            var p = extra.FirstOrDefault(x => x.LocalFile == f);
            if (p == null) { p = new Pkg { Id = "local:" + f, Name = Path.GetFileNameWithoutExtension(f), Cat = "Profilo " + pr.Name, LocalFile = f, Source = "" }; extra.Add(p); }
            p.Selected = true;
        }
        SetTab(0);
        int n = Chosen().Count;
        Status = "Profilo " + pr.Name + ": " + n + (n == 1 ? " programma da installare" : " programmi da installare") + (missing.Count > 0 ? " · installer locali non trovati: " + string.Join(", ", missing) : "");
    }

    void SaveProfile() {
        var ids = Chosen().Where(p => p.LocalFile == null).Select(p => p.Id).ToList();
        if (ids.Count == 0) return;
        var name = Ask.Text(this, "Nome del profilo", "Es. \"Studio Rossi\" o \"PC per la scuola\"");
        if (string.IsNullOrWhiteSpace(name)) return;
        try {
            var f = Catalog.Save(name, ids.Count + " programmi scelti il " + DateTime.Now.ToString("dd/MM/yyyy"), ids);
            profiles = Catalog.Profiles();
            Status = "Profilo salvato: " + name;
            if (tab == 2) Fill();
        } catch (Exception e) { App.Log(e); MessageBox.Show("Non riesco a salvare il profilo:\n" + e.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }
    void DeleteProfile(Profile pr) {
        if (pr.Origin != "tuo" || pr.File == null) return;
        if (MessageBox.Show("Eliminare il profilo " + pr.Name + "?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        try { File.Delete(pr.File); } catch (Exception e) { App.Log(e); }
        profiles = Catalog.Profiles(); Fill();
    }
}

// piccola finestra per scrivere un nome
public static class Ask {
    public static string Text(IWin32Window owner, string title, string hint) {
        using (var f = new Form { Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false,
                                  ClientSize = new Size(420, 150), BackColor = Th.Surface, ForeColor = Th.Text, Font = Th.F(10f) }) {
            var l = new Label { Text = hint, AutoSize = false, ForeColor = Th.Dim };
            l.SetBounds(20, 16, 380, 22);
            var t = new TextBox { BorderStyle = BorderStyle.FixedSingle, BackColor = Th.Surface2, ForeColor = Th.Text };
            t.SetBounds(20, 44, 380, 28);
            var ok = new Btn { Kind = BtnKind.Primary, Text = "Salva", C1 = Th.C1, C2 = Th.C2 };
            var no = new Btn { Text = "Annulla" };
            ok.SetBounds(196, 96, 100, 38); no.SetBounds(304, 96, 96, 38);
            ok.Click += (s, e) => { f.DialogResult = DialogResult.OK; f.Close(); };
            no.Click += (s, e) => { f.DialogResult = DialogResult.Cancel; f.Close(); };
            t.KeyDown += (s, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; f.DialogResult = DialogResult.OK; f.Close(); } else if (e.KeyCode == Keys.Escape) f.Close(); };
            f.Controls.AddRange(new Control[] { l, t, ok, no });
            return f.ShowDialog(owner) == DialogResult.OK ? t.Text.Trim() : null;
        }
    }
}
