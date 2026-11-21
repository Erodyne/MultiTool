using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;

public class Node {
    public string Name, Path;
    public long Size, Files;
    public bool IsDir, IsOther, Denied;
    public DateTime Modified;
    public Node Parent;
    public List<Node> Kids;        // cartelle e i file più grandi di questa cartella
    public int Hidden;             // file non elencati singolarmente (raccolti in "Altri file")
    public long HiddenSize;
}

public class ExtStat { public string Ext; public long Size, Count; }

// Scansione di un disco o di una cartella. Per non occupare troppa memoria su dischi con milioni di file:
// tutte le cartelle, ma per ogni cartella solo i 40 file più grandi (gli altri sommati in "Altri file").
public class Scanner {
    public Node Root;
    public long FilesSeen, DirsSeen, Denied;
    public string Current = "";
    public readonly List<Node> Biggest = new List<Node>();   // i file più grandi di tutta la scansione
    public readonly Dictionary<string, ExtStat> Ext = new Dictionary<string, ExtStat>(StringComparer.OrdinalIgnoreCase);
    const int PerDir = 40, TopN = 500;
    long biggestMin;

    public void Run(string path, CancellationToken ct) {
        Root = new Node { Name = path, Path = path, IsDir = true, Kids = new List<Node>() };
        try { Root.Modified = Directory.GetLastWriteTime(path); } catch { }
        var stack = new Stack<Node>();
        stack.Push(Root);
        var order = new List<Node>();
        while (stack.Count > 0 && !ct.IsCancellationRequested) {
            var d = stack.Pop();
            order.Add(d);
            Current = d.Path;
            var files = new List<Node>();
            try {
                foreach (var e in new DirectoryInfo(d.Path).EnumerateFileSystemInfos("*", SearchOption.TopDirectoryOnly)) {
                    if (ct.IsCancellationRequested) break;
                    var a = e.Attributes;
                    if ((a & FileAttributes.ReparsePoint) != 0) continue; // giunzioni e collegamenti: non contati due volte
                    if ((a & FileAttributes.Directory) != 0) {
                        var n = new Node { Name = e.Name, Path = e.FullName, IsDir = true, Parent = d, Kids = new List<Node>(), Modified = e.LastWriteTime };
                        d.Kids.Add(n); stack.Push(n); DirsSeen++;
                    } else {
                        var fi = (FileInfo)e;
                        long len = fi.Length;
                        FilesSeen++; d.Size += len; d.Files++;
                        var f = new Node { Name = e.Name, Path = e.FullName, Size = len, Parent = d, Modified = fi.LastWriteTime, Files = 1 };
                        files.Add(f);
                        AddExt(fi.Extension, len);
                        AddBiggest(f);
                    }
                }
            } catch (UnauthorizedAccessException) { d.Denied = true; Denied++; }
            catch (Exception) { d.Denied = true; Denied++; }
            if (files.Count > PerDir) {
                files.Sort((x, y) => y.Size.CompareTo(x.Size));
                for (int i = PerDir; i < files.Count; i++) { d.Hidden++; d.HiddenSize += files[i].Size; }
                files.RemoveRange(PerDir, files.Count - PerDir);
            }
            d.Kids.AddRange(files);
        }
        // somme dal basso verso l'alto
        for (int i = order.Count - 1; i >= 0; i--) {
            var d = order[i];
            if (d.Parent != null) { d.Parent.Size += d.Size; d.Parent.Files += d.Files; }
        }
        foreach (var d in order) Finish(d);
        Biggest.Sort((x, y) => y.Size.CompareTo(x.Size));
    }

    static void Finish(Node d) {
        if (d.Hidden > 0) d.Kids.Add(new Node { Name = "Altri " + d.Hidden + " file", Path = d.Path, Size = d.HiddenSize, Files = d.Hidden, Parent = d, IsOther = true });
        d.Kids.Sort((x, y) => y.Size.CompareTo(x.Size));
    }

