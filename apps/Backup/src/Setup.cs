using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

// Un solo exe che fa anche da installer, come DiskVital:
//   "/S" installa in silenzio (lo usa la Erodyne Suite), "<Nome>-Setup-*.exe" aperto a mano chiede se installare,
//   "--disinstalla [/S]" rimuove. PerUser = installazione per l'utente in %LOCALAPPDATA%\Programs (senza amministratore),
//   altrimenti in Programmi (serve l'amministratore).
public static class Setup {
    public static bool PerUser = true;
    public static string Key = "Erodyne";                 // nome della voce in Uninstall e della cartella
    public static string ExeName = "Erodyne.exe";
    public static Action BeforeInstall, AfterInstall, OnUninstall;

    public static string Dir {
        get {
            return PerUser ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", Key)
                           : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Key);
        }
    }
    public static string Exe { get { return Path.Combine(Dir, ExeName); } }
    static string Me { get { return Path.GetFullPath(Assembly.GetExecutingAssembly().Location); } }
    static string StartLnk { get { return Path.Combine(Environment.GetFolderPath(PerUser ? Environment.SpecialFolder.Programs : Environment.SpecialFolder.CommonPrograms), App.Name + ".lnk"); } }
    static string DesktopLnk { get { return Path.Combine(Environment.GetFolderPath(PerUser ? Environment.SpecialFolder.DesktopDirectory : Environment.SpecialFolder.CommonDesktopDirectory), App.Name + ".lnk"); } }
    static string KeyPath { get { return @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + Key; } }

    public static bool IsInstalledCopy { get { return string.Equals(Me, Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase); } }
    public static bool Installed { get { return File.Exists(Exe); } }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool DeleteFile(string path);

    static RegistryKey Root() {
        return PerUser ? RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Default)
                       : RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, Environment.Is64BitOperatingSystem ? RegistryView.Registry64 : RegistryView.Default);
    }

    public static bool OfferInstall() {
        if (IsInstalledCopy) return false;
        var setupName = App.Name.Replace(" ", "") + "-Setup";
        if (!Path.GetFileName(Me).StartsWith(setupName, StringComparison.OrdinalIgnoreCase)) return false;
        var r = MessageBox.Show("Installare " + App.Name + " " + App.Version + "?\n\n" +
            (PerUser ? "Si installa solo per il tuo utente, senza permessi di amministratore," : "Va in Programmi,") +
            " con collegamenti nel menu Start e sul desktop.\n\nNo = usalo senza installarlo.",
            App.Name, MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
        if (r == DialogResult.Cancel) return true;
        if (r == DialogResult.No) return false;
        if (!Install(false)) return true;
        try { Process.Start(new ProcessStartInfo(Exe) { UseShellExecute = true, WorkingDirectory = Dir }); } catch { }
        return true;
    }

    public static bool Install(bool silent) {
        try {
            if (BeforeInstall != null) BeforeInstall();
            Directory.CreateDirectory(Dir);
            try { File.Delete(Exe + ".old"); } catch { }
            if (!IsInstalledCopy) {
                var tmp = Exe + ".new";
                File.Copy(Me, tmp, true);
                DeleteFile(tmp + ":Zone.Identifier");
                if (File.Exists(Exe)) File.Move(Exe, Exe + ".old"); // un exe aperto si può rinominare, non sovrascrivere
                File.Move(tmp, Exe);
                try { File.Delete(Exe + ".old"); } catch { }
            }
            Shortcut(StartLnk); Shortcut(DesktopLnk);
            using (var b = Root())
            using (var k = b.CreateSubKey(KeyPath)) {
                k.SetValue("DisplayName", App.Name);
                k.SetValue("DisplayVersion", App.Version);
                k.SetValue("Publisher", "Erodyne");
                k.SetValue("DisplayIcon", Exe + ",0");
                k.SetValue("InstallLocation", Dir);
                k.SetValue("UninstallString", "\"" + Exe + "\" --disinstalla");
                k.SetValue("QuietUninstallString", "\"" + Exe + "\" --disinstalla /S");
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                k.SetValue("EstimatedSize", (int)Math.Max(1, new FileInfo(Exe).Length / 1024), RegistryValueKind.DWord);
                k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
            }
            if (AfterInstall != null) AfterInstall();
            return true;
        } catch (Exception e) {
            App.Log(e);
            if (!silent) MessageBox.Show("Installazione non riuscita:\n" + e.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    public static void Uninstall(bool silent) {
        if (!silent && MessageBox.Show("Disinstallare " + App.Name + "?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        bool wipe = !silent && Directory.Exists(App.DataDir) &&
            MessageBox.Show("Eliminare anche le impostazioni di " + App.Name + "?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
        try { if (OnUninstall != null) OnUninstall(); } catch (Exception e) { App.Log(e); }
        try { File.Delete(StartLnk); } catch { }
        try { File.Delete(DesktopLnk); } catch { }
        try { using (var b = Root()) b.DeleteSubKeyTree(KeyPath, false); } catch { }
        if (wipe) try { Directory.Delete(App.DataDir, true); } catch { }
        // la cartella (con l'exe in uso) si cancella dopo la chiusura
        try {
            var cmd = Proc.Sys("cmd.exe");
            Process.Start(new ProcessStartInfo(cmd, "/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"" + Dir + "\"") {
                WindowStyle = ProcessWindowStyle.Hidden, CreateNoWindow = true, UseShellExecute = false, WorkingDirectory = Path.GetTempPath() });
        } catch { }
        if (!silent) MessageBox.Show(App.Name + " è stato disinstallato.", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    static void Shortcut(string lnk) {
        try {
            var t = Type.GetTypeFromProgID("WScript.Shell");
            object sh = Activator.CreateInstance(t);
            try {
                object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { lnk });
                var st = sc.GetType();
                st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { Exe });
                st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { Dir });
                st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { Exe + ",0" });
                st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { App.Description });
                st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
                Marshal.FinalReleaseComObject(sc);
            } finally { Marshal.FinalReleaseComObject(sh); }
        } catch (Exception e) { App.Log(e); }
    }
}
