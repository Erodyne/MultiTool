using System;
using System.Security;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Windows.Forms;

// Backup automatico: attività pianificata dell'utente, con i suoi permessi normali (mai da amministratore).
// Due avvii: all'ora scelta e un po' dopo l'accesso, così un backup saltato (PC spento, disco scollegato) si recupera.
public static class Schedule {
    public static string TaskName {
        get { return "Erodyne Backup - " + Regex.Replace(Environment.UserName, @"[^\w\.\- ]", "_"); }
    }
    public static bool On { get { return Store.GetBool("automatico"); } }
    public static bool Weekly { get { return Store.Get("frequenza") == "settimana"; } }
    public static DayOfWeek Day {
        get { int d; return int.TryParse(Store.Get("giorno"), out d) && d >= 0 && d <= 6 ? (DayOfWeek)d : DayOfWeek.Friday; }
    }
    public static TimeSpan Time {
        get { TimeSpan t; return TimeSpan.TryParse(Store.Get("ora") ?? "13:00", out t) && t < TimeSpan.FromDays(1) ? t : new TimeSpan(13, 0, 0); }
    }
    static readonly string[] DayNames = { "domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato" };
    static readonly string[] DayXml = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    public static string DayName(DayOfWeek d) { return DayNames[(int)d]; }
    public static string Describe() {
        if (!On) return "Disattivato";
        return (Weekly ? "Ogni " + DayName(Day) : "Ogni giorno") + " alle " + new DateTime(Time.Ticks).ToString("HH:mm");
    }

    // vero se è ora di fare il backup (chiamato dall'attività pianificata)
    public static bool Due() {
        var last = Engine.LastOk;
        if (!last.HasValue) return true;
        var every = Weekly ? TimeSpan.FromDays(7) : TimeSpan.FromDays(1);
        var since = DateTime.Now - last.Value;
        if (since.TotalHours < every.TotalHours * 0.9) return false;
        // all'ora stabilita, oppure subito se il backup previsto è stato saltato
        bool timeReached = DateTime.Now.TimeOfDay >= Time - TimeSpan.FromMinutes(10) && (!Weekly || DateTime.Now.DayOfWeek == Day);
        return timeReached || since.TotalHours >= every.TotalHours * 1.5;
    }

    public static string Apply() {
        if (!On) { Tasks.Delete(TaskName); return null; }
        var exe = Setup.Installed ? Setup.Exe : Application.ExecutablePath;
        var user = WindowsIdentity.GetCurrent().Name;
        var start = DateTime.Today.Add(Time).ToString("yyyy-MM-ddTHH:mm:ss");
        var cal = Weekly
            ? "<CalendarTrigger><StartBoundary>" + start + "</StartBoundary><Enabled>true</Enabled><ScheduleByWeek><DaysOfWeek><" + DayXml[(int)Day] + " /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek></CalendarTrigger>"
            : "<CalendarTrigger><StartBoundary>" + start + "</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>";
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n" +
            "<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">" +
            "<RegistrationInfo><Author>Erodyne</Author><Description>Erodyne Backup: copia le cartelle scelte sul disco di backup.</Description></RegistrationInfo>" +
            "<Triggers>" + cal + "<LogonTrigger><Enabled>true</Enabled><UserId>" + SecurityElement.Escape(user) + "</UserId><Delay>PT5M</Delay></LogonTrigger></Triggers>" +
            "<Principals><Principal id=\"Author\"><UserId>" + SecurityElement.Escape(user) + "</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>" +
            "<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>" +
            "<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT12H</ExecutionTimeLimit><Priority>7</Priority>" +
            "<IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings></Settings>" +
            "<Actions Context=\"Author\"><Exec><Command>" + SecurityElement.Escape(exe) + "</Command><Arguments>--auto</Arguments></Exec></Actions></Task>";
        return Tasks.Create(TaskName, xml) ? null : "Non riesco a creare il backup automatico nell'Utilità di pianificazione.";
    }
}
