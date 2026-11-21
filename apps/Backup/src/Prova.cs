using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Forms;

// Collaudo automatico (GitHub Actions): "--prova <cartella>" esegue i passi dell'app, salva una schermata
// dopo ciascuno e chiude. Ogni passo può aspettare che il lavoro in sottofondo finisca (Ready).
public static class Prova {
    public class Step { public string Name; public Action Do; public Func<bool> Ready; public int MaxSec = 60; }
    public static readonly List<Step> Steps = new List<Step>();
    public static readonly List<string> Log = new List<string>();

    public static void Attach(Form f, string dir) {
        Directory.CreateDirectory(dir);
        int i = -1; DateTime t0 = DateTime.Now; bool started = false;
        var tm = new Timer { Interval = 500 };
        Action next = null;
        next = () => {
            i++;
            if (i >= Steps.Count) {
                try { File.WriteAllLines(Path.Combine(dir, "prova.txt"), Log.ToArray()); } catch { }
                tm.Stop(); f.Close(); return;
            }
            t0 = DateTime.Now; started = false;
        };
        tm.Tick += (s, e) => {
            if (i < 0) { if ((DateTime.Now - t0).TotalSeconds < 2) return; next(); }
            if (i >= Steps.Count) return;
            var st = Steps[i];
            try {
                if (!started) { started = true; if (st.Do != null) st.Do(); t0 = DateTime.Now; return; }
                bool ready = st.Ready == null || st.Ready();
                double sec = (DateTime.Now - t0).TotalSeconds;
                if ((!ready || sec < 1.5) && sec < st.MaxSec) return;
                Shot(f, Path.Combine(dir, (i + 1).ToString("00") + "-" + st.Name + ".png"));
                Log.Add(st.Name + " | " + (ready ? "ok" : "TEMPO SCADUTO") + " | " + sec.ToString("0") + "s");
            } catch (Exception ex) { Log.Add(st.Name + " | ERRORE | " + ex.Message); App.Log(ex); }
            next();
        };
        f.Shown += (s, e) => { t0 = DateTime.Now; tm.Start(); };
    }
    static void Shot(Form f, string file) {
        using (var bmp = new Bitmap(f.Width, f.Height)) {
            f.DrawToBitmap(bmp, new Rectangle(0, 0, f.Width, f.Height));
            bmp.Save(file, ImageFormat.Png);
        }
    }
}