    void AddExt(string ext, long len) {
        if (string.IsNullOrEmpty(ext)) ext = "(senza estensione)";
        ExtStat s;
        if (!Ext.TryGetValue(ext, out s)) Ext[ext] = s = new ExtStat { Ext = ext.ToLowerInvariant() };
        s.Size += len; s.Count++;
    }
    void AddBiggest(Node f) {
        if (Biggest.Count >= TopN && f.Size <= biggestMin) return;
        Biggest.Add(f);
        if (Biggest.Count > TopN * 2) {
            Biggest.Sort((x, y) => y.Size.CompareTo(x.Size));
            Biggest.RemoveRange(TopN, Biggest.Count - TopN);
            biggestMin = Biggest[Biggest.Count - 1].Size;
        }
    }

    // dopo un'eliminazione: tolgo il nodo e aggiorno le somme
    public void Remove(Node n) {
        var p = n.Parent;
        if (p != null) p.Kids.Remove(n);
        for (var x = p; x != null; x = x.Parent) { x.Size -= n.Size; x.Files -= n.IsDir ? n.Files : 1; }
        Biggest.RemoveAll(b => b == n || b.Path.StartsWith(n.Path + "\\", StringComparison.OrdinalIgnoreCase));
        if (!n.IsDir) {
            ExtStat s; var ext = System.IO.Path.GetExtension(n.Name);
            if (string.IsNullOrEmpty(ext)) ext = "(senza estensione)";
            if (Ext.TryGetValue(ext, out s)) { s.Size -= n.Size; s.Count--; }
        }
    }
}

// Mappa ad albero "squarified": rettangoli con proporzioni il più possibile vicine al quadrato
public static class Squarify {
    public static List<KeyValuePair<Node, System.Drawing.RectangleF>> Layout(List<Node> items, System.Drawing.RectangleF r) {
        var res = new List<KeyValuePair<Node, System.Drawing.RectangleF>>();
        var list = items.Where(x => x.Size > 0).ToList();
        double total = list.Sum(x => (double)x.Size);
        if (total <= 0 || r.Width < 2 || r.Height < 2) return res;
        double scale = r.Width * (double)r.Height / total;
        var areas = list.Select(x => x.Size * scale).ToList();
        int i = 0;
        var rect = r;
        while (i < list.Count) {
            double side = Math.Min(rect.Width, rect.Height);
            int j = i; double sum = 0, worst = double.MaxValue;
            while (j < list.Count) {
                double s2 = sum + areas[j];
                double w = Worst(areas, i, j, s2, side);
                if (w > worst) break;
                worst = w; sum = s2; j++;
            }
            // riga da i a j-1
            if (rect.Width >= rect.Height) {
                float colW = (float)(sum / rect.Height), y = rect.Y;
                for (int k = i; k < j; k++) { float h = (float)(areas[k] / colW); res.Add(new KeyValuePair<Node, System.Drawing.RectangleF>(list[k], new System.Drawing.RectangleF(rect.X, y, colW, h))); y += h; }
                rect = new System.Drawing.RectangleF(rect.X + colW, rect.Y, rect.Width - colW, rect.Height);
            } else {
                float rowH = (float)(sum / rect.Width), x = rect.X;
                for (int k = i; k < j; k++) { float w = (float)(areas[k] / rowH); res.Add(new KeyValuePair<Node, System.Drawing.RectangleF>(list[k], new System.Drawing.RectangleF(x, rect.Y, w, rowH))); x += w; }
                rect = new System.Drawing.RectangleF(rect.X, rect.Y + rowH, rect.Width, rect.Height - rowH);
            }
            i = j;
            if (rect.Width < 1 || rect.Height < 1) break;
        }
        return res;
    }
    static double Worst(List<double> a, int i, int j, double sum, double side) {
        double mx = 0, mn = double.MaxValue;
        for (int k = i; k <= j; k++) { mx = Math.Max(mx, a[k]); mn = Math.Min(mn, a[k]); }
        double s2 = sum * sum, w2 = side * side;
        if (mn <= 0) return double.MaxValue;
        return Math.Max(w2 * mx / s2, s2 / (w2 * mn));
    }
}
