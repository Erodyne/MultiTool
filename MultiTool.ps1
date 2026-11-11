param([switch]$Auto, [switch]$Backup, [switch]$Uninstall)
# ============================================================
#  MultiTool 2026 - Manutenzione PC
# ============================================================

$AppVersion = '2026.11.11.3'
$ScriptPath = $PSCommandPath
$Root    = Split-Path -Parent $ScriptPath
$Installed = $Root -like "$env:ProgramFiles*"
$Base    = if ($Installed) { Join-Path $env:ProgramData 'MultiTool' } else { $Root }
$InstDir = Join-Path $Base 'Installers'
$ProfDir = Join-Path $Base 'Profili'
$DataDir = Join-Path $Base 'Dati'
foreach ($d in $InstDir, $ProfDir, $DataDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

# --- Elevazione (silenziosa) ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $Auto -and -not $Backup -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`"" + $(if ($Uninstall) { ' -Uninstall' } else { '' }))
    exit
}

# ============================================================
#  Funzioni condivise (UI, runspace e modalità automatica)
# ============================================================
$Helpers = @'

$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Get-WingetPath {
    if ($script:wg) { return $script:wg }
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { $script:wg = $c.Source; return $script:wg }
    $p = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
         Sort-Object FullName -Descending | Select-Object -First 1
    if ($p) { $script:wg = $p.FullName; return $script:wg }
    $u = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $u) { $script:wg = $u; return $u }
    throw 'winget non trovato. Installa "Programma di installazione app" dal Microsoft Store.'
}

function Invoke-Hidden([string]$File, [string]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File; $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $e = $p.StandardError.ReadToEndAsync()
    $o = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $o; Err = $e.Result }
}

function Invoke-Live([string]$File, [string]$Arguments, [Text.Encoding]$Enc, [scriptblock]$OnLine) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File; $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Enc
    $p = [Diagnostics.Process]::Start($psi)
    $null = $p.StandardError.ReadToEndAsync()
    $all = New-Object Text.StringBuilder
    $cur = New-Object Text.StringBuilder
    $buf = New-Object char[] 1024
    while (($n = $p.StandardOutput.Read($buf, 0, 1024)) -gt 0) {
        [void]$all.Append($buf, 0, $n)
        for ($i = 0; $i -lt $n; $i++) {
            $ch = $buf[$i]
            if ($ch -eq [char]13 -or $ch -eq [char]10) {
                $l = $cur.ToString().Trim()
                if ($l) { & $OnLine $l }
                [void]$cur.Clear()
            } elseif ($ch -ne [char]0) { [void]$cur.Append($ch) }
        }
    }
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $all.ToString() }
}

function Get-Cut([string]$l, [int]$a, [int]$b) {
    if ($a -ge $l.Length) { return '' }
    if ($b -lt 0 -or $b -gt $l.Length) { return $l.Substring($a).Trim() }
    return $l.Substring($a, $b - $a).Trim()
}

function ConvertFrom-WingetTable([string]$Text) {
    $lines = $Text -split "`n" | ForEach-Object { ($_ -split "`r")[-1].TrimEnd() }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^-{20,}$') { continue }
        $cols = @([regex]::Matches($lines[$i - 1], '\S+') | ForEach-Object { $_.Index })
        if ($cols.Count -lt 3) { continue }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $l = $lines[$j]
            if ([string]::IsNullOrWhiteSpace($l) -or $l.Length -le $cols[2]) { break }
            $cells = @()
            for ($k = 0; $k -lt $cols.Count; $k++) {
                $end = if ($k + 1 -lt $cols.Count) { $cols[$k + 1] } else { -1 }
                $cells += Get-Cut $l $cols[$k] $end
            }
            if ($cells[1] -notmatch '^\S+$') { continue }
            [pscustomobject]@{ Cols = $cells }
        }
    }
}

function Invoke-Winget([string]$Verb, [string]$Id, [string]$Source, $It) {
    $a = "$Verb --id `"$Id`" --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
    if ($Verb -eq 'upgrade') { $a += ' --include-unknown' }
    if ($Source) { $a += " --source $Source" }
    if (-not $It) { return Invoke-Hidden (Get-WingetPath) $a }
    $cb = {
        param($l)
        $m = [regex]::Match($l, '([\d\.,]+)\s*([KMG]B)\s*/\s*([\d\.,]+)\s*([KMG]B)')
        if ($m.Success) {
            $mul = @{ KB = 1KB; MB = 1MB; GB = 1GB }
            $x = [double]($m.Groups[1].Value -replace ',', '.') * $mul[$m.Groups[2].Value]
            $y = [double]($m.Groups[3].Value -replace ',', '.') * $mul[$m.Groups[4].Value]
            if ($y -gt 0) { $It.Status = 'Download {0}%' -f [int]($x / $y * 100) }
            return
        }
        $m = [regex]::Match($l, '(\d{1,3})\s*%')
        if ($m.Success) { $It.Status = "In corso $($m.Groups[1].Value)%" ; return }
        if ($l -match 'install|Install') { $It.Status = 'Installazione…' }
    }
    Invoke-Live (Get-WingetPath) $a ([Text.Encoding]::UTF8) $cb
}

function Get-WingetResult([int]$Code, [string]$OkText) {
    if ($Code -eq 0) { return 'ok', $OkText }
    $hex = '0x{0:X8}' -f $Code
    switch ($hex) {
        '0x8A15002B' { return 'ok', 'Già aggiornato' }
        '0x8A150061' { return 'ok', 'Già installato' }
        '0x8A150109' { $sync.Reboot = $true; return 'ok', 'Riavvio richiesto' }
        '0x8A150014' { return 'err', 'Non trovato' }
    }
    if ($Code -in 3010, 1641) { $sync.Reboot = $true; return 'ok', 'Riavvio richiesto' }
    return 'err', "Errore $hex"
}

function Write-ErrLog([string]$Msg) {
    try {
        $d = Join-Path $DataDir 'Logs'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Add-Content (Join-Path $d 'errori.log') ("{0}  {1}" -f (Get-Date -Format 's'), $Msg) -Encoding UTF8
    } catch {}
}

function Set-It($it, [string]$kind, [string]$text) { $it.StatusKind = $kind; $it.Status = $text }

function Set-ExitResult($it, $code, [string]$okText) {
    if ($code -eq 0)              { Set-It $it 'ok' $okText }
    elseif ($code -in 3010, 1641) { $sync.Reboot = $true; Set-It $it 'ok' 'Riavvio richiesto' }
    else                          { Set-It $it 'err' "Codice $code" }
}

function Invoke-Each($items, [scriptblock]$Body, [string]$Verb) {
    foreach ($it in $items) {
        if ($sync.Cancel) { Set-It $it 'skip' 'Annullato'; continue }
        $sync.Status = "$Verb $($it.Name)…"
        Set-It $it 'run' 'In corso…'
        try { & $Body $it } catch { Set-It $it 'err' 'Errore'; $it.Sub = $_.Exception.Message; Write-ErrLog "$area / $($it.Name): $($_.Exception.Message)" }
        Add-History $area $it.Name $it.Status $it.StatusKind
        $sync.Done++
    }
}

function New-Row([hashtable]$p) {
    $d = @{ Name = ''; Sub = ''; C1 = ''; C2 = ''; Tag = ''; TagKind = 'none'; Key = ''; Data = $null
            Selected = $false; Checkable = $true; Status = ''; StatusKind = 'none'; Arrow = $false; Glyph = '' }
    foreach ($k in $p.Keys) { if ($null -ne $p[$k]) { $d[$k] = $p[$k] } }
    $d
}

function Format-Size([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) }
    elseif ($b -gt 0) { '{0:N0} KB' -f ($b / 1KB) } else { '0 KB' }
}

function Read-Json([string]$Name, $Default) {
    $p = Join-Path $DataDir $Name
    if (Test-Path $p) { try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
    $Default
}
function Save-Json([string]$Name, $Obj) {
    ConvertTo-Json -InputObject $Obj -Depth 5 | Set-Content (Join-Path $DataDir $Name) -Encoding UTF8
}
function Read-Exclusions { @(@(Read-Json 'exclusions.json' @()) | Where-Object { $_ }) }

function Get-Settings {
    $s = Read-Json 'settings.json' $null
    if (-not $s) { $s = [pscustomobject]@{} }
    $def = @{ Restore = $true; AutoEnabled = $false; AutoDay = 'Sunday'; AutoTime = '12:00'; Theme = 'dark'; Tray = $true; UpdateUrl = 'https://raw.githubusercontent.com/Erodyne/MultiTool/main'
              WinL = $null; WinT = $null; WinW = $null; WinH = $null; WinMax = $false; Lhm = $false
              ShopName = ''; ShopPhone = ''; ShopEmail = ''; ShopWeb = ''; ShopLogo = ''; WarrantyMonths = 24
              BackupDest = ''; LastBackup = ''; BackupAuto = $false; BackupTime = '13:00'; SensLog = $false; Lang = 'it'; Prefetch = $true }
    foreach ($k in $def.Keys) { if (-not ($s.PSObject.Properties.Name -contains $k)) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $def[$k] -Force } }
    $s
}

function Add-History([string]$Area, [string]$Name, [string]$Result, [string]$Kind) {
    $line = [pscustomobject]@{ Time = (Get-Date).ToString('s'); Area = $Area; Name = $Name; Result = $Result; Kind = $Kind } | ConvertTo-Json -Compress
    try { Add-Content -Path (Join-Path $DataDir 'history.jsonl') -Value $line -Encoding UTF8 } catch {}
}

function New-RestorePoint([string]$Desc) {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = (Get-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    try {
        Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $true
    } catch { $false }
    finally {
        if ($null -eq $old) { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $old -Type DWord -ErrorAction SilentlyContinue }
    }
}

function Test-PendingReboot {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Start-StoreScan {
    try {
        Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
            Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
    } catch {}
}

function Run-Wait([string]$File, [string]$Arguments, [string]$Dir, [string]$Style) {
    if (-not $Dir -or -not (Test-Path $Dir)) { $Dir = $env:SystemRoot }
    $p = if ($Arguments) { Start-Process -FilePath $File -ArgumentList $Arguments -WorkingDirectory $Dir -WindowStyle $Style -PassThru }
         else            { Start-Process -FilePath $File -WorkingDirectory $Dir -WindowStyle $Style -PassThru }
    $null = $p.Handle
    $p.WaitForExit()
    if ($null -eq $p.ExitCode) { 0 } else { $p.ExitCode }
}

function Split-CommandLine([string]$c) {
    $c = $c.Trim()
    if ($c.StartsWith('"')) {
        $e = $c.IndexOf('"', 1)
        return $c.Substring(1, $e - 1), $c.Substring($e + 1).Trim()
    }
    $m = [regex]::Match($c, '^(.+?\.exe)\s*(.*)$', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value, $m.Groups[2].Value }
    return $c, ''
}

function Install-Local([string]$Path, [bool]$Silent) {
    $dir = Split-Path $Path
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    $af  = "$Path.args"
    $ua  = if (Test-Path $af) { (Get-Content $af -Raw).Trim() } else { $null }
    switch -Regex ($ext) {
        '^\.msi$' {
            $a = "/i `"$Path`""
            if ($ua) { $a += " $ua" } elseif ($Silent) { $a += ' /qn /norestart' }
            return Run-Wait 'msiexec.exe' $a $dir 'Normal'
        }
        '^\.(msix|msixbundle|appx|appxbundle)$' { Add-AppxPackage -Path $Path -ErrorAction Stop; return 0 }
        '^\.(bat|cmd)$' { return Run-Wait 'cmd.exe' "/c `"$Path`"" $dir $(if ($Silent) { 'Hidden' } else { 'Normal' }) }
        default { return Run-Wait $Path $(if ($Silent -and $ua) { $ua } else { '' }) $dir 'Normal' }
    }
}

function Install-WU($items, [string]$Type) {
    $s = New-Object -ComObject Microsoft.Update.Session
    $s.ClientApplicationID = 'MultiTool'
    $sync.Status = 'Preparo gli aggiornamenti selezionati…'
    $sr = $s.CreateUpdateSearcher(); $sr.ServerSelection = 2; $sr.Online = $true
    $res = $sr.Search("IsInstalled=0 and IsHidden=0 and Type='$Type'")
    $map = @{}
    foreach ($u in $res.Updates) { $map[$u.Identity.UpdateID] = $u }
    Invoke-Each $items {
        param($it)
        $u = $map[$it.Key]
        if (-not $u) { Set-It $it 'err' 'Non più disponibile'; return }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        $c = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$c.Add($u)
        Set-It $it 'run' 'Download…'
        $d = $s.CreateUpdateDownloader(); $d.Updates = $c; [void]$d.Download()
        Set-It $it 'run' 'Installazione…'
        $in = $s.CreateUpdateInstaller(); $in.Updates = $c; $r = $in.Install()
        if ($r.RebootRequired) { $sync.Reboot = $true }
        if ($r.ResultCode -in 2, 3) { Set-It $it 'ok' $(if ($r.RebootRequired) { 'Riavvio richiesto' } else { 'Installato' }) }
        else { Set-It $it 'err' "Esito $($r.ResultCode)" }
    } 'Installo'
}

function Get-DirSize($Paths, [int]$MinAgeHours = 0) {
    $s = 0; $cut = (Get-Date).AddHours(-$MinAgeHours)
    foreach ($p in $Paths) {
        if (Test-Path $p) {
            $s += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue |
                   Where-Object { $MinAgeHours -eq 0 -or $_.LastWriteTime -lt $cut } | Measure-Object Length -Sum).Sum
        }
    }
    [double]$s
}
function Remove-Items($Paths, [int]$MinAgeHours = 0) {
    $cut = (Get-Date).AddHours(-$MinAgeHours)
    foreach ($p in $Paths) {
        if (-not (Test-Path $p)) { continue }
        if ($MinAgeHours -eq 0) { Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; continue }
        Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem $p -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue) } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-CleanTarget($t) {
    $before = if ($t.Id -eq 'recycle') { Get-RecycleSize } else { Get-DirSize $t.Paths $t.Age }
    switch ($t.Id) {
        'recycle' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        'wu' {
            Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
            Remove-Items $t.Paths
            Start-Service wuauserv, bits -ErrorAction SilentlyContinue
        }
        'do' { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { Remove-Items $t.Paths } }
        default { Remove-Items $t.Paths $t.Age }
    }
    $after = if ($t.Id -eq 'recycle') { Get-RecycleSize } else { Get-DirSize $t.Paths $t.Age }
    [pscustomobject]@{ Freed = [Math]::Max(0, $before - $after); After = $after }
}
function Get-RecycleSize {
    $s = 0
    try { foreach ($i in (New-Object -ComObject Shell.Application).Namespace(10).Items()) { $s += [double]$i.ExtendedProperty('Size') } } catch {}
    $s
}
function Get-CleanTargets {
    @(
        @{ Id = 'tmpuser'; Name = 'File temporanei utente';      Def = $true;  Age = 24; Desc = "$env:TEMP  ·  esclusi quelli delle ultime 24 ore"; Paths = @($env:TEMP) }
        @{ Id = 'tmpwin';  Name = 'File temporanei di Windows';   Def = $true;  Age = 24; Desc = "$env:SystemRoot\Temp  ·  esclusi quelli delle ultime 24 ore"; Paths = @("$env:SystemRoot\Temp") }
        @{ Id = 'wu';      Name = 'Cache di Windows Update';      Def = $true;  Desc = 'Pacchetti di aggiornamento già installati'; Paths = @("$env:SystemRoot\SoftwareDistribution\Download") }
        @{ Id = 'do';      Name = 'Ottimizzazione recapito';      Def = $true;  Desc = 'Cache di condivisione aggiornamenti'; Paths = @("$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") }
        @{ Id = 'wer';     Name = 'Segnalazioni errori';          Def = $true;  Desc = 'Report di errore di Windows'; Paths = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue") }
        @{ Id = 'dump';    Name = 'Dump di arresto anomalo';      Def = $true;  Desc = 'Minidump e crash dump delle app'; Paths = @("$env:SystemRoot\Minidump", "$env:LOCALAPPDATA\CrashDumps") }
        @{ Id = 'thumb';   Name = 'Cache miniature';              Def = $false; Desc = 'Verrà ricreata automaticamente'; Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db") }
        @{ Id = 'recycle'; Name = 'Cestino';                      Def = $false; Desc = 'Svuota definitivamente il cestino'; Paths = @() }
    )
}


function Get-PrivacyTweaks {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    @(
        @{ Id = 'tel';  Name = 'Telemetria al minimo'; Desc = 'Invia a Microsoft solo i dati diagnostici indispensabili'
           Reg = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; V = 0 }) }
        @{ Id = 'ads';  Name = 'ID pubblicità disattivato'; Desc = 'Le app non usano il tuo ID per gli annunci personalizzati'
           Reg = @(@{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; V = 0 }) }
        @{ Id = 'tail'; Name = 'Esperienze personalizzate disattivate'; Desc = 'Niente suggerimenti basati sui tuoi dati diagnostici'
           Reg = @(@{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; N = 'TailoredExperiencesWithDiagnosticDataEnabled'; V = 0 }) }
        @{ Id = 'sugg'; Name = 'Niente app promosse e suggerimenti in Start'; Desc = 'Blocca le app installate in automatico e i suggerimenti'
           Reg = @(@{ P = $cdm; N = 'SubscribedContent-338388Enabled'; V = 0 }, @{ P = $cdm; N = 'SubscribedContent-338389Enabled'; V = 0 },
                   @{ P = $cdm; N = 'SystemPaneSuggestionsEnabled'; V = 0 }, @{ P = $cdm; N = 'SilentInstalledAppsEnabled'; V = 0 }, @{ P = $cdm; N = 'SoftLandingEnabled'; V = 0 }) }
        @{ Id = 'lock'; Name = 'Niente pubblicità nella schermata di blocco'; Desc = 'Disattiva consigli e curiosità sulla schermata di blocco'
           Reg = @(@{ P = $cdm; N = 'RotatingLockScreenOverlayEnabled'; V = 0 }, @{ P = $cdm; N = 'SubscribedContent-338387Enabled'; V = 0 }) }
        @{ Id = 'act';  Name = 'Cronologia attività disattivata'; Desc = 'Windows non registra né invia le attività svolte'
           Reg = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'PublishUserActivities'; V = 0 },
                   @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'UploadUserActivities'; V = 0 }) }
        @{ Id = 'bing'; Name = 'Niente risultati Bing nella ricerca di Start'; Desc = 'La ricerca mostra solo file e app del PC (riavvio di Esplora risorse)'
           Reg = @(@{ P = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; N = 'DisableSearchBoxSuggestions'; V = 1 }) }
        @{ Id = 'fb';   Name = 'Nessuna richiesta di feedback'; Desc = 'Windows non chiede più valutazioni e opinioni'
           Reg = @(@{ P = 'HKCU:\Software\Microsoft\Siuf\Rules'; N = 'NumberOfSIUFInPeriod'; V = 0 }) }
    )
}
function Get-BloatApps {
    @(
        @{ N = 'Microsoft.BingNews'; T = 'Notizie (Microsoft News)' }
        @{ N = 'Microsoft.GetHelp'; T = 'Assistenza' }
        @{ N = 'Microsoft.Getstarted'; T = 'Suggerimenti' }
        @{ N = 'Microsoft.MicrosoftSolitaireCollection'; T = 'Solitaire Collection' }
        @{ N = 'Microsoft.People'; T = 'Contatti' }
        @{ N = 'Microsoft.WindowsFeedbackHub'; T = 'Hub di Feedback' }
        @{ N = 'Microsoft.MicrosoftOfficeHub'; T = 'Microsoft 365 (Office) app promozionale' }
        @{ N = 'Clipchamp.Clipchamp'; T = 'Clipchamp' }
        @{ N = 'Microsoft.549981C3F5F10'; T = 'Cortana' }
        @{ N = 'Microsoft.BingSearch'; T = 'Ricerca Bing' }
        @{ N = 'Microsoft.PowerAutomateDesktop'; T = 'Power Automate' }
        @{ N = 'Microsoft.ZuneVideo'; T = 'Film e TV' }
        @{ N = 'king.com.*'; T = 'Giochi King (Candy Crush…)' }
        @{ N = '*Disney*'; T = 'Disney+' }
    )
}
function Read-PrivacyBackup { $b = Read-Json 'privacy-backup.json' $null; $h = @{}; if ($b) { foreach ($p in $b.PSObject.Properties) { $h[$p.Name] = $p.Value } }; $h }
function Set-Tweak($t, [bool]$Apply) {
    $bk = Read-PrivacyBackup
    foreach ($r in $t.Reg) {
        $key = "$($r.P)|$($r.N)"
        $cur = Get-ItemProperty $r.P -Name $r.N -ErrorAction SilentlyContinue
        if ($Apply) {
            if (-not $bk.ContainsKey($key)) { $bk[$key] = @{ Exists = ($null -ne $cur); Value = $(if ($cur) { $cur.($r.N) } else { $null }) } }
            if (-not (Test-Path $r.P)) { New-Item -Path $r.P -Force | Out-Null }
            Set-ItemProperty -Path $r.P -Name $r.N -Value $r.V -Type DWord
        } else {
            $b = $bk[$key]
            if ($b -and $b.Exists) { Set-ItemProperty -Path $r.P -Name $r.N -Value $b.Value -Type DWord }
            else { Remove-ItemProperty -Path $r.P -Name $r.N -ErrorAction SilentlyContinue }
            $bk.Remove($key)
        }
    }
    Save-Json 'privacy-backup.json' $bk
}
function Test-Tweak($t) {
    foreach ($r in $t.Reg) {
        $v = (Get-ItemProperty $r.P -Name $r.N -ErrorAction SilentlyContinue).($r.N)
        if ($v -ne $r.V) { return $false }
    }
    $true
}
function Wait-Uninstallers([datetime]$Since, [int]$Minutes = 20) {
    $end = (Get-Date).AddMinutes($Minutes)
    Start-Sleep -Seconds 2
    while ((Get-Date) -lt $end) {
        $p = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            ($_.ProcessName -match '^(Au_|Un_A|Un_|unins\d*|_iu14D2N|uninstall|uninst|Uninstaller)') -or
            ($_.Path -and $_.Path -like "$env:TEMP*" -and $_.StartTime -ge $Since) }
        if (-not $p) { break }
        Start-Sleep -Seconds 2
    }
}

function Find-LhmDll {
    foreach ($r in "$env:LOCALAPPDATA\Microsoft\WinGet\Packages", "$env:ProgramFiles\WinGet\Packages", "$env:ProgramFiles\LibreHardwareMonitor") {
        if (-not (Test-Path $r)) { continue }
        $f = Get-ChildItem $r -Recurse -Filter 'LibreHardwareMonitorLib.dll' -ErrorAction SilentlyContinue |
             Sort-Object @{ e = { if ($_.FullName -match 'net4') { 0 } elseif ($_.FullName -match 'net\d') { 2 } else { 1 } } }, @{ e = { $_.LastWriteTime }; Descending = $true } |
             Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    $null
}

function Get-HwInventory {
    $cards = New-Object System.Collections.ArrayList
    function Add-Card([string]$T, [int]$G, $Rows) {
        $rr = @($Rows | Where-Object { $_ -and ([string]$_.V).Trim() })
        if ($rr.Count) { [void]$cards.Add(@{ T = $T; G = [string][char]$G; Rows = $rr }) }
    }
    function Row([string]$L, $V) { [pscustomobject]@{ L = $L; V = ([string]$V).Trim() } }
    function Dt($d) { if ($d) { try { ([datetime]$d).ToString('dd/MM/yyyy') } catch { [string]$d } } }
    function Gb($b) { if ($b) { Format-Size ([double]$b) } }

    $sync.HwStatus = 'Sistema…'
    $cs = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem; $bios = Get-CimInstance Win32_BIOS
    $bb = Get-CimInstance Win32_BaseBoard; $enc = Get-CimInstance Win32_SystemEnclosure | Select-Object -First 1
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $chassis = switch (@($enc.ChassisTypes)[0]) { { $_ -in 3, 4, 5, 6, 7, 15, 16 } { 'Desktop' } { $_ -in 8, 9, 10, 14, 31, 32 } { 'Portatile' } { $_ -in 13 } { 'All-in-one' } { $_ -in 30 } { 'Tablet' } default { '' } }
    Add-Card 'Sistema' 0xE7F8 @(
        (Row 'Produttore' $cs.Manufacturer); (Row 'Modello' $cs.Model); (Row 'Famiglia' $cs.SystemFamily); (Row 'Tipo' $chassis)
        (Row 'Numero di serie' $bios.SerialNumber); (Row 'Nome PC' $env:COMPUTERNAME)
        (Row 'Sistema operativo' "$($os.Caption) $($cv.DisplayVersion)"); (Row 'Build' "$($cv.CurrentBuildNumber).$($cv.UBR)  ·  $($os.OSArchitecture)")
        (Row 'Installato il' (Dt $os.InstallDate)))

    $sync.HwStatus = 'Scheda madre e firmware…'
    $sb = 'UEFI'
    try { $sb = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'UEFI  ·  Secure Boot attivo' } else { 'UEFI  ·  Secure Boot disattivo' } }
    catch { if ($_.Exception.Message -match 'not supported|non supportat') { $sb = 'Legacy BIOS' } }
    $tpm = ''
    try {
        $t = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm -ErrorAction Stop
        $tpm = if ($t) { "Presente  ·  versione $(([string]$t.SpecVersion -split ',')[0])  ·  " + $(if ($t.IsEnabled_InitialValue) { 'attivo' } else { 'disattivo' }) } else { 'Assente' }
    } catch {}
    Add-Card 'Scheda madre e firmware' 0xE964 @(
        (Row 'Scheda madre' "$($bb.Manufacturer) $($bb.Product)"); (Row 'Revisione' $bb.Version); (Row 'Seriale scheda' $bb.SerialNumber)
        (Row 'BIOS / UEFI' "$($bios.Manufacturer)  ·  versione $($bios.SMBIOSBIOSVersion)"); (Row 'Data firmware' (Dt $bios.ReleaseDate))
        (Row 'SMBIOS' "$($bios.SMBIOSMajorVersion).$($bios.SMBIOSMinorVersion)"); (Row 'Avvio' $sb); (Row 'TPM' $tpm))

    $sync.HwStatus = 'Processore…'
    foreach ($c in Get-CimInstance Win32_Processor) {
        Add-Card 'Processore' 0xE950 @(
            (Row 'Modello' ($c.Name -replace '\s+', ' ')); (Row 'Produttore' $c.Manufacturer)
            (Row 'Core / thread' "$($c.NumberOfCores) core  ·  $($c.NumberOfLogicalProcessors) thread"); (Row 'Frequenza base' "$([math]::Round($c.MaxClockSpeed / 1000, 2)) GHz")
            (Row 'Cache L2 / L3' "$([math]::Round($c.L2CacheSize / 1024, 1)) MB  ·  $([math]::Round($c.L3CacheSize / 1024, 1)) MB"); (Row 'Socket' $c.SocketDesignation)
            (Row 'Virtualizzazione' $(if ($c.VirtualizationFirmwareEnabled) { 'Attiva nel firmware' } else { 'Disattiva nel firmware' })); (Row 'Revisione' "$($c.Caption)"))
    }

    $sync.HwStatus = 'Memoria…'
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
    $rows = @((Row 'Totale' (Gb $cs.TotalPhysicalMemory)), (Row 'Slot occupati' "$($mods.Count) di $slots"))
    foreach ($m in $mods) {
        $type = switch ([int]$m.SMBIOSMemoryType) { 20 { 'DDR' } 21 { 'DDR2' } 24 { 'DDR3' } 26 { 'DDR4' } 30 { 'LPDDR4' } 34 { 'DDR5' } 35 { 'LPDDR5' } default { '' } }
        $spd = if ($m.ConfiguredClockSpeed) { $m.ConfiguredClockSpeed } else { $m.Speed }
        $rows += Row $(if ($m.DeviceLocator) { $m.DeviceLocator } else { 'Modulo' }) ("$(Gb $m.Capacity) $type $spd MT/s  ·  $($m.Manufacturer) $($m.PartNumber)".Trim())
    }
    Add-Card 'Memoria RAM' 0xE964 $rows

    $sync.HwStatus = 'Scheda video…'
    $cls = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($g in Get-CimInstance Win32_VideoController) {
        $vram = $null
        foreach ($k in Get-ChildItem $cls -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p.DriverDesc -eq $g.Name -and $p.'HardwareInformation.qwMemorySize') { $vram = [double]$p.'HardwareInformation.qwMemorySize'; break }
        }
        if (-not $vram -and $g.AdapterRAM -gt 0) { $vram = [double][uint32]$g.AdapterRAM }
        Add-Card 'Scheda video' 0xE7F4 @(
            (Row 'Modello' $g.Name); (Row 'Produttore' $g.AdapterCompatibility); (Row 'Memoria video' (Gb $vram))
            (Row 'Driver' "$($g.DriverVersion)  ·  del $(Dt $g.DriverDate)")
            (Row 'Risoluzione' $(if ($g.CurrentHorizontalResolution) { "$($g.CurrentHorizontalResolution) × $($g.CurrentVerticalResolution) a $($g.CurrentRefreshRate) Hz" })))
    }

    $sync.HwStatus = 'Dischi…'
    foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId) {
        $rc = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $type = (@($(if ($d.MediaType -and "$($d.MediaType)" -ne 'Unspecified') { $d.MediaType }), $d.BusType) | Where-Object { $_ }) -join ' · '
        $h = switch ("$($d.HealthStatus)") { 'Healthy' { 'Integro' } 'Warning' { 'Attenzione' } 'Unhealthy' { 'Guasto' } default { "$($d.HealthStatus)" } }
        Add-Card "Disco $($d.DeviceId)" 0xEDA2 @(
            (Row 'Modello' $d.FriendlyName); (Row 'Produttore' $d.Manufacturer); (Row 'Tipo' $type); (Row 'Capacità' (Gb $d.Size))
            (Row 'Firmware' $d.FirmwareVersion); (Row 'Numero di serie' $d.SerialNumber); (Row 'Stato' $h)
            (Row 'Temperatura' $(if ($rc.Temperature) { "$($rc.Temperature) °C (max $($rc.TemperatureMax) °C)" })); (Row 'Usura' $(if ($null -ne $rc.Wear) { "$($rc.Wear)%" }))
            (Row 'Ore di accensione' $rc.PowerOnHours); (Row 'Cicli di accensione' $rc.StartStopCycleCount)
            (Row 'Errori di lettura' $(if ($null -ne $rc.ReadErrorsUncorrected) { "$($rc.ReadErrorsUncorrected) non corretti" })))
    }

    $sync.HwStatus = 'Monitor…'
    try {
        $dec = { param($a) (-join (@($a) | Where-Object { $_ } | ForEach-Object { [char]$_ })).Trim() }
        $bp = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue)
        foreach ($m in Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop) {
            $b = $bp | Where-Object { $_.InstanceName -eq $m.InstanceName } | Select-Object -First 1
            $inch = if ($b -and $b.MaxHorizontalImageSize) { [math]::Round([math]::Sqrt([math]::Pow($b.MaxHorizontalImageSize, 2) + [math]::Pow($b.MaxVerticalImageSize, 2)) / 2.54, 1) }
            Add-Card 'Monitor' 0xE7F4 @(
                (Row 'Modello' (& $dec $m.UserFriendlyName)); (Row 'Produttore (codice)' (& $dec $m.ManufacturerName)); (Row 'Codice prodotto' (& $dec $m.ProductCodeID))
                (Row 'Numero di serie' (& $dec $m.SerialNumberID)); (Row 'Anno di produzione' $m.YearOfManufacture); (Row 'Diagonale' $(if ($inch) { "$inch pollici" })))
        }
    } catch {}

    $sync.HwStatus = 'Rete e audio…'
    $rows = @()
    foreach ($n in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object Name) {
        $rows += Row $n.Name ("$($n.InterfaceDescription)  ·  $(if ($n.Status -eq 'Up') { $n.LinkSpeed } else { 'non connesso' })  ·  MAC $($n.MacAddress)  ·  driver $($n.DriverVersionString)")
    }
    Add-Card 'Rete' 0xE701 $rows
    $rows = @(); foreach ($a in Get-CimInstance Win32_SoundDevice) { $rows += Row $a.Manufacturer $a.Name }
    Add-Card 'Audio' 0xE767 $rows

    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($b) {
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
        $st = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
        $cyc = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Select-Object -First 1).CycleCount
        $chem = switch ([int]$b.Chemistry) { 3 { 'Piombo' } 4 { 'Nichel-cadmio' } 5 { 'Nichel-metallo idruro' } 6 { 'Ioni di litio' } 8 { 'Litio-polimero' } default { '' } }
        Add-Card 'Batteria' 0xE83F @(
            (Row 'Modello' $b.Name); (Row 'Produttore' $st.ManufactureName); (Row 'Chimica' $chem); (Row 'Carica' "$($b.EstimatedChargeRemaining)%")
            (Row 'Capacità di progetto' $(if ($st.DesignedCapacity) { "$($st.DesignedCapacity) mWh" })); (Row 'Capacità attuale' $(if ($full) { "$full mWh" }))
            (Row 'Salute' $(if ($full -and $st.DesignedCapacity) { "$([int]([math]::Min(100, $full / $st.DesignedCapacity * 100)))%" })); (Row 'Cicli di carica' $cyc))
    }
    $cards
}

function Invoke-MaintStep($it) {
    switch ($it.Key) {
        'upd' {
            $excl = Read-Exclusions
            $it.Sub = 'Cerco aggiornamenti…'
            Start-StoreScan
            $r = Invoke-Hidden (Get-WingetPath) 'upgrade --include-unknown --accept-source-agreements --disable-interactivity'
            $list = @(ConvertFrom-WingetTable $r.Out | Where-Object { $_.Cols.Count -ge 4 -and $excl -notcontains $_.Cols[1] -and $_.Cols[1] -notmatch '…$' })
            $ok = 0; $err = 0; $i = 0
            foreach ($t in $list) {
                if ($sync.Cancel) { break }
                $i++; $c = $t.Cols
                $it.Sub = "($i/$($list.Count)) $($c[0])"
                $x = Invoke-Winget 'upgrade' $c[1] $(if ($c.Count -ge 5) { $c[4] } else { '' })
                $k, $txt = Get-WingetResult $x.Code 'Aggiornato'
                Add-History $area $c[0] $txt $k
                if ($k -eq 'ok') { $ok++ } else { $err++ }
            }
            $it.Sub = if ($list.Count) { "$ok aggiornati, $err errori" } else { 'Nessun aggiornamento disponibile' }
            if ($err) { Set-It $it 'err' "$err errori" } else { Set-It $it 'ok' "$ok aggiornati" }
        }
        'wu' {
            $it.Sub = 'Cerco aggiornamenti di Windows…'
            $s = New-Object -ComObject Microsoft.Update.Session; $s.ClientApplicationID = 'MultiTool'
            $sr = $s.CreateUpdateSearcher(); $sr.ServerSelection = 2; $sr.Online = $true
            $c = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $sr.Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates) {
                if ($u.BrowseOnly) { continue }
                if (-not $u.EulaAccepted) { $u.AcceptEula() }
                [void]$c.Add($u)
            }
            if ($c.Count -eq 0) { $it.Sub = 'Windows è aggiornato'; Set-It $it 'ok' 'Nessuno'; return }
            $it.Sub = "Scarico $($c.Count) aggiornamenti…"
            $d = $s.CreateUpdateDownloader(); $d.Updates = $c; [void]$d.Download()
            $it.Sub = "Installo $($c.Count) aggiornamenti…"
            $in = $s.CreateUpdateInstaller(); $in.Updates = $c; $r = $in.Install()
            $ok = 0; for ($i = 0; $i -lt $c.Count; $i++) { if ($r.GetUpdateResult($i).ResultCode -in 2, 3) { $ok++ } }
            if ($r.RebootRequired) { $sync.Reboot = $true }
            $it.Sub = "$ok di $($c.Count) installati" + $(if ($r.RebootRequired) { '  ·  riavvio richiesto' } else { '' })
            if ($ok -lt $c.Count) { Set-It $it 'err' "$($c.Count - $ok) errori" } else { Set-It $it 'ok' "$ok installati" }
        }
        'clean' {
            $tot = 0
            foreach ($t in Get-CleanTargets | Where-Object { $_.Def }) { $it.Sub = "Pulisco: $($t.Name)…"; $tot += (Invoke-CleanTarget $t).Freed }
            $it.Sub = "Spazio liberato: $(Format-Size $tot)"
            Set-It $it 'ok' "Liberati $(Format-Size $tot)"
        }
        'drv' {
            $n = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue).Count
            $it.Sub = if ($n) { "$n dispositivi con problemi: apri la sezione Driver" } else { 'Nessun dispositivo con problemi' }
            if ($n) { Set-It $it 'err' "$n problemi" } else { Set-It $it 'ok' 'Tutto ok' }
        }
        'repair' {
            $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
            $cb = { param($l) $it.Sub = $l }
            $r1 = Invoke-Live "$env:SystemRoot\System32\dism.exe" '/Online /Cleanup-Image /RestoreHealth' $oem $cb
            $r2 = Invoke-Live "$env:SystemRoot\System32\sfc.exe" '/scannow' ([Text.Encoding]::Unicode) $cb
            $bad = $r1.Code -ne 0 -or $r2.Out -match 'impossibile|unable to fix|non è stato possibile'
            $it.Sub = 'DISM ' + $(if ($r1.Code -eq 0) { 'ok' } else { 'errore' }) + '  ·  SFC ' + $(if ($r2.Out -match 'riparat|successfully repaired') { 'file riparati' } elseif ($bad) { 'problemi non risolti' } else { 'nessun problema' })
            if ($bad) { Set-It $it 'err' 'Da verificare' } else { Set-It $it 'ok' 'Completata' }
        }
    }
}

function Install-Profile($it, [string]$Path, [bool]$silent) {
    $p = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $err = 0; $n = 0
    foreach ($id in (@($p.winget) | Where-Object { $_ })) {
        if ($sync.Cancel) { break }
        $n++; $it.Sub = "winget: $id"
        $r = Invoke-Winget 'install' $id ''
        $k, $t = Get-WingetResult $r.Code 'Installato'
        if ($k -eq 'err') { $err++ }
        Add-History $area "$($it.Name) › $id" $t $k
    }
    foreach ($l in (@($p.local) | Where-Object { $_ })) {
        if ($sync.Cancel) { break }
        $n++; $it.Sub = "locale: $l"
        $f = Get-ChildItem $InstDir -Recurse -File -Filter $l -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $f) { $err++; Add-History $area "$($it.Name) › $l" 'File non trovato' 'err'; continue }
        $code = Install-Local $f.FullName $silent
        if ($code -notin 0, 3010, 1641) { $err++ }
        Add-History $area "$($it.Name) › $l" "Codice $code" $(if ($code -in 0, 3010, 1641) { 'ok' } else { 'err' })
    }
    $it.Sub = "$n elementi elaborati"
    if ($err) { Set-It $it 'err' "$err errori" } else { Set-It $it 'ok' 'Completato' }
}


# ---------- Consegna PC ----------
function Get-PcIdentity {
    $cs = Get-CimInstance Win32_ComputerSystem; $bios = Get-CimInstance Win32_BIOS
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\s+', ' '
    $disks = (Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FriendlyName) $(Format-Size $_.Size)" }) -join ' + '
    [pscustomobject]@{ Maker = "$($cs.Manufacturer)".Trim(); Model = "$($cs.Model)".Trim(); Serial = "$($bios.SerialNumber)".Trim()
        Cpu = $cpu.Trim(); Ram = Format-Size $cs.TotalPhysicalMemory; Disks = $disks
        Os = (Get-CimInstance Win32_OperatingSystem).Caption + ' ' + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion }
}
function Get-ShopHeader($S) {
    $E = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $logo = ''
    if ($S.ShopLogo -and (Test-Path $S.ShopLogo)) {
        $ext = [IO.Path]::GetExtension($S.ShopLogo).TrimStart('.').ToLower(); if ($ext -eq 'jpg') { $ext = 'jpeg' }
        $logo = "<img src='data:image/$ext;base64,$([Convert]::ToBase64String([IO.File]::ReadAllBytes($S.ShopLogo)))' style='max-height:64px;max-width:220px'>"
    }
    $contacts = (@($S.ShopPhone, $S.ShopEmail, $S.ShopWeb) | Where-Object { $_ } | ForEach-Object { & $E $_ }) -join '  ·  '
    "<div class='shop'>$logo<div><div class='sn'>$(& $E $(if ($S.ShopName) { $S.ShopName } else { 'MultiTool' }))</div><div class='m'>$contacts</div></div></div>"
}
function New-DeliveryReport {
    $S = Get-Settings; $E = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $id = Get-PcIdentity
    $cards = Get-HwInventory
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName } |
            Sort-Object DisplayName -Unique | ForEach-Object { "<tr><td>$(& $E $_.DisplayName)</td><td>$(& $E $_.DisplayVersion)</td><td>$(& $E $_.Publisher)</td></tr>" }
    $hw = foreach ($c in $cards) { "<h3>$(& $E $c.T)</h3><table>" + (($c.Rows | ForEach-Object { "<tr><th>$(& $E $_.L)</th><td>$(& $E $_.V)</td></tr>" }) -join '') + '</table>' }
    $sale = Get-Date; $exp = $sale.AddMonths([int]$S.WarrantyMonths)
    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>Rapporto di consegna - $(& $E $id.Serial)</title>
<style>body{font-family:Segoe UI,sans-serif;color:#1b1e27;margin:36px;max-width:960px}.shop{display:flex;gap:18px;align-items:center;border-bottom:3px solid #7c5cff;padding-bottom:16px}
.sn{font-size:22px;font-weight:600}.m{color:#5b6175;font-size:13px}h1{font-size:26px;margin:26px 0 4px}h2{font-size:18px;margin:30px 0 8px;color:#5b3fd9}h3{font-size:15px;margin:18px 0 6px}
table{width:100%;border-collapse:collapse;margin-bottom:6px}th,td{padding:6px 10px;text-align:left;border-bottom:1px solid #eceef4;font-size:13px;vertical-align:top}th{width:200px;color:#5b6175;font-weight:600}
.box{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}.k{background:#f4f5f9;border-radius:10px;padding:10px 12px}.k b{display:block;font-size:15px}.sig{display:flex;gap:40px;margin-top:40px}.sig div{flex:1;border-top:1px solid #999;padding-top:6px;font-size:12px;color:#5b6175}
@media print{body{margin:12mm}h2{page-break-after:avoid}}</style></head><body>
$(Get-ShopHeader $S)
<h1>Rapporto di consegna</h1><div class="m">Preparato il $($sale.ToString('dd/MM/yyyy HH:mm'))</div>
<h2>Computer</h2><div class="box">
<div class="k">Modello<b>$(& $E "$($id.Maker) $($id.Model)")</b></div><div class="k">Numero di serie<b>$(& $E $id.Serial)</b></div><div class="k">Sistema<b>$(& $E $id.Os)</b></div>
<div class="k">Processore<b>$(& $E $id.Cpu)</b></div><div class="k">Memoria<b>$(& $E $id.Ram)</b></div><div class="k">Garanzia fino al<b>$($exp.ToString('dd/MM/yyyy'))</b></div></div>
<h2>Hardware nel dettaglio</h2>$($hw -join '')
<h2>Programmi installati</h2><table><tr><th>Programma</th><th>Versione</th><th>Editore</th></tr>$($apps -join '')</table>
<div class="sig"><div>Firma del tecnico</div><div>Firma del cliente per ricevuta</div></div>
<p class="m" style="margin-top:24px">Generato da MultiTool</p></body></html>
"@
    $dir = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ("Consegna-{0}-{1}.html" -f ($id.Serial -replace '[^\w-]', ''), (Get-Date -Format 'yyyyMMdd-HHmm'))
    Set-Content -Path $file -Value $html -Encoding UTF8
    $file
}
function New-PcLabel {
    $S = Get-Settings; $E = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $id = Get-PcIdentity
    $exp = (Get-Date).AddMonths([int]$S.WarrantyMonths).ToString('dd/MM/yyyy')
    $qr = if ($S.ShopWeb) { $u = $S.ShopWeb; if ($u -notmatch '^https?://') { $u = "https://$u" }; $u + $(if ($u -match '\?') { '&' } else { '?' }) + 'sn=' + [uri]::EscapeDataString($id.Serial) }
          else { "$($S.ShopName) - Assistenza $($S.ShopPhone) $($S.ShopEmail) - S/N $($id.Serial)" }
    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>Etichetta $(& $E $id.Serial)</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>body{font-family:Segoe UI,sans-serif;margin:20px}.l{width:90mm;height:50mm;border:1px dashed #999;border-radius:3mm;padding:3mm;box-sizing:border-box;display:flex;gap:3mm}
.t{flex:1;font-size:8.5pt;line-height:1.35;overflow:hidden}.n{font-weight:700;font-size:10.5pt;border-bottom:2px solid #7c5cff;margin-bottom:1.5mm;padding-bottom:1mm}
#q{width:30mm;height:30mm;align-self:center}#q img,#q canvas{width:30mm!important;height:30mm!important}.f{font-size:7pt;color:#555}.np{margin-top:14px}@media print{.np{display:none}body{margin:0}.l{border:none}}</style></head>
<body><div class="l"><div class="t"><div class="n">$(& $E $(if ($S.ShopName) { $S.ShopName } else { 'Assistenza' }))</div>
<b>$(& $E "$($id.Maker) $($id.Model)")</b><br>S/N: $(& $E $id.Serial)<br>$(& $E $id.Cpu)<br>RAM $(& $E $id.Ram)<br>
Vendita: $(Get-Date -Format 'dd/MM/yyyy')  ·  Garanzia: $exp<br><span class="f">$(& $E ((@($S.ShopPhone, $S.ShopEmail) | Where-Object { $_ }) -join '  ·  '))</span></div><div id="q"></div></div>
<div class="np"><button onclick="window.print()">Stampa</button> <span class="f">Formato 90 × 50 mm. Il codice QR richiede la connessione a internet per essere generato.</span></div>
<script>new QRCode(document.getElementById('q'),{text:$(ConvertTo-Json $qr),width:256,height:256,correctLevel:QRCode.CorrectLevel.M});</script></body></html>
"@
    $dir = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ("Etichetta-{0}.html" -f ($id.Serial -replace '[^\w-]', ''))
    Set-Content -Path $file -Value $html -Encoding UTF8
    $file
}

# ---------- Backup ----------
function Get-BackupFolders {
    $dl = try { (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch { Join-Path $env:USERPROFILE 'Downloads' }
    @(
        @{ Id = 'doc'; Name = 'Documenti'; Path = [Environment]::GetFolderPath('MyDocuments'); Def = $true }
        @{ Id = 'desk'; Name = 'Desktop'; Path = [Environment]::GetFolderPath('Desktop'); Def = $true }
        @{ Id = 'pic'; Name = 'Immagini'; Path = [Environment]::GetFolderPath('MyPictures'); Def = $true }
        @{ Id = 'vid'; Name = 'Video'; Path = [Environment]::GetFolderPath('MyVideos'); Def = $false }
        @{ Id = 'mus'; Name = 'Musica'; Path = [Environment]::GetFolderPath('MyMusic'); Def = $false }
        @{ Id = 'dl'; Name = 'Download'; Path = $dl; Def = $false }
    )
}
function Invoke-FolderBackup([string]$Src, [string]$Dest) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $a = "`"$Src`" `"$Dest`" /E /XO /R:1 /W:1 /MT:8 /NP /NFL /NDL /XJ /XA:S"
    $r = Invoke-Hidden "$env:SystemRoot\System32\robocopy.exe" $a
    $m = [regex]::Match($r.Out, '(?m)^\s*(File|Files)\s*:\s*(\d+)\s+(\d+)')
    [pscustomobject]@{ Code = $r.Code; Copied = $(if ($m.Success) { [int]$m.Groups[3].Value } else { -1 }) }
}

# ---------- Rete ----------
function Test-Ping([string]$HostName) {
    try { $p = New-Object Net.NetworkInformation.Ping; $t = @(1..3 | ForEach-Object { $r = $p.Send($HostName, 1500); if ($r.Status -eq 'Success') { $r.RoundtripTime } }); if ($t.Count) { [int]($t | Measure-Object -Average).Average } else { $null } } catch { $null }
}
function Measure-Download([int]$Seconds = 12) {
    $req = [Net.HttpWebRequest]::Create('https://speed.cloudflare.com/__down?bytes=200000000'); $req.Timeout = 15000
    $resp = $req.GetResponse(); $st = $resp.GetResponseStream(); $buf = New-Object byte[] 65536
    $sw = [Diagnostics.Stopwatch]::StartNew(); $tot = 0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $tot += $n }
    $sw.Stop(); $resp.Close()
    [math]::Round($tot * 8 / $sw.Elapsed.TotalSeconds / 1e6, 1)
}
function Measure-Upload([int]$MB = 15) {
    $data = New-Object byte[] ($MB * 1MB); (New-Object Random).NextBytes($data)
    $req = [Net.HttpWebRequest]::Create('https://speed.cloudflare.com/__up'); $req.Method = 'POST'; $req.ContentType = 'application/octet-stream'; $req.Timeout = 60000
    $req.ContentLength = $data.Length
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $st = $req.GetRequestStream(); $st.Write($data, 0, $data.Length); $st.Close()
    $req.GetResponse().Close(); $sw.Stop()
    [math]::Round($data.Length * 8 / $sw.Elapsed.TotalSeconds / 1e6, 1)
}

# ---------- Benchmark ----------
function Get-BenchTests {
    @(
        @{ Id = 'cpu1'; Name = 'Processore · crittografia AES'; Args = 'cpu -encryption' }
        @{ Id = 'cpu2'; Name = 'Processore · compressione'; Args = 'cpu -compression' }
        @{ Id = 'mem';  Name = 'Memoria RAM · velocità'; Args = 'mem' }
        @{ Id = 'dsr';  Name = "Disco $env:SystemDrive · lettura sequenziale"; Args = "disk -seq -read -drive $($env:SystemDrive.TrimEnd(':'))" }
        @{ Id = 'dsw';  Name = "Disco $env:SystemDrive · scrittura sequenziale"; Args = "disk -seq -write -drive $($env:SystemDrive.TrimEnd(':'))" }
        @{ Id = 'drr';  Name = "Disco $env:SystemDrive · lettura casuale"; Args = "disk -ran -read -drive $($env:SystemDrive.TrimEnd(':'))" }
    )
}

function Show-Toast([string]$Title, [string]$Text) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $x = New-Object Windows.Data.Xml.Dom.XmlDocument
        $t = [Security.SecurityElement]::Escape($Title); $m = [Security.SecurityElement]::Escape($Text)
        $x.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$m</text></binding></visual></toast>")
        $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show((New-Object Windows.UI.Notifications.ToastNotification $x))
    } catch {}
}
'@

. ([scriptblock]::Create($Helpers))

# ============================================================
#  MODALITÀ AUTOMATICA (attività pianificata)
# ============================================================
if ($Auto) {
    $sync = @{}
    $S = Get-Settings
    if ($S.Restore) { [void](New-RestorePoint 'MultiTool - Aggiornamento automatico') }
    $excl = Read-Exclusions
    Start-StoreScan
    $ok = 0; $err = 0
    try {
        $r = Invoke-Hidden (Get-WingetPath) 'upgrade --include-unknown --accept-source-agreements --disable-interactivity'
        foreach ($t in ConvertFrom-WingetTable $r.Out) {
            $c = $t.Cols
            if ($c.Count -lt 4 -or $excl -contains $c[1]) { continue }
            $src = if ($c.Count -ge 5) { $c[4] } else { '' }
            $x = Invoke-Winget 'upgrade' $c[1] $src
            $k, $txt = Get-WingetResult $x.Code 'Aggiornato'
            Add-History 'Automatico' $c[0] $txt $k
            if ($k -eq 'ok') { $ok++ } else { $err++ }
        }
        $msg = if ($ok + $err) { "$ok programmi aggiornati" + $(if ($err) { ", $err con errori" } else { '' }) } else { 'Nessun aggiornamento disponibile' }
    } catch { $msg = "Errore: $($_.Exception.Message)" }
    if ($sync.Reboot) { $msg += ' - riavvio consigliato' }
    Show-Toast 'MultiTool - Aggiornamento automatico' $msg
    exit
}

# ============================================================
#  BACKUP AUTOMATICO (attività pianificata)
# ============================================================
if ($Backup) {
    $sync = @{}
    $S = Get-Settings
    if (-not $S.BackupDest -or -not (Test-Path $S.BackupDest)) { Show-Toast 'MultiTool - Backup' 'Destinazione non disponibile: collega il disco del backup'; exit }
    $root = Join-Path $S.BackupDest "MultiTool-Backup\$env:COMPUTERNAME"
    $n = 0; $err = 0
    foreach ($f in Get-BackupFolders | Where-Object { $_.Def -and $_.Path -and (Test-Path $_.Path) }) {
        $r = Invoke-FolderBackup $f.Path (Join-Path $root $f.Name)
        if ($r.Code -lt 8) { $n += [Math]::Max(0, $r.Copied) } else { $err++ }
    }
    $S.LastBackup = (Get-Date).ToString('s'); Save-Json 'settings.json' $S
    Add-History 'Backup automatico' $root $(if ($err) { "$err errori" } else { "$n file copiati" }) $(if ($err) { 'err' } else { 'ok' })
    Show-Toast 'MultiTool - Backup' $(if ($err) { "Backup completato con $err errori" } else { "Backup completato: $n file nuovi o modificati" })
    exit
}

# ============================================================
#  DISINSTALLAZIONE
# ============================================================
if ($Uninstall) {
    Add-Type -AssemblyName PresentationFramework
    if ([Windows.MessageBox]::Show('Disinstallare MultiTool da questo PC?', 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { exit }
    $keepData = [Windows.MessageBox]::Show("Conservare i dati (impostazioni, cronologia, rapporti, installer e profili) in $env:ProgramData\MultiTool?", 'MultiTool', 'YesNo', 'Question') -eq 'Yes'
    Get-ScheduledTask -TaskName 'MultiTool*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName 'MultiTool*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    foreach ($d in [Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('CommonDesktopDirectory')) { Remove-Item (Join-Path $d 'MultiTool.lnk') -Force -ErrorAction SilentlyContinue }
    Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MultiTool' -Recurse -Force -ErrorAction SilentlyContinue
    $target = Join-Path $env:ProgramFiles 'MultiTool'
    $cmd = "timeout /t 3 /nobreak >nul & rmdir /s /q `"$target`"" + $(if (-not $keepData) { " & rmdir /s /q `"$env:ProgramData\MultiTool`"" } else { '' })
    Start-Process cmd.exe -ArgumentList "/c $cmd" -WindowStyle Hidden
    [void][Windows.MessageBox]::Show('MultiTool è stato disinstallato.', 'MultiTool', 'OK', 'Information')
    exit
}

# --- Nasconde la console ---
Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
'@
[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)

# --- Identità propria sulla barra delle applicazioni (altrimenti Windows mostra l'icona di PowerShell) ---
Add-Type -Name Shell -Namespace NativeApp -MemberDefinition @'
[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@
[void][NativeApp.Shell]::SetCurrentProcessExplicitAppUserModelID('Erodyne.MultiTool')

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# --- Istanza unica ---
$Mutex = New-Object Threading.Mutex($false, 'Local\MultiTool2026')
if (-not $Mutex.WaitOne(0)) {
    [void][Windows.MessageBox]::Show('MultiTool è già aperto (controlla anche l''area di notifica).', 'MultiTool', 'OK', 'Information')
    exit
}
$Settings = Get-Settings

$ThemeMap = @{
    '#0B0D12' = '#F4F5F9'; '#12151D' = '#FFFFFF'; '#131722' = '#FFFFFF'; '#141823' = '#EEF0F5'; '#151925' = '#F7F7FB'
    '#161A25' = '#F3F4F8'; '#171A24' = '#EEF0F5'; '#191D28' = '#E9EBF2'; '#1A1E2A' = '#E3E6EE'; '#1A1E2B' = '#E6E8EF'
    '#1A1F2C' = '#ECEEF5'; '#1B1F2E' = '#E6E3FF'; '#1C2030' = '#ECEEF4'; '#1C2130' = '#E3E6EE'; '#1E2230' = '#E3E6EE'
    '#1E2232' = '#FFFFFF'; '#1F2434' = '#E2E5EC'; '#1F2436' = '#D9DCE5'; '#232838' = '#E0E3EA'; '#2A3042' = '#D3D7E0'
    '#2E3448' = '#C8CCD6'; '#343B55' = '#B9BED0'; '#3A4058' = '#B0B5C5'; '#E8EAF2' = '#1B1E27'; '#FFFFFF' = '#11131A'
    '#9AA0B8' = '#5B6175'; '#6B7290' = '#7A8096'; '#5C6278' = '#8A90A6'; '#4F5570' = '#9AA0B3'; '#7C83A0' = '#6B7290'
    '#C9CDDB' = '#3A3F4E'; '#A0A6BC' = '#5B6175'; '#16284A' = '#DCE8FF'; '#0F2E27' = '#D7F5EA'; '#3A1A1F' = '#FDE2E2'
    '#33280F' = '#FFF1CC'; '#231D10' = '#FFF6DB'; '#4A3A15' = '#F0D58A'; '#F3E2B5' = '#5A4510'; '#22D3EE' = '#0891B2'
}
function Apply-Theme([string]$Text) {
    if ($Settings.Theme -ne 'light') { return $Text }
    [regex]::Replace($Text, '#[0-9A-Fa-f]{6}(?![0-9A-Fa-f])', { param($m) $k = $m.Value.ToUpper(); if ($ThemeMap.ContainsKey($k)) { $ThemeMap[$k] } else { $m.Value } })
}

Add-Type -TypeDefinition @'
using System.ComponentModel;
using System.Collections.Generic;
public class MtItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    readonly Dictionary<string, object> v = new Dictionary<string, object>();
    object G(string n, object d) { lock (v) { object o; return v.TryGetValue(n, out o) ? o : d; } }
    void S(string n, object val) {
        lock (v) { v[n] = val; }
        var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n));
    }
    public bool   Selected   { get { return (bool)G("Selected", false); }   set { S("Selected", value); } }
    public bool   Editable   { get { return (bool)G("Editable", true); }    set { S("Editable", value); } }
    public bool   Checkable  { get { return (bool)G("Checkable", true); }   set { S("Checkable", value); } }
    public bool   Arrow      { get { return (bool)G("Arrow", false); }      set { S("Arrow", value); } }
    public string Name       { get { return (string)G("Name", ""); }        set { S("Name", value); } }
    public string Sub        { get { return (string)G("Sub", ""); }         set { S("Sub", value); } }
    public string C1         { get { return (string)G("C1", ""); }          set { S("C1", value); } }
    public string C2         { get { return (string)G("C2", ""); }          set { S("C2", value); } }
    public string Tag        { get { return (string)G("Tag", ""); }         set { S("Tag", value); } }
    public string TagKind    { get { return (string)G("TagKind", "none"); } set { S("TagKind", value); } }
    public string Status     { get { return (string)G("Status", ""); }      set { S("Status", value); } }
    public string StatusKind { get { return (string)G("StatusKind", "none"); } set { S("StatusKind", value); } }
    public string Glyph      { get { return (string)G("Glyph", ""); }       set { S("Glyph", value); } }
    public string Key        { get { return (string)G("Key", ""); }         set { S("Key", value); } }
    public object Data       { get { return G("Data", null); }              set { S("Data", value); } }
}
'@

# ============================================================
#  UI (XAML)
# ============================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MultiTool" Width="1280" Height="820" MinWidth="1100" MinHeight="680"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanResizeWithGrip"
        FontFamily="Segoe UI Variable Display, Segoe UI" Foreground="#E8EAF2"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <BooleanToVisibilityConverter x:Key="B2V"/>
    <LinearGradientBrush x:Key="Accent" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#7C5CFF" Offset="0"/>
      <GradientStop Color="#22D3EE" Offset="1"/>
    </LinearGradientBrush>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#2E3448" Margin="1"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BaseBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#E8EAF2"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="24,11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="#191D28"/>
      <Setter Property="BorderBrush" Value="#2A3042"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentBtn" TargetType="Button" BasedOn="{StaticResource BaseBtn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button" BasedOn="{StaticResource BaseBtn}"/>
    <Style x:Key="LinkBtn" TargetType="Button" BasedOn="{StaticResource BaseBtn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#9AA0B8"/>
    </Style>
    <Style x:Key="TitleBtn" TargetType="Button" BasedOn="{StaticResource LinkBtn}">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Padding" Value="16,10"/>
    </Style>
    <Style x:Key="QuickBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#E8EAF2"/>
      <Setter Property="Margin" Value="5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#161A25" BorderBrush="#232838" BorderThickness="1" CornerRadius="14" Padding="16,14">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="b" Property="Background" Value="#1A1F2C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#9AA0B8"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="10" Padding="12,9">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="30"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="g" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center"/>
                <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#141823"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1B1F2E"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
                <Setter TargetName="g" Property="Foreground" Value="#A78BFA"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavSection" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#4F5570"/>
      <Setter Property="Margin" Value="12,18,0,6"/>
    </Style>

    <Style x:Key="DayPill" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="days"/>
      <Setter Property="Foreground" Value="#9AA0B8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Width="38" Height="34" CornerRadius="10" Background="#141823" BorderBrush="#2A3042" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="b" Property="BorderThickness" Value="0"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="#E8EAF2"/>
      <Setter Property="CaretBrush" Value="#E8EAF2"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="#141823" BorderBrush="#2A3042" BorderThickness="1" CornerRadius="10" Padding="12,9">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#7C5CFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Check" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="box" Width="20" Height="20" CornerRadius="6" BorderThickness="1.5" BorderBrush="#3A4058" Background="Transparent">
              <TextBlock x:Name="mark" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="White"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="BorderThickness" Value="0"/>
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="box" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#C9CDDB"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="track" Width="40" Height="22" CornerRadius="11" Background="#2A3042">
                <Ellipse x:Name="knob" Width="16" Height="16" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="RowItem" TargetType="ListBoxItem">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="r" Background="#131722" CornerRadius="12" Padding="16,11" Margin="0,0,0,8" BorderThickness="1" BorderBrush="#1C2130">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="r" Property="BorderBrush" Value="#343B55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#12151D"/>
      <Setter Property="BorderBrush" Value="#1F2434"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="18"/>
      <Setter Property="Padding" Value="22"/>
      <Setter Property="Margin" Value="6"/>
    </Style>
    <Style x:Key="CardLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#6B7290"/>
    </Style>

    <Style x:Key="StatusPill" TargetType="Border">
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Background" Value="#1E2230"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding StatusKind}" Value="none"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="run"><Setter Property="Background" Value="#16284A"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="ok"><Setter Property="Background" Value="#0F2E27"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="err"><Setter Property="Background" Value="#3A1A1F"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="skip"><Setter Property="Background" Value="#171A24"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="StatusText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#9AA0B8"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding StatusKind}" Value="run"><Setter Property="Foreground" Value="#60A5FA"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="ok"><Setter Property="Foreground" Value="#34D399"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="err"><Setter Property="Foreground" Value="#F87171"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="skip"><Setter Property="Foreground" Value="#5C6278"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="TagPill" TargetType="Border">
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="8,3"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Background" Value="#1C2030"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Tag}" Value=""><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
        <DataTrigger Binding="{Binding TagKind}" Value="ok"><Setter Property="Background" Value="#0F2E27"/></DataTrigger>
        <DataTrigger Binding="{Binding TagKind}" Value="err"><Setter Property="Background" Value="#3A1A1F"/></DataTrigger>
        <DataTrigger Binding="{Binding TagKind}" Value="warn"><Setter Property="Background" Value="#33280F"/></DataTrigger>
        <DataTrigger Binding="{Binding TagKind}" Value="info"><Setter Property="Background" Value="#16284A"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="TagText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#A0A6BC"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding TagKind}" Value="ok"><Setter Property="Foreground" Value="#34D399"/></DataTrigger>
        <DataTrigger Binding="{Binding TagKind}" Value="err"><Setter Property="Foreground" Value="#F87171"/></DataTrigger>
        <DataTrigger Binding="{Binding TagKind}" Value="warn"><Setter Property="Foreground" Value="#FBBF24"/></DataTrigger>
        <DataTrigger Binding="{Binding TagKind}" Value="info"><Setter Property="Foreground" Value="#60A5FA"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="ColHead" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#5C6278"/>
    </Style>
  </Window.Resources>

  <Border CornerRadius="18" Background="#0B0D12" BorderBrush="#1F2436" BorderThickness="1">
    <Grid>
      <Border CornerRadius="18" IsHitTestVisible="False">
        <Border.Background>
          <RadialGradientBrush Center="0.95,0" GradientOrigin="0.95,0" RadiusX="0.5" RadiusY="0.7">
            <GradientStop Color="#2A7C5CFF" Offset="0"/>
            <GradientStop Color="#007C5CFF" Offset="1"/>
          </RadialGradientBrush>
        </Border.Background>
      </Border>
      <Border CornerRadius="18" IsHitTestVisible="False">
        <Border.Background>
          <RadialGradientBrush Center="0.25,1" GradientOrigin="0.25,1" RadiusX="0.45" RadiusY="0.55">
            <GradientStop Color="#1A22D3EE" Offset="0"/>
            <GradientStop Color="#0022D3EE" Offset="1"/>
          </RadialGradientBrush>
        </Border.Background>
      </Border>

      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="48"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="240"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Title bar -->
        <Grid x:Name="TitleBar" Grid.ColumnSpan="2" Background="Transparent">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0">
            <Border Width="24" Height="24" CornerRadius="7" Background="{StaticResource Accent}">
              <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock Text="MultiTool" FontSize="14" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
            <Border CornerRadius="6" Background="#1A1E2B" Padding="7,2" Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="ADMIN" FontSize="10" FontWeight="Bold" Foreground="#9AA0B8"/>
            </Border>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnMin" Style="{StaticResource TitleBtn}" Content="&#xE921;"/>
            <Button x:Name="BtnMax" Style="{StaticResource TitleBtn}" Content="&#xE922;"/>
            <Button x:Name="BtnClose" Style="{StaticResource TitleBtn}" Content="&#xE8BB;" Margin="0,0,6,0"/>
          </StackPanel>
        </Grid>

        <!-- Sidebar -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="NavPanel" Margin="14,0,10,20">
            <RadioButton x:Name="NavHome" Style="{StaticResource Nav}" Tag="&#xE80F;" Content="Home" IsChecked="True"/>
            <RadioButton x:Name="NavFull" Style="{StaticResource Nav}" Tag="&#xE768;" Content="Manutenzione completa"/>
            <RadioButton x:Name="NavDeliver" Style="{StaticResource Nav}" Tag="&#xE719;" Content="Preparazione consegna"/>
            <TextBlock Text="PROGRAMMI" Style="{StaticResource NavSection}"/>
            <RadioButton x:Name="NavUpdates"   Style="{StaticResource Nav}" Tag="&#xE895;" Content="Aggiorna programmi"/>
            <RadioButton x:Name="NavInstall"   Style="{StaticResource Nav}" Tag="&#xE896;" Content="Installer locali"/>
            <RadioButton x:Name="NavCatalog"   Style="{StaticResource Nav}" Tag="&#xE721;" Content="Catalogo winget"/>
            <RadioButton x:Name="NavProfiles"  Style="{StaticResource Nav}" Tag="&#xE8F1;" Content="Profili"/>
            <RadioButton x:Name="NavUninstall" Style="{StaticResource Nav}" Tag="&#xE74D;" Content="Disinstalla"/>
            <RadioButton x:Name="NavBackup"    Style="{StaticResource Nav}" Tag="&#xE753;" Content="Backup"/>
            <TextBlock Text="SISTEMA" Style="{StaticResource NavSection}"/>
            <RadioButton x:Name="NavHw"        Style="{StaticResource Nav}" Tag="&#xE7F8;" Content="Hardware"/>
            <RadioButton x:Name="NavWU"        Style="{StaticResource Nav}" Tag="&#xE777;" Content="Windows Update"/>
            <RadioButton x:Name="NavDrivers"   Style="{StaticResource Nav}" Tag="&#xE950;" Content="Driver"/>
            <RadioButton x:Name="NavStartup"   Style="{StaticResource Nav}" Tag="&#xE7E8;" Content="Avvio automatico"/>
            <RadioButton x:Name="NavCleanup"   Style="{StaticResource Nav}" Tag="&#xE894;" Content="Pulizia disco"/>
            <RadioButton x:Name="NavRepair"    Style="{StaticResource Nav}" Tag="&#xE90F;" Content="Riparazione"/>
            <RadioButton x:Name="NavPrivacy"   Style="{StaticResource Nav}" Tag="&#xE72E;" Content="Privacy"/>
            <RadioButton x:Name="NavSecurity"  Style="{StaticResource Nav}" Tag="&#xEA18;" Content="Sicurezza"/>
            <RadioButton x:Name="NavNetwork"   Style="{StaticResource Nav}" Tag="&#xE774;" Content="Rete"/>
            <RadioButton x:Name="NavBench"     Style="{StaticResource Nav}" Tag="&#xE916;" Content="Benchmark"/>
            <RadioButton x:Name="NavRestore"   Style="{StaticResource Nav}" Tag="&#xE7A7;" Content="Punti di ripristino"/>
            <TextBlock Text="ALTRO" Style="{StaticResource NavSection}"/>
            <RadioButton x:Name="NavHistory"   Style="{StaticResource Nav}" Tag="&#xE81C;" Content="Cronologia"/>
            <RadioButton x:Name="NavLogs"      Style="{StaticResource Nav}" Tag="&#xE8A5;" Content="Log"/>
            <RadioButton x:Name="NavSettings"  Style="{StaticResource Nav}" Tag="&#xE713;" Content="Impostazioni"/>
            <TextBlock x:Name="AppVer" Foreground="#4F5570" FontSize="11" Margin="12,18,0,0"/>
            <TextBlock x:Name="PrefInfo" Foreground="#4F5570" FontSize="11" Margin="12,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </ScrollViewer>

        <!-- Content -->
        <Grid Grid.Row="1" Grid.Column="1" Margin="26,0,36,28">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Border x:Name="RebootBar" Visibility="Collapsed" Background="#231D10" BorderBrush="#4A3A15" BorderThickness="1" CornerRadius="12" Padding="16,10" Margin="0,0,0,14">
            <Grid>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#FBBF24" VerticalAlignment="Center"/>
                <TextBlock Text="È necessario un riavvio per completare alcune modifiche." Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#F3E2B5"/>
              </StackPanel>
              <Button x:Name="RebootGo" Style="{StaticResource AccentBtn}" Content="Riavvia ora" Padding="16,7" FontSize="13" HorizontalAlignment="Right"/>
            </Grid>
          </Border>

          <!-- ===================== HOME ===================== -->
          <Grid x:Name="ViewHome" Grid.Row="1">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="6,14,0,14">
              <TextBlock x:Name="HHello" FontSize="40" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
              <TextBlock x:Name="HSub" FontSize="15" Foreground="#9AA0B8" Margin="0,4,0,0" Text="Raccolgo le informazioni sul sistema…"/>
            </StackPanel>

            <UniformGrid Grid.Row="1" Columns="4">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="SISTEMA" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="HOs" Text="—" FontSize="18" FontWeight="SemiBold" Margin="0,10,0,0" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="HBuild" Text=" " FontSize="12" Foreground="#9AA0B8" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="PROCESSORE" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="HCpu" Text="—" FontSize="15" FontWeight="SemiBold" Margin="0,10,0,0" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="HCores" Text=" " FontSize="12" Foreground="#9AA0B8" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="MEMORIA" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="HRam" Text="—" FontSize="18" FontWeight="SemiBold" Margin="0,10,0,0"/>
                  <Border Height="6" CornerRadius="3" Background="#1A1E2A" Margin="0,10,0,0" ClipToBounds="True">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition x:Name="HRamA" Width="0*"/>
                        <ColumnDefinition x:Name="HRamB" Width="100*"/>
                      </Grid.ColumnDefinitions>
                      <Border CornerRadius="3" Background="{StaticResource Accent}"/>
                    </Grid>
                  </Border>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="PROTEZIONE" Style="{StaticResource CardLabel}"/>
                  <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <Ellipse x:Name="HDefDot" Width="9" Height="9" Fill="#5C6278" VerticalAlignment="Center"/>
                    <TextBlock x:Name="HDef" Text="—" FontSize="18" FontWeight="SemiBold" Margin="8,0,0,0"/>
                  </StackPanel>
                  <TextBlock x:Name="HDefSig" Text=" " FontSize="12" Foreground="#9AA0B8" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
            </UniformGrid>

            <Grid Grid.Row="2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="1.3*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}">
                <DockPanel>
                  <TextBlock DockPanel.Dock="Top" Text="SPAZIO SU DISCO" Style="{StaticResource CardLabel}" Margin="0,0,0,16"/>
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel x:Name="HDisks"/>
                  </ScrollViewer>
                </DockPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}">
                <DockPanel>
                  <Grid DockPanel.Dock="Top" Margin="0,0,0,12">
                    <TextBlock Text="SALUTE HARDWARE" Style="{StaticResource CardLabel}" VerticalAlignment="Center"/>
                    <Button x:Name="HHwMore" Style="{StaticResource LinkBtn}" Content="Dettagli  &#x2192;" HorizontalAlignment="Right" Padding="6,2" FontSize="12" Margin="0,-6,-6,-6"/>
                  </Grid>
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel x:Name="HHealth"/>
                  </ScrollViewer>
                </DockPanel>
              </Border>
              <Border Grid.Column="2" Style="{StaticResource Card}">
                <DockPanel>
                  <TextBlock DockPanel.Dock="Top" Text="AZIONI RAPIDE" Style="{StaticResource CardLabel}" Margin="0,0,0,10"/>
                  <UniformGrid Columns="2" Rows="2" Margin="-5">
                    <Button x:Name="QUpd" Style="{StaticResource QuickBtn}">
                      <StackPanel>
                        <Border Width="38" Height="38" CornerRadius="11" Background="{StaticResource Accent}" HorizontalAlignment="Left">
                          <TextBlock Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text="Aggiorna programmi" FontSize="15" FontWeight="SemiBold" Margin="0,12,0,0"/>
                        <TextBlock x:Name="QUpdSub" Text="winget + Microsoft Store" FontSize="12" Foreground="#9AA0B8" Margin="0,2,0,0"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="QWU" Style="{StaticResource QuickBtn}">
                      <StackPanel>
                        <Border Width="38" Height="38" CornerRadius="11" Background="{StaticResource Accent}" HorizontalAlignment="Left">
                          <TextBlock Text="&#xE777;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text="Windows Update" FontSize="15" FontWeight="SemiBold" Margin="0,12,0,0"/>
                        <TextBlock Text="Aggiornamenti di sistema" FontSize="12" Foreground="#9AA0B8" Margin="0,2,0,0"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="QDrv" Style="{StaticResource QuickBtn}">
                      <StackPanel>
                        <Border Width="38" Height="38" CornerRadius="11" Background="{StaticResource Accent}" HorizontalAlignment="Left">
                          <TextBlock Text="&#xE768;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text="Manutenzione completa" FontSize="15" FontWeight="SemiBold" Margin="0,12,0,0" TextTrimming="CharacterEllipsis"/>
                        <TextBlock Text="Tutto in un clic" FontSize="12" Foreground="#9AA0B8" Margin="0,2,0,0"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="QClean" Style="{StaticResource QuickBtn}">
                      <StackPanel>
                        <Border Width="38" Height="38" CornerRadius="11" Background="{StaticResource Accent}" HorizontalAlignment="Left">
                          <TextBlock Text="&#xE894;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text="Pulizia disco" FontSize="15" FontWeight="SemiBold" Margin="0,12,0,0"/>
                        <TextBlock Text="Libera spazio" FontSize="12" Foreground="#9AA0B8" Margin="0,2,0,0"/>
                      </StackPanel>
                    </Button>
                  </UniformGrid>
                </DockPanel>
              </Border>
            </Grid>
          </Grid>

          <!-- ===================== LISTA GENERICA ===================== -->
          <Grid x:Name="ViewList" Grid.Row="1" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid Margin="0,10,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock x:Name="LTitle" FontSize="32" FontWeight="Bold"/>
                <TextBlock x:Name="LSub" Foreground="#9AA0B8" FontSize="14" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom">
                <CheckBox x:Name="LSilent" Style="{StaticResource Switch}" Content="Silenziosa" IsChecked="True" Margin="0,0,14,0" VerticalAlignment="Center"/>
                <Button x:Name="LX1" Style="{StaticResource LinkBtn}"/>
                <Button x:Name="LX2" Style="{StaticResource LinkBtn}"/>
                <Button x:Name="LAll" Style="{StaticResource LinkBtn}" Content="Tutti"/>
                <Button x:Name="LNone" Style="{StaticResource LinkBtn}" Content="Nessuno"/>
              </StackPanel>
            </Grid>

            <Grid x:Name="LSearchBox" Grid.Row="1" Margin="0,16,0,0" Visibility="Collapsed">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="LSearch" Style="{StaticResource Input}"/>
              <Button x:Name="LSearchGo" Grid.Column="1" Style="{StaticResource AccentBtn}" Content="Cerca" Margin="10,0,0,0" Padding="22,9"/>
            </Grid>

            <Border Grid.Row="2" x:Name="LTrack" Height="4" CornerRadius="2" Background="#1A1E2A" Margin="0,16,0,16" ClipToBounds="True">
              <Grid>
                <Border x:Name="LFill" HorizontalAlignment="Left" Width="0" CornerRadius="2" Background="{StaticResource Accent}"/>
                <Border x:Name="LShimmer" Width="200" HorizontalAlignment="Left" CornerRadius="2" Background="{StaticResource Accent}" Visibility="Collapsed">
                  <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
                </Border>
              </Grid>
            </Border>

            <Grid Grid.Row="3">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Grid x:Name="LHeader" Margin="17,0,25,10">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="36"/><ColumnDefinition Width="46"/><ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="130"/><ColumnDefinition Width="26"/><ColumnDefinition Width="130"/>
                  <ColumnDefinition Width="120"/><ColumnDefinition Width="150"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="2" x:Name="LH0" Text="NOME" Style="{StaticResource ColHead}"/>
                <TextBlock Grid.Column="3" x:Name="LH1" Style="{StaticResource ColHead}"/>
                <TextBlock Grid.Column="5" x:Name="LH2" Style="{StaticResource ColHead}"/>
                <TextBlock Grid.Column="6" x:Name="LH3" Style="{StaticResource ColHead}"/>
                <TextBlock Grid.Column="7" x:Name="LH4" Style="{StaticResource ColHead}"/>
              </Grid>
              <ListBox x:Name="LList" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="#E8EAF2"
                       ItemContainerStyle="{StaticResource RowItem}" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                       VirtualizingPanel.ScrollUnit="Pixel">
                <ListBox.ItemTemplate>
                  <DataTemplate>
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="36"/><ColumnDefinition Width="46"/><ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="130"/><ColumnDefinition Width="26"/><ColumnDefinition Width="130"/>
                        <ColumnDefinition Width="120"/><ColumnDefinition Width="150"/>
                      </Grid.ColumnDefinitions>
                      <CheckBox Style="{StaticResource Check}" IsChecked="{Binding Selected, Mode=TwoWay}" IsEnabled="{Binding Editable}"
                                Visibility="{Binding Checkable, Converter={StaticResource B2V}}" VerticalAlignment="Center"/>
                      <Border Grid.Column="1" Width="34" Height="34" CornerRadius="9" Background="#1C2030" HorizontalAlignment="Left">
                        <TextBlock Text="{Binding Glyph}" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#A78BFA" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="0,0,14,0">
                        <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                        <TextBlock Text="{Binding Sub}" FontSize="12" Foreground="#6B7290" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                      </StackPanel>
                      <TextBlock Grid.Column="3" Text="{Binding C1}" Foreground="#9AA0B8" FontFamily="Cascadia Mono, Consolas" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,8,0"/>
                      <TextBlock Grid.Column="4" Text="&#xE72A;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#4F5570" VerticalAlignment="Center"
                                 Visibility="{Binding Arrow, Converter={StaticResource B2V}}"/>
                      <TextBlock Grid.Column="5" Text="{Binding C2}" Foreground="#22D3EE" FontFamily="Cascadia Mono, Consolas" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,8,0"/>
                      <Border Grid.Column="6" Style="{StaticResource TagPill}" Margin="0,0,8,0">
                        <TextBlock Text="{Binding Tag}" Style="{StaticResource TagText}"/>
                      </Border>
                      <Border Grid.Column="7" Style="{StaticResource StatusPill}">
                        <TextBlock Text="{Binding Status}" Style="{StaticResource StatusText}"/>
                      </Border>
                    </Grid>
                  </DataTemplate>
                </ListBox.ItemTemplate>
              </ListBox>
              <StackPanel x:Name="LEmpty" Grid.Row="1" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Border Width="76" Height="76" CornerRadius="38" Background="#1C2030" HorizontalAlignment="Center">
                  <TextBlock x:Name="LEmptyGlyph" FontFamily="Segoe MDL2 Assets" FontSize="28" Foreground="#A78BFA" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock x:Name="LEmptyTitle" FontSize="22" FontWeight="SemiBold" Margin="0,18,0,0" HorizontalAlignment="Center"/>
                <TextBlock x:Name="LEmptyText" Foreground="#9AA0B8" Margin="0,6,0,0" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="520"/>
              </StackPanel>
            </Grid>

            <WrapPanel x:Name="LCreditsBar" Grid.Row="4" Margin="0,10,0,0" Visibility="Collapsed">
              <TextBlock Text="Servizio offerto da:" Foreground="#5C6278" FontSize="12" VerticalAlignment="Center" Margin="0,0,2,0"/>
              <WrapPanel x:Name="LCredits"/>
            </WrapPanel>

            <Grid Grid.Row="5" Margin="0,12,0,0">
              <TextBlock x:Name="LSummary" VerticalAlignment="Center" Foreground="#9AA0B8" FontSize="13"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="LReport" Style="{StaticResource LinkBtn}" Content="Apri rapporto" Visibility="Collapsed" Margin="0,0,10,0"/>
                <Button x:Name="LCancel" Style="{StaticResource GhostBtn}" Content="ANNULLA" MinWidth="140" Margin="0,0,10,0"/>
                <Button x:Name="LGo2" Style="{StaticResource GhostBtn}" MinWidth="140" Margin="0,0,10,0"/>
                <Button x:Name="LGo" Style="{StaticResource AccentBtn}" MinWidth="160"/>
              </StackPanel>
            </Grid>
          </Grid>

          <!-- ===================== HARDWARE ===================== -->
          <Grid x:Name="ViewHw" Grid.Row="1" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Margin="0,10,0,10">
              <StackPanel>
                <TextBlock Text="Hardware" FontSize="32" FontWeight="Bold"/>
                <TextBlock x:Name="HwSub" Text="Componenti, firmware e sensori del PC." Foreground="#9AA0B8" FontSize="14" Margin="0,4,0,0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
                <Button x:Name="HwHist" Style="{StaticResource LinkBtn}" Content="Storico sensori"/>
                <Button x:Name="HwLabel" Style="{StaticResource LinkBtn}" Content="Etichetta QR"/>
                <Button x:Name="HwAdv" Style="{StaticResource LinkBtn}" Content="Attiva sensori avanzati"/>
                <Button x:Name="HwExport" Style="{StaticResource LinkBtn}" Content="Esporta inventario"/>
                <Button x:Name="HwReload" Style="{StaticResource LinkBtn}" Content="Aggiorna"/>
              </StackPanel>
            </Grid>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <Grid>
                      <TextBlock Text="SENSORI IN TEMPO REALE" Style="{StaticResource CardLabel}"/>
                      <TextBlock x:Name="HwSensSrc" HorizontalAlignment="Right" FontSize="11" Foreground="#6B7290"/>
                    </Grid>
                    <TextBlock x:Name="HwSensMsg" Foreground="#9AA0B8" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
                    <WrapPanel x:Name="HwSens" Margin="0,12,0,0"/>
                  </StackPanel>
                </Border>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel x:Name="HwCol1"/>
                  <StackPanel x:Name="HwCol2" Grid.Column="1"/>
                </Grid>
                <WrapPanel Margin="6,6,0,0">
                  <TextBlock Text="Servizio offerto da:" Foreground="#5C6278" FontSize="12" VerticalAlignment="Center"/>
                  <Button x:Name="HwCr1" Style="{StaticResource LinkBtn}" Content="Windows (WMI)" FontSize="12" Padding="6,2" Foreground="#A78BFA" Tag="https://learn.microsoft.com/windows/win32/wmisdk/wmi-start-page"/>
                  <Button x:Name="HwCr2" Style="{StaticResource LinkBtn}" Content="LibreHardwareMonitor" FontSize="12" Padding="6,2" Foreground="#A78BFA" Tag="https://github.com/LibreHardwareMonitor/LibreHardwareMonitor"/>
                  <Button x:Name="HwCr3" Style="{StaticResource LinkBtn}" Content="PawnIO" FontSize="12" Padding="6,2" Foreground="#A78BFA" Tag="https://pawnio.eu"/>
                  <Button x:Name="HwCr4" Style="{StaticResource LinkBtn}" Content="NVIDIA SMI" FontSize="12" Padding="6,2" Foreground="#A78BFA" Tag="https://developer.nvidia.com/system-management-interface"/>
                </WrapPanel>
              </StackPanel>
            </ScrollViewer>
          </Grid>

          <!-- ===================== LOG ===================== -->
          <Grid x:Name="ViewLogs" Grid.Row="1" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Margin="0,10,0,16">
              <StackPanel>
                <TextBlock Text="Log" FontSize="32" FontWeight="Bold"/>
                <TextBlock Text="Errori del programma, riparazioni e attività registrate." Foreground="#9AA0B8" FontSize="14" Margin="0,4,0,0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
                <Button x:Name="LogReload" Style="{StaticResource LinkBtn}" Content="Aggiorna"/>
                <Button x:Name="LogOpen" Style="{StaticResource LinkBtn}" Content="Apri cartella"/>
                <Button x:Name="LogDelete" Style="{StaticResource LinkBtn}" Content="Elimina log"/>
              </StackPanel>
            </Grid>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="260"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}" Margin="0,0,12,0" Padding="8">
                <ListBox x:Name="LogFiles" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                  <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                      <Setter Property="Cursor" Value="Hand"/>
                      <Setter Property="Template">
                        <Setter.Value>
                          <ControlTemplate TargetType="ListBoxItem">
                            <Border x:Name="b" CornerRadius="8" Padding="10,8" Background="Transparent"><ContentPresenter/></Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#141823"/></Trigger>
                              <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#1B1F2E"/></Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Setter.Value>
                      </Setter>
                    </Style>
                  </ListBox.ItemContainerStyle>
                  <ListBox.ItemTemplate>
                    <DataTemplate>
                      <StackPanel>
                        <TextBlock Text="{Binding Name}" Foreground="#E8EAF2" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                        <TextBlock Text="{Binding LastWriteTime, StringFormat=dd/MM/yyyy HH:mm}" Foreground="#6B7290" FontSize="11"/>
                      </StackPanel>
                    </DataTemplate>
                  </ListBox.ItemTemplate>
                </ListBox>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0" Padding="4">
                <TextBox x:Name="LogText" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#C9CDDB"
                         FontFamily="Cascadia Mono, Consolas" FontSize="12" Padding="12" TextWrapping="NoWrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
              </Border>
            </Grid>
          </Grid>

          <!-- ===================== IMPOSTAZIONI ===================== -->
          <ScrollViewer x:Name="ViewSettings" Grid.Row="1" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="0,10,0,0">
              <TextBlock Text="Impostazioni" FontSize="32" FontWeight="Bold" Margin="6,0,0,4"/>
              <TextBlock Text="Sicurezza, automazione e gestione dei dati." Foreground="#9AA0B8" FontSize="14" Margin="6,0,0,10"/>
              <UniformGrid Columns="2">
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="SICUREZZA" Style="{StaticResource CardLabel}"/>
                    <CheckBox x:Name="SetRestore" Style="{StaticResource Switch}" Margin="0,16,0,0" FontSize="14" Content="Crea un punto di ripristino prima delle modifiche"/>
                    <TextBlock Text="Vale per aggiornamenti, installazioni, driver e disinstallazioni." Foreground="#6B7290" FontSize="12" Margin="50,6,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="AGGIORNAMENTO AUTOMATICO" Style="{StaticResource CardLabel}"/>
                    <CheckBox x:Name="SetAuto" Style="{StaticResource Switch}" Margin="0,16,0,0" FontSize="14" Content="Aggiorna i programmi ogni settimana"/>
                    <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                      <RadioButton x:Name="SetD1" Style="{StaticResource DayPill}" Content="L" Tag="Monday"/>
                      <RadioButton x:Name="SetD2" Style="{StaticResource DayPill}" Content="M" Tag="Tuesday"/>
                      <RadioButton x:Name="SetD3" Style="{StaticResource DayPill}" Content="M" Tag="Wednesday"/>
                      <RadioButton x:Name="SetD4" Style="{StaticResource DayPill}" Content="G" Tag="Thursday"/>
                      <RadioButton x:Name="SetD5" Style="{StaticResource DayPill}" Content="V" Tag="Friday"/>
                      <RadioButton x:Name="SetD6" Style="{StaticResource DayPill}" Content="S" Tag="Saturday"/>
                      <RadioButton x:Name="SetD7" Style="{StaticResource DayPill}" Content="D" Tag="Sunday"/>
                      <TextBox x:Name="SetTime" Style="{StaticResource Input}" Width="80" Margin="8,0,0,0" HorizontalContentAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                      <Button x:Name="SetSave" Style="{StaticResource AccentBtn}" Content="Salva pianificazione" Padding="18,8" FontSize="13"/>
                      <TextBlock x:Name="SetAutoInfo" Foreground="#9AA0B8" FontSize="12" VerticalAlignment="Center" Margin="14,0,0,0"/>
                    </StackPanel>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="PROGRAMMI" Style="{StaticResource CardLabel}"/>
                    <TextBlock Text="Gestisci le esclusioni dagli aggiornamenti e sposta l'elenco dei programmi su un altro PC." Foreground="#9AA0B8" FontSize="13" Margin="0,12,0,14" TextWrapping="Wrap"/>
                    <WrapPanel>
                      <Button x:Name="SetExcl" Style="{StaticResource GhostBtn}" Content="Esclusioni" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                      <Button x:Name="SetExport" Style="{StaticResource GhostBtn}" Content="Esporta elenco" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                      <Button x:Name="SetImport" Style="{StaticResource GhostBtn}" Content="Importa elenco" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="ASPETTO E AVVIO" Style="{StaticResource CardLabel}"/>
                    <CheckBox x:Name="SetLight" Style="{StaticResource Switch}" Margin="0,16,0,0" FontSize="14" Content="Tema chiaro (riavvia MultiTool)"/>
                    <CheckBox x:Name="SetTray" Style="{StaticResource Switch}" Margin="0,14,0,0" FontSize="14" Content="Riduci nell'area di notifica"/>
                    <CheckBox x:Name="SetPrefetch" Style="{StaticResource Switch}" Margin="0,14,0,0" FontSize="14" Content="Prepara tutte le sezioni all'avvio"/>
                    <TextBlock Text="Con l'icona nell'area di notifica MultiTool controlla gli aggiornamenti ogni 6 ore e ti avvisa." Foreground="#6B7290" FontSize="12" Margin="50,6,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="AGGIORNAMENTI DI MULTITOOL" Style="{StaticResource CardLabel}"/>
                    <TextBlock x:Name="SetUpdInfo" Foreground="#9AA0B8" FontSize="13" Margin="0,12,0,10" TextWrapping="Wrap"/>
                    <TextBox x:Name="SetUpdUrl" Style="{StaticResource Input}" FontSize="12"/>
                    <TextBlock Text="Indirizzo della cartella online con version.txt e MultiTool.ps1 (es. GitHub raw)." Foreground="#6B7290" FontSize="11" Margin="2,6,0,10" TextWrapping="Wrap"/>
                    <StackPanel Orientation="Horizontal">
                      <Button x:Name="SetUpdCheck" Style="{StaticResource GhostBtn}" Content="Controlla ora" Padding="16,8" FontSize="13" Margin="0,0,8,0"/>
                      <Button x:Name="SetUpdGo" Style="{StaticResource AccentBtn}" Content="Aggiorna" Padding="16,8" FontSize="13" Visibility="Collapsed"/>
                    </StackPanel>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="NEGOZIO (RAPPORTI ED ETICHETTE)" Style="{StaticResource CardLabel}"/>
                    <Grid Margin="0,12,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                      <TextBlock Text="Nome" Foreground="#9AA0B8" VerticalAlignment="Center"/>
                      <TextBox x:Name="SetShopName" Grid.Column="1" Style="{StaticResource Input}" FontSize="12" Margin="0,3" Tag="ShopName"/>
                      <TextBlock Grid.Row="1" Text="Telefono" Foreground="#9AA0B8" VerticalAlignment="Center"/>
                      <TextBox x:Name="SetShopPhone" Grid.Row="1" Grid.Column="1" Style="{StaticResource Input}" FontSize="12" Margin="0,3" Tag="ShopPhone"/>
                      <TextBlock Grid.Row="2" Text="Email" Foreground="#9AA0B8" VerticalAlignment="Center"/>
                      <TextBox x:Name="SetShopEmail" Grid.Row="2" Grid.Column="1" Style="{StaticResource Input}" FontSize="12" Margin="0,3" Tag="ShopEmail"/>
                      <TextBlock Grid.Row="3" Text="Sito web" Foreground="#9AA0B8" VerticalAlignment="Center"/>
                      <TextBox x:Name="SetShopWeb" Grid.Row="3" Grid.Column="1" Style="{StaticResource Input}" FontSize="12" Margin="0,3" Tag="ShopWeb"/>
                      <TextBlock Grid.Row="4" Text="Garanzia (mesi)" Foreground="#9AA0B8" VerticalAlignment="Center"/>
                      <TextBox x:Name="SetWarranty" Grid.Row="4" Grid.Column="1" Style="{StaticResource Input}" FontSize="12" Margin="0,3" Width="80" HorizontalAlignment="Left" Tag="WarrantyMonths"/>
                      <TextBlock Grid.Row="5" Text="Logo" Foreground="#9AA0B8" VerticalAlignment="Center"/>
                      <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal" Margin="0,3">
                        <Button x:Name="SetLogo" Style="{StaticResource GhostBtn}" Content="Scegli immagine" Padding="12,6" FontSize="12"/>
                        <TextBlock x:Name="SetLogoInfo" Foreground="#6B7290" FontSize="11" VerticalAlignment="Center" Margin="10,0,0,0" TextTrimming="CharacterEllipsis" MaxWidth="200"/>
                      </StackPanel>
                    </Grid>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="BACKUP E SENSORI" Style="{StaticResource CardLabel}"/>
                    <CheckBox x:Name="SetBkAuto" Style="{StaticResource Switch}" Margin="0,16,0,0" FontSize="14" Content="Backup automatico ogni giorno alle"/>
                    <StackPanel Orientation="Horizontal" Margin="50,8,0,0">
                      <TextBox x:Name="SetBkTime" Style="{StaticResource Input}" Width="80" FontSize="12"/>
                      <Button x:Name="SetBkSave" Style="{StaticResource GhostBtn}" Content="Salva" Padding="14,6" FontSize="12" Margin="8,0,0,0"/>
                    </StackPanel>
                    <TextBlock x:Name="SetBkInfo" Foreground="#6B7290" FontSize="12" Margin="50,6,0,0" TextWrapping="Wrap"/>
                    <CheckBox x:Name="SetSensLog" Style="{StaticResource Switch}" Margin="0,16,0,0" FontSize="14" Content="Registra temperature e ventole in background"/>
                    <TextBlock Text="Un valore ogni 30 secondi, consultabile da Hardware → Storico sensori." Foreground="#6B7290" FontSize="12" Margin="50,6,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="INSTALLAZIONE E LINGUA" Style="{StaticResource CardLabel}"/>
                    <TextBlock x:Name="SetInstInfo" Foreground="#9AA0B8" FontSize="13" Margin="0,12,0,10" TextWrapping="Wrap"/>
                    <WrapPanel>
                      <Button x:Name="SetInstall" Style="{StaticResource AccentBtn}" Content="Installa in questo PC" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                      <Button x:Name="SetUninst" Style="{StaticResource GhostBtn}" Content="Disinstalla MultiTool" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                    </WrapPanel>
                    <CheckBox x:Name="SetEnglish" Style="{StaticResource Switch}" Margin="0,8,0,0" FontSize="14" Content="English interface (riavvia MultiTool)"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="CARTELLE" Style="{StaticResource CardLabel}"/>
                    <TextBlock Text="Installer locali, profili di installazione, cronologia, log e backup dei driver." Foreground="#9AA0B8" FontSize="13" Margin="0,12,0,14" TextWrapping="Wrap"/>
                    <WrapPanel>
                      <Button x:Name="SetOpenInst" Style="{StaticResource GhostBtn}" Content="Installers" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                      <Button x:Name="SetOpenProf" Style="{StaticResource GhostBtn}" Content="Profili" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                      <Button x:Name="SetOpenData" Style="{StaticResource GhostBtn}" Content="Dati e log" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                      <Button x:Name="SetOpenRep" Style="{StaticResource GhostBtn}" Content="Rapporti" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
              </UniformGrid>
            </StackPanel>
          </ScrollViewer>

          <!-- Toast -->
          <Border x:Name="Toast" Grid.Row="1" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,70"
                  Background="#1E2232" BorderBrush="#343B55" BorderThickness="1" CornerRadius="12" Padding="18,11">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE946;" FontFamily="Segoe MDL2 Assets" Foreground="#A78BFA" VerticalAlignment="Center"/>
              <TextBlock x:Name="ToastText" Margin="10,0,0,0" FontSize="13" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$TrEn = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
$TrEn['AGGIORNAMENTI DI MULTITOOL'] = 'MULTITOOL UPDATES'
$TrEn['AGGIORNAMENTO AUTOMATICO'] = 'AUTOMATIC UPDATE'
$TrEn['ALTRO'] = 'OTHER'
$TrEn['AMBITO'] = 'SCOPE'
$TrEn['ANNULLA'] = 'CANCEL'
$TrEn['APPLICA'] = 'APPLY'
$TrEn['ASPETTO E AVVIO'] = 'APPEARANCE AND STARTUP'
$TrEn['ATTIVA'] = 'ENABLE'
$TrEn['AVVIA'] = 'START'
$TrEn['AVVIA BACKUP'] = 'START BACKUP'
$TrEn['AVVIA TEST'] = 'RUN TEST'
$TrEn['AZIONI RAPIDE'] = 'QUICK ACTIONS'
$TrEn['Aggiorna'] = 'Refresh'
$TrEn['Aggiorna i programmi ogni settimana'] = 'Update apps every week'
$TrEn['Aggiorna programmi'] = 'Update apps'
$TrEn['Aggiornamenti di sistema'] = 'System updates'
$TrEn['Analisi di winget e Microsoft Store…'] = 'Checking winget and Microsoft Store…'
$TrEn['Apri backup'] = 'Open backup'
$TrEn['Apri cartella'] = 'Open folder'
$TrEn['Apri cartella profili'] = 'Open profiles folder'
$TrEn['Apri log'] = 'Open logs'
$TrEn['Apri rapporto'] = 'Open report'
$TrEn['Attiva sensori avanzati'] = 'Enable advanced sensors'
$TrEn['Avvio automatico'] = 'Startup apps'
$TrEn['BACKUP E SENSORI'] = 'BACKUP AND SENSORS'
$TrEn['Backup automatico ogni giorno alle'] = 'Automatic daily backup at'
$TrEn['Backup driver'] = 'Back up drivers'
$TrEn['CARTELLE'] = 'FOLDERS'
$TrEn['CORREGGI'] = 'FIX'
$TrEn['CORRISPONDENZA'] = 'MATCH'
$TrEn['CREA PUNTO'] = 'CREATE POINT'
$TrEn['Calcolo delle cartelle…'] = 'Measuring folders…'
$TrEn['Calcolo dello spazio recuperabile…'] = 'Measuring reclaimable space…'
$TrEn['Catalogo winget'] = 'winget catalog'
$TrEn['Cerca'] = 'Search'
$TrEn['Cerca tra migliaia di programmi e installali senza scaricare nulla a mano.'] = 'Search thousands of apps and install them without downloading anything by hand.'
$TrEn['Cerca un programma'] = 'Search for an app'
$TrEn['Collega un cavo o una rete Wi-Fi.'] = 'Connect a cable or a Wi-Fi network.'
$TrEn['Componenti, firmware e sensori del PC.'] = 'PC components, firmware and sensors.'
$TrEn['Con l''icona nell''area di notifica MultiTool controlla gli aggiornamenti ogni 6 ore e ti avvisa.'] = 'With the tray icon MultiTool checks for updates every 6 hours and notifies you.'
$TrEn['Controlla ora'] = 'Check now'
$TrEn['Controllo delle protezioni…'] = 'Checking protections…'
$TrEn['Controllo dello stato dei driver…'] = 'Checking drivers…'
$TrEn['Copia file .exe, .msi, .msix o .appx nella cartella Installers, poi premi Ricarica.'] = 'Copy .exe, .msi, .msix or .appx files into the Installers folder, then press Reload.'
$TrEn['Crea un file .json nella cartella Profili (vedi gli esempi inclusi).'] = 'Create a .json file in the Profiles folder (see the included examples).'
$TrEn['Crea un punto di ripristino prima delle modifiche'] = 'Create a restore point before changes'
$TrEn['Cronologia'] = 'History'
$TrEn['DATA'] = 'DATE'
$TrEn['DIMENSIONE'] = 'SIZE'
$TrEn['DISATTIVA'] = 'DISABLE'
$TrEn['DISINSTALLA'] = 'UNINSTALL'
$TrEn['Dati del negozio'] = 'Shop details'
$TrEn['Dati e log'] = 'Data and logs'
$TrEn['Dettagli  &#x2192;'] = 'Details  &#x2192;'
$TrEn['Dettagli  →'] = 'Details  →'
$TrEn['Diagnosi della connessione…'] = 'Diagnosing the connection…'
$TrEn['Disinstalla'] = 'Uninstall'
$TrEn['Disinstalla MultiTool'] = 'Uninstall MultiTool'
$TrEn['Elenco vuoto'] = 'Empty list'
$TrEn['Elimina il più vecchio'] = 'Delete the oldest'
$TrEn['Elimina log'] = 'Delete logs'
$TrEn['English interface (riavvia MultiTool)'] = 'English interface (restarts MultiTool)'
$TrEn['Errori del programma, riparazioni e attività registrate.'] = 'App errors, repairs and recorded activity.'
$TrEn['Escludi selezionati'] = 'Exclude selected'
$TrEn['Esclusioni'] = 'Exclusions'
$TrEn['Esporta elenco'] = 'Export list'
$TrEn['Esporta inventario'] = 'Export inventory'
$TrEn['Etichetta QR'] = 'QR label'
$TrEn['Garanzia (mesi)'] = 'Warranty (months)'
$TrEn['Gestione attività'] = 'Task Manager'
$TrEn['Gestione dispositivi'] = 'Device Manager'
$TrEn['Gestisci le esclusioni dagli aggiornamenti e sposta l''elenco dei programmi su un altro PC.'] = 'Manage update exclusions and move your app list to another PC.'
$TrEn['Gruppi di programmi da installare in un colpo solo.'] = 'Groups of apps to install in one go.'
$TrEn['INSTALLA'] = 'INSTALL'
$TrEn['INSTALLA PROFILI'] = 'INSTALL PROFILES'
$TrEn['INSTALLATA'] = 'INSTALLED'
$TrEn['INSTALLAZIONE E LINGUA'] = 'INSTALLATION AND LANGUAGE'
$TrEn['Il file non contiene pacchetti winget validi.'] = 'The file contains no valid winget packages.'
$TrEn['Importa elenco'] = 'Import list'
$TrEn['Impostazioni'] = 'Settings'
$TrEn['Impostazioni Windows Update'] = 'Windows Update settings'
$TrEn['In "Aggiorna programmi" seleziona un programma e premi "Escludi selezionati".'] = 'In "Update apps" select an app and press "Exclude selected".'
$TrEn['Indirizzo della cartella online con version.txt e MultiTool.ps1 (es. GitHub raw).'] = 'Address of the online folder with version.txt and MultiTool.ps1 (e.g. GitHub raw).'
$TrEn['Installa in questo PC'] = 'Install on this PC'
$TrEn['Installer locali'] = 'Local installers'
$TrEn['Installer locali, profili di installazione, cronologia, log e backup dei driver.'] = 'Local installers, install profiles, history, logs and driver backups.'
$TrEn['Lettura dei programmi all''avvio…'] = 'Reading startup apps…'
$TrEn['Lettura dei programmi installati…'] = 'Reading installed apps…'
$TrEn['Lettura dei punti di ripristino…'] = 'Reading restore points…'
$TrEn['Lettura del file…'] = 'Reading file…'
$TrEn['Lettura della cartella Installers…'] = 'Reading the Installers folder…'
$TrEn['Lettura della cronologia…'] = 'Reading history…'
$TrEn['Lettura delle impostazioni…'] = 'Reading settings…'
$TrEn['Libera spazio'] = 'Free up space'
$TrEn['LOCALI'] = 'LOCAL'
$TrEn['MEMORIA'] = 'MEMORY'
$TrEn['MODALITÀ'] = 'MODE'
$TrEn['Manutenzione completa'] = 'Full maintenance'
$TrEn['NEGOZIO (RAPPORTI ED ETICHETTE)'] = 'SHOP (REPORTS AND LABELS)'
$TrEn['NEL BACKUP'] = 'IN BACKUP'
$TrEn['NOME'] = 'NAME'
$TrEn['NUOVA'] = 'NEW'
$TrEn['Nessun aggiornamento di sistema in attesa.'] = 'No pending system updates.'
$TrEn['Nessun driver da segnalare'] = 'No driver issues'
$TrEn['Nessun installer trovato'] = 'No installers found'
$TrEn['Nessun problema e nessun driver di terze parti rilevato.'] = 'No problems and no third-party drivers found.'
$TrEn['Nessun profilo'] = 'No profiles'
$TrEn['Nessun programma'] = 'No apps'
$TrEn['Nessun programma all''avvio'] = 'No startup apps'
$TrEn['Nessun punto di ripristino'] = 'No restore points'
$TrEn['Nessuna cartella'] = 'No folders'
$TrEn['Nessuna esclusione'] = 'No exclusions'
$TrEn['Nessuna operazione registrata'] = 'No recorded operations'
$TrEn['Nessuna rete connessa'] = 'No network connected'
$TrEn['Nessuno'] = 'None'
$TrEn['Niente da pulire'] = 'Nothing to clean'
$TrEn['Nome'] = 'Name'
$TrEn['Non ho trovato programmi disinstallabili.'] = 'No uninstallable apps found.'
$TrEn['ORA'] = 'NOW'
$TrEn['ORIGINE'] = 'SOURCE'
$TrEn['PRECEDENTE'] = 'PREVIOUS'
$TrEn['PROCEDI'] = 'PROCEED'
$TrEn['PROCESSORE'] = 'PROCESSOR'
$TrEn['PROGRAMMI'] = 'APPS'
$TrEn['PROTEZIONE'] = 'PROTECTION'
$TrEn['PULISCI'] = 'CLEAN'
$TrEn['Premi CREA PUNTO: verrà attivata anche la protezione sistema.'] = 'Press CREATE POINT: system protection will be enabled too.'
$TrEn['Preparazione consegna'] = 'Delivery prep'
$TrEn['Profili'] = 'Profiles'
$TrEn['Programmi che non verranno mai aggiornati.'] = 'Apps that will never be updated.'
$TrEn['Programmi e funzionalità'] = 'Programs and Features'
$TrEn['Pulizia disco'] = 'Disk cleanup'
$TrEn['Punti di ripristino'] = 'Restore points'
$TrEn['Qui troverai aggiornamenti, installazioni e pulizie eseguite.'] = 'Updates, installs and cleanups will appear here.'
$TrEn['RIMUOVI ESCLUSIONE'] = 'REMOVE EXCLUSION'
$TrEn['RIPARA CONNESSIONE'] = 'REPAIR CONNECTION'
$TrEn['RIPRISTINA'] = 'RESTORE'
$TrEn['Raccolgo le informazioni sul sistema…'] = 'Collecting system information…'
$TrEn['Rapporti'] = 'Reports'
$TrEn['Registra temperature e ventole in background'] = 'Log temperatures and fans in background'
$TrEn['Rete'] = 'Network'
$TrEn['Riavvia ora'] = 'Restart now'
$TrEn['Ricalcola'] = 'Recalculate'
$TrEn['Ricarica'] = 'Reload'
$TrEn['Ricerca aggiornamenti di Windows…'] = 'Searching for Windows updates…'
$TrEn['Ricerca di nuovo'] = 'Search again'
$TrEn['Ricontrolla'] = 'Check again'
$TrEn['Riduci nell''area di notifica'] = 'Minimize to tray'
$TrEn['Prepara tutte le sezioni all''avvio'] = 'Prepare all sections at startup'
$TrEn['Riparazione'] = 'Repair'
$TrEn['Ripristina driver da backup'] = 'Restore drivers from backup'
$TrEn['SALUTE HARDWARE'] = 'HARDWARE HEALTH'
$TrEn['SENSORI IN TEMPO REALE'] = 'LIVE SENSORS'
$TrEn['SICUREZZA'] = 'SECURITY'
$TrEn['SISTEMA'] = 'SYSTEM'
$TrEn['SPAZIO SU DISCO'] = 'DISK SPACE'
$TrEn['STATO'] = 'STATUS'
$TrEn['Salva'] = 'Save'
$TrEn['Salva pianificazione'] = 'Save schedule'
$TrEn['Scegli destinazione'] = 'Choose destination'
$TrEn['Scegli immagine'] = 'Choose image'
$TrEn['Scrivi un nome, ad esempio "vlc", "firefox" o "7zip", e premi Invio.'] = 'Type a name, e.g. "vlc", "firefox" or "7zip", and press Enter.'
$TrEn['Servizio offerto da:'] = 'Powered by:'
$TrEn['Sicurezza'] = 'Security'
$TrEn['Sicurezza di Windows'] = 'Windows Security'
$TrEn['Sicurezza, automazione e gestione dei dati.'] = 'Security, automation and data management.'
$TrEn['Silenziosa'] = 'Silent'
$TrEn['Sito web'] = 'Website'
$TrEn['Solo etichetta QR'] = 'QR label only'
$TrEn['Storico sensori'] = 'Sensor history'
$TrEn['Svuota cronologia'] = 'Clear history'
$TrEn['TEST VELOCITÀ'] = 'SPEED TEST'
$TrEn['TIPO'] = 'TYPE'
$TrEn['Telefono'] = 'Phone'
$TrEn['Tema chiaro (riavvia MultiTool)'] = 'Light theme (restarts MultiTool)'
$TrEn['Tutti'] = 'All'
$TrEn['Tutto aggiornato'] = 'All up to date'
$TrEn['Tutto in un clic'] = 'All in one click'
$TrEn['Un valore ogni 30 secondi, consultabile da Hardware → Storico sensori.'] = 'One value every 30 seconds, viewable in Hardware → Sensor history.'
$TrEn['VALORE'] = 'VALUE'
$TrEn['VELOCITÀ'] = 'SPEED'
$TrEn['VERSIONE'] = 'VERSION'
$TrEn['Vale per aggiornamenti, installazioni, driver e disinstallazioni.'] = 'Applies to updates, installs, drivers and uninstalls.'
$TrEn['Windows parte già leggero.'] = 'Windows already starts light.'
$TrEn['Windows è aggiornato'] = 'Windows is up to date'
$TrEn['winget non ha trovato aggiornamenti disponibili.'] = 'winget found no available updates.'
$TrEn['È necessario un riavvio per completare alcune modifiche.'] = 'A restart is needed to complete some changes.'
$TrEn['Elenco'] = 'List'
$TrEn['CHIUDI'] = 'CLOSE'
$TrEn['Operazione completata.'] = 'Done.'
$TrEn['ESITO'] = 'RESULT'
$TrEn['STATO DRIVER'] = 'DRIVER STATUS'
$TrEn['AVVIO'] = 'STARTUP'
$TrEn['Stato e problemi'] = 'Status and issues'
$TrEn['Aggiorna programmi '] = 'Update apps'
$TrEn['Riparazione di sistema'] = 'System repair'
$TrEn['Benchmark'] = 'Benchmark'
$TrEn['Backup'] = 'Backup'
$TrEn['Hardware'] = 'Hardware'
$TrEn['Privacy'] = 'Privacy'
$TrEn['Log'] = 'Logs'
$TrEn['Driver'] = 'Drivers'
$TrEn['Home'] = 'Home'
$TrEn['Analisi in corso…'] = 'Analysing…'
$TrEn['Componenti'] = 'Components'
$TrEn['Disinstalla programmi'] = 'Uninstall apps'
function T([string]$t) { if ($Settings.Lang -eq 'en' -and $TrEn.ContainsKey($t)) { $TrEn[$t] } else { $t } }
function Apply-Lang([string]$Text) {
    if ($Settings.Lang -ne 'en') { return $Text }
    [regex]::Replace($Text, '(Text|Content)="([^"]*)"', { param($m) $v = [Net.WebUtility]::HtmlDecode($m.Groups[2].Value); if ($TrEn.ContainsKey($v)) { "$($m.Groups[1].Value)=`"$([Security.SecurityElement]::Escape($TrEn[$v]))`"" } else { $m.Value } })
}
$xaml = Apply-Lang (Apply-Theme $xaml)
$win = [Windows.Markup.XamlReader]::Parse($xaml)
$IcoPath = Join-Path $Root 'MultiTool.ico'
if (Test-Path $IcoPath) { try { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([uri]$IcoPath) } catch {} }
$ui = @{}
foreach ($m in [regex]::Matches($xaml, 'x:Name="(\w+)"')) {
    $el = $win.FindName($m.Groups[1].Value)
    if ($el) { $ui[$m.Groups[1].Value] = $el }
}

# ============================================================
#  Stato e runspace
# ============================================================
$sync  = [hashtable]::Synchronized(@{ Phase = 'idle'; Token = 0 })
$State = @{ Mode = $null; InfoPending = $false; Pending = $false; ToastUntil = [datetime]::MinValue; Q = (New-Object System.Collections.ArrayList); Tick = 0; Report = $null }
$Items = New-Object System.Collections.ObjectModel.ObservableCollection[MtItem]
$ui.LList.ItemsSource = $Items

function Start-Bg([string]$Code, [hashtable]$Vars) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $base = @{ sync = $sync; DataDir = $DataDir; InstDir = $InstDir; ProfDir = $ProfDir; area = 'MultiTool' }
    foreach ($k in $base.Keys) { $rs.SessionStateProxy.SetVariable($k, $base[$k]) }
    if ($Vars) { foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) } }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Helpers + "`n" + $Code)
    [void]$Jobs.Add(@{ PS = $ps; H = $ps.BeginInvoke() })
}
$Jobs = New-Object System.Collections.ArrayList
function Clear-Jobs {
    foreach ($j in @($Jobs.ToArray())) {
        if ($j.H.IsCompleted) {
            try { [void]$j.PS.EndInvoke($j.H) } catch { Write-ErrLog "Job: $($_.Exception.Message)" }
            foreach ($e in $j.PS.Streams.Error) { Write-ErrLog "Job: $e" }
            try { $j.PS.Runspace.Dispose(); $j.PS.Dispose() } catch {}
            $Jobs.Remove($j)
        }
    }
}

function G([int]$c) { [string][char]$c }
function Vis($b) { if ($b) { 'Visible' } else { 'Collapsed' } }
function Toast([string]$t) { [void]$State.Q.Add($t) }

# ============================================================
#  Codice delle analisi e delle azioni (eseguito in background)
# ============================================================
$ScanUpdates = @'
$excl = Read-Exclusions
$sync.Status = 'Avvio la scansione del Microsoft Store…'
Start-StoreScan
$sync.Status = 'Interrogo winget, attendi qualche secondo…'
$r = Invoke-Hidden (Get-WingetPath) 'upgrade --include-unknown --accept-source-agreements --disable-interactivity'
foreach ($t in ConvertFrom-WingetTable $r.Out) {
    $c = $t.Cols
    if ($c.Count -lt 4) { continue }
    $src = if ($c.Count -ge 5) { $c[4] } else { '' }
    $ex  = $excl -contains $c[1]
    $cut = $c[1] -match '…$'
    $rows.Add((New-Row @{ Name = $c[0]; Sub = $c[1]; Key = $c[1]; C1 = $c[2]; C2 = $c[3]; Arrow = $true; Data = $src
        Tag = $(if ($ex) { 'escluso' } else { $src }); TagKind = $(if ($ex) { 'warn' } else { 'none' }); Selected = (-not $ex -and -not $cut)
        Checkable = (-not $cut); Status = $(if ($cut) { 'ID troncato' } else { '' }); StatusKind = $(if ($cut) { 'skip' } else { 'none' }) }))
}
$n = $rows.Count
$sync.ScanInfo = if ($n) { "Trovati $n aggiornamenti. Controlla l'elenco, poi scegli se procedere." } else { $null }
'@

$ActUpdates = @'
Invoke-Each $items {
    param($it)
    $r = Invoke-Winget 'upgrade' $it.Key ([string]$it.Data) $it
    $k, $t = Get-WingetResult $r.Code 'Aggiornato'
    Set-It $it $k $t
} 'Aggiorno'
'@

$ActWingetInstall = @'
Invoke-Each $items {
    param($it)
    $r = Invoke-Winget 'install' $it.Key ([string]$it.Data) $it
    $k, $t = Get-WingetResult $r.Code 'Installato'
    Set-It $it $k $t
} 'Installo'
'@

$ScanWU = @'
$sync.Status = 'Cerco aggiornamenti di Windows… può richiedere qualche minuto'
$s = New-Object -ComObject Microsoft.Update.Session
$s.ClientApplicationID = 'MultiTool'
$sr = $s.CreateUpdateSearcher(); $sr.ServerSelection = 2; $sr.Online = $true
$res = $sr.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
foreach ($u in $res.Updates) {
    $kb  = (@($u.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
    $cat = @($u.Categories) | Select-Object -First 1 | ForEach-Object { $_.Name }
    $tag = if ($u.MsrcSeverity) { $u.MsrcSeverity } elseif ($u.BrowseOnly) { 'Facoltativo' } else { 'Consigliato' }
    $kind = if ($u.MsrcSeverity -eq 'Critical') { 'err' } elseif ($u.BrowseOnly) { 'none' } else { 'info' }
    $rows.Add((New-Row @{ Name = $u.Title; Sub = ((@($kb, $cat) | Where-Object { $_ }) -join '  ·  '); Key = $u.Identity.UpdateID
        C1 = (Format-Size ([double]$u.MaxDownloadSize)); Tag = $tag; TagKind = $kind; Selected = (-not $u.BrowseOnly) }))
}
$n = $rows.Count
$sync.ScanInfo = if ($n) { "$n aggiornamenti disponibili. I facoltativi non sono selezionati." } else { $null }
'@

$ActWU = @'
Install-WU $items 'Software'
'@

$ScanDrivers = @'
$nProb = 0; $nOld = 0; $nUns = 0
$sync.Status = 'Controllo i dispositivi con problemi…'
foreach ($d in Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue) {
    $nProb++
    $rows.Add((New-Row @{ Name = $(if ($d.Name) { $d.Name } else { $d.DeviceID }); Sub = "Codice errore $($d.ConfigManagerErrorCode)  ·  $($d.PNPClass)"
        Tag = 'problema'; TagKind = 'err'; Checkable = $false; Glyph = [string][char]0xE7BA })) | Out-Null
}
$sync.Status = 'Analizzo i driver installati…'
$seen = @{}
$drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
       Where-Object { $_.DeviceName -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' } | Sort-Object DeviceName
foreach ($d in $drv) {
    $k = "$($d.DeviceName)|$($d.DriverVersion)"
    if ($seen[$k]) { continue }; $seen[$k] = 1
    $date = $d.DriverDate
    $age  = if ($date) { ((Get-Date) - $date).TotalDays / 365 } else { 0 }
    if ($d.IsSigned -eq $false) { $tag = 'non firmato'; $kind = 'err'; $nUns++ }
    elseif ($age -gt 5)          { $tag = 'datato'; $kind = 'warn'; $nOld++ }
    else                         { $tag = 'ok'; $kind = 'ok' }
    $rows.Add((New-Row @{ Name = $d.DeviceName; Sub = "$($d.DriverProviderName)  ·  $($d.DeviceClass)"; C1 = $d.DriverVersion
        C2 = $(if ($date) { $date.ToString('dd/MM/yyyy') } else { '' }); Tag = $tag; TagKind = $kind; Checkable = $false })) | Out-Null
}
$sorted = @($rows | Sort-Object @{ e = { switch ($_.TagKind) { 'err' { 0 } 'warn' { 1 } default { 2 } } } }, @{ e = { $_.Name } })
$rows.Clear(); foreach ($r in $sorted) { [void]$rows.Add($r) }
$sync.ScanInfo = "$($rows.Count) driver di terze parti  ·  $nProb dispositivi con problemi  ·  $nUns non firmati  ·  $nOld oltre 5 anni"
'@

$ScanInstallers = @'
$exts = '.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle', '.bat', '.cmd'
$files = Get-ChildItem -Path $InstDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $exts -contains $_.Extension.ToLower() } | Sort-Object Name
foreach ($f in $files) {
    $rel = Split-Path ($f.FullName.Substring($InstDir.Length).TrimStart('\')) -Parent
    $hasArgs = Test-Path "$($f.FullName).args"
    $det = @()
    if ($rel) { $det += $rel }
    if ($hasArgs) { $det += 'parametri: ' + (Get-Content "$($f.FullName).args" -Raw).Trim() }
    $silentOk = $hasArgs -or ($f.Extension -match 'msi|appx|msix')
    $rows.Add((New-Row @{ Name = $f.Name; Sub = ($det -join '  ·  '); Key = $f.FullName; C1 = $f.Extension.TrimStart('.').ToUpper()
        C2 = (Format-Size $f.Length); Tag = $(if ($silentOk) { 'silenziosa' } else { 'guidata' }); TagKind = $(if ($silentOk) { 'ok' } else { 'none' }) }))
}
$sync.ScanInfo = if ($rows.Count) { "$($rows.Count) installer nella cartella. Per gli .exe silenziosi crea un file nome.exe.args con i parametri." } else { $null }
'@

$ActInstallers = @'
Invoke-Each $items {
    param($it)
    $code = Install-Local $it.Key $silent
    Set-ExitResult $it $code 'Installato'
} 'Installo'
'@

$ScanCatalog = @'
$sync.Status = "Cerco `"$query`" nel catalogo…"
$r = Invoke-Hidden (Get-WingetPath) ("search `"$query`" --accept-source-agreements --disable-interactivity")
foreach ($t in ConvertFrom-WingetTable $r.Out) {
    $c = $t.Cols
    $src = if ($c.Count -ge 4) { $c[-1] } else { '' }
    $cut = $c[1] -match '…$'
    $rows.Add((New-Row @{ Name = $c[0]; Sub = $c[1]; Key = $c[1]; C1 = $c[2]; C2 = $(if ($c.Count -ge 5) { $c[3] } else { '' }); Tag = $src; Data = $src
        Checkable = (-not $cut); Status = $(if ($cut) { 'ID troncato' } else { '' }); StatusKind = $(if ($cut) { 'skip' } else { 'none' }) }))
}
$sync.ScanInfo = if ($rows.Count) { "$($rows.Count) risultati per `"$query`"." } else { $null }
'@

$ScanProfiles = @'
foreach ($f in Get-ChildItem $ProfDir -Filter *.json -ErrorAction SilentlyContinue) {
    try { $p = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    $wg = @(@($p.winget) | Where-Object { $_ }); $lc = @(@($p.local) | Where-Object { $_ })
    $rows.Add((New-Row @{ Name = $(if ($p.name) { $p.name } else { $f.BaseName }); Sub = $(if ($p.description) { $p.description } else { $f.Name })
        Key = $f.FullName; C1 = "$($wg.Count) pacchetti"; C2 = "$($lc.Count) file" }))
}
'@

$ActProfiles = @'
Invoke-Each $items { param($it) Install-Profile $it $it.Key $silent } 'Installo il profilo'
'@

$ScanImport = @'
$j = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($src in @($j.Sources)) {
    $sn = $src.SourceDetails.Name
    foreach ($p in @($src.Packages)) {
        $rows.Add((New-Row @{ Name = $p.PackageIdentifier; Sub = "da $([IO.Path]::GetFileName($file))"; Key = $p.PackageIdentifier; Tag = $sn; Data = $sn; Selected = $true }))
    }
}
$sync.ScanInfo = "$($rows.Count) pacchetti nell'elenco importato."
'@

$ScanUninstall = @'
$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
$seen = @{}
$list = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.UninstallString -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName -and $_.ReleaseType -notmatch 'Update|Hotfix' } |
        Sort-Object DisplayName
foreach ($e in $list) {
    $k = "$($e.DisplayName)|$($e.DisplayVersion)"
    if ($seen[$k]) { continue }; $seen[$k] = 1
    $msi = ($e.WindowsInstaller -eq 1) -and ($e.PSChildName -match '^\{.+\}$')
    $tag = if ($msi) { 'MSI' } elseif ($e.QuietUninstallString) { 'silenziosa' } else { 'guidata' }
    $rows.Add((New-Row @{ Name = $e.DisplayName; Sub = [string]$e.Publisher; Key = $e.PSChildName; C1 = [string]$e.DisplayVersion
        C2 = $(if ($e.EstimatedSize) { Format-Size ([double]$e.EstimatedSize * 1KB) } else { '' }); Tag = $tag
        Data = @{ Msi = $msi; Quiet = [string]$e.QuietUninstallString; Cmd = [string]$e.UninstallString } }))
}
foreach ($a in Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -eq 'Store' } | Sort-Object Name) {
    $nm = ($a.Name -replace '^[^\.]+\.', '') -replace '([a-z])([A-Z])', '$1 $2'
    $rows.Add((New-Row @{ Name = $nm; Sub = "$($a.Publisher -replace '^CN=([^,]+).*', '$1')  ·  app Microsoft Store"; Key = $a.PackageFullName
        C1 = [string]$a.Version; Tag = 'Store'; TagKind = 'info'; Data = @{ Appx = $a.PackageFullName } }))
}
$sync.ScanInfo = "$($rows.Count) programmi e app installati."
'@

$ActUninstall = @'
Invoke-Each $items {
    param($it)
    $d = $it.Data
    $t0 = Get-Date
    if ($d.Appx) {
        Remove-AppxPackage -Package $d.Appx -ErrorAction Stop
        Set-It $it 'ok' 'Disinstallato'; return
    }
    if ($d.Msi) {
        $a = "/x $($it.Key)" + $(if ($silent) { ' /qn /norestart' } else { '' })
        $code = Run-Wait 'msiexec.exe' $a $env:SystemRoot 'Normal'
    } else {
        $cmd = if ($silent -and $d.Quiet) { $d.Quiet } else { $d.Cmd }
        $f, $a = Split-CommandLine $cmd
        if ($f -match 'msiexec') { $a = $a -replace '/I', '/X'; if ($silent) { $a += ' /qn /norestart' } }
        $dir = $env:SystemRoot
        try { $dir = Split-Path $f -ErrorAction Stop } catch {}
        $code = Run-Wait $f $a $dir 'Normal'
        $it.Status = 'Attendo il disinstallatore…'
        Wait-Uninstallers $t0
    }
    Set-ExitResult $it $code 'Disinstallato'
} 'Disinstallo'
'@

$ScanStartup = @'
$base = 'Software\Microsoft\Windows\CurrentVersion'
$defs = @(
    @{ Scope = 'Utente';           Reg = "HKCU:\$base\Run";                  Appr = "HKCU:\$base\Explorer\StartupApproved\Run" }
    @{ Scope = 'Sistema';          Reg = "HKLM:\$base\Run";                  Appr = "HKLM:\$base\Explorer\StartupApproved\Run" }
    @{ Scope = 'Sistema 32 bit';   Reg = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Appr = "HKLM:\$base\Explorer\StartupApproved\Run32" }
)
function Test-Approved($key, $name) {
    try { $v = (Get-Item $key -ErrorAction Stop).GetValue($name); if ($v -is [byte[]] -and $v.Length) { return -not ($v[0] -band 1) } } catch {}
    $true
}
foreach ($d in $defs) {
    if (-not (Test-Path $d.Reg)) { continue }
    $key = Get-Item $d.Reg
    foreach ($n in $key.GetValueNames()) {
        if (-not $n) { continue }
        $en = Test-Approved $d.Appr $n
        $rows.Add((New-Row @{ Name = $n; Sub = [string]$key.GetValue($n); C1 = $d.Scope; Key = $n; Data = @{ Appr = $d.Appr; Name = $n }
            Tag = $(if ($en) { 'attivo' } else { 'disattivato' }); TagKind = $(if ($en) { 'ok' } else { 'warn' }) }))
    }
}
$folders = @(
    @{ Scope = 'Cartella utente'; Dir = [Environment]::GetFolderPath('Startup');       Appr = "HKCU:\$base\Explorer\StartupApproved\StartupFolder" }
    @{ Scope = 'Cartella comune'; Dir = [Environment]::GetFolderPath('CommonStartup'); Appr = "HKLM:\$base\Explorer\StartupApproved\StartupFolder" }
)
foreach ($d in $folders) {
    foreach ($f in Get-ChildItem $d.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
        $en = Test-Approved $d.Appr $f.Name
        $rows.Add((New-Row @{ Name = $f.BaseName; Sub = $f.FullName; C1 = $d.Scope; Key = $f.Name; Data = @{ Appr = $d.Appr; Name = $f.Name }
            Tag = $(if ($en) { 'attivo' } else { 'disattivato' }); TagKind = $(if ($en) { 'ok' } else { 'warn' }) }))
    }
}
foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.TaskName -notlike 'MultiTool*' }) {
    $trig = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -match 'LogonTrigger|BootTrigger' })
    if (-not $trig.Count) { continue }
    $en = $t.State -ne 'Disabled'
    $exe = (@($t.Actions) | Select-Object -First 1).Execute
    $rows.Add((New-Row @{ Name = $t.TaskName; Sub = [string]$exe; C1 = 'Attività pianificata'; Key = $t.TaskName; Data = @{ Task = $t.TaskName; TPath = $t.TaskPath }
        Tag = $(if ($en) { 'attivo' } else { 'disattivato' }); TagKind = $(if ($en) { 'ok' } else { 'warn' }) }))
}
$on = @($rows | Where-Object { $_.Tag -eq 'attivo' }).Count
$sync.ScanInfo = "$($rows.Count) programmi all'avvio, $on attivi. Seleziona e scegli ATTIVA o DISATTIVA."
'@

$ActStartup = @'
$verb = if ($op -eq 'disable') { 'Disattivo' } else { 'Attivo' }
Invoke-Each $items {
    param($it)
    $d = $it.Data
    if ($d.Task) {
        if ($op -eq 'disable') { Disable-ScheduledTask -TaskName $d.Task -TaskPath $d.TPath -ErrorAction Stop | Out-Null }
        else { Enable-ScheduledTask -TaskName $d.Task -TaskPath $d.TPath -ErrorAction Stop | Out-Null }
    } else {
        if (-not (Test-Path $d.Appr)) { New-Item -Path $d.Appr -Force | Out-Null }
        $first = if ($op -eq 'disable') { 3 } else { 2 }
        [byte[]]$b = @($first) + @(0) * 11
        Set-ItemProperty -Path $d.Appr -Name $d.Name -Value $b -Type Binary
    }
    if ($op -eq 'disable') { $it.Tag = 'disattivato'; $it.TagKind = 'warn'; Set-It $it 'ok' 'Disattivato' }
    else                   { $it.Tag = 'attivo'; $it.TagKind = 'ok'; Set-It $it 'ok' 'Attivato' }
} $verb
'@

$ScanCleanup = @'
$tot = 0
foreach ($t in Get-CleanTargets) {
    $sync.Status = "Calcolo: $($t.Name)…"
    $size = if ($t.Id -eq 'recycle') { Get-RecycleSize } else { Get-DirSize $t.Paths $t.Age }
    $tot += $size
    $rows.Add((New-Row @{ Name = $t.Name; Sub = $t.Desc; Key = $t.Id; C1 = (Format-Size $size); Data = [double]$size
        Selected = ($size -gt 0 -and $t.Def); Tag = $(if ($size -ge 1GB) { 'molto spazio' } else { '' }); TagKind = 'warn' }))
}
$sync.ScanInfo = "Spazio recuperabile: $(Format-Size $tot)"
'@

$ActCleanup = @'
$sync.Freed = 0
Invoke-Each $items {
    param($it)
    $t = Get-CleanTargets | Where-Object { $_.Id -eq $it.Key }
    $r = Invoke-CleanTarget $t
    $sync.Freed += $r.Freed
    $it.C1 = Format-Size $r.After
    Set-It $it 'ok' ("Liberati " + (Format-Size $r.Freed))
} 'Pulisco'
$sync.Extra = "Spazio liberato: $(Format-Size $sync.Freed)"
'@

$ScanRepair = @'
$rows.Add((New-Row @{ Name = 'Ripristino immagine di Windows (DISM)'; Sub = 'DISM /Online /Cleanup-Image /RestoreHealth  ·  10-20 minuti'; Key = 'dism'; Selected = $true }))
$rows.Add((New-Row @{ Name = 'Controllo file di sistema (SFC)'; Sub = 'sfc /scannow  ·  5-15 minuti'; Key = 'sfc'; Selected = $true }))
$rows.Add((New-Row @{ Name = 'Analisi del disco di sistema (CHKDSK)'; Sub = "chkdsk $env:SystemDrive /scan  ·  sola lettura"; Key = 'chkdsk'; Selected = $false }))
$sync.ScanInfo = 'Esegui prima DISM e poi SFC. Puoi continuare a usare il PC nel frattempo.'
'@

$ActRepair = @'
$oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
$logDir = Join-Path $DataDir 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Invoke-Each $items {
    param($it)
    $cb = { param($l) $it.Sub = $l }
    switch ($it.Key) {
        'dism' {
            $r = Invoke-Live "$env:SystemRoot\System32\dism.exe" '/Online /Cleanup-Image /RestoreHealth' $oem $cb
            if ($r.Code -eq 0) { Set-It $it 'ok' 'Completato' } else { Set-It $it 'err' ('Errore 0x{0:X8}' -f $r.Code) }
        }
        'sfc' {
            $r = Invoke-Live "$env:SystemRoot\System32\sfc.exe" '/scannow' ([Text.Encoding]::Unicode) $cb
            if ($r.Out -match 'impossibile|unable to fix|non è stato possibile') { Set-It $it 'err' 'Non risolti' }
            elseif ($r.Out -match 'riparat|successfully repaired') { Set-It $it 'ok' 'Riparato' }
            else { Set-It $it 'ok' 'Nessun problema' }
        }
        'chkdsk' {
            $r = Invoke-Live "$env:SystemRoot\System32\chkdsk.exe" "$env:SystemDrive /scan" $oem $cb
            if ($r.Code -eq 0) { Set-It $it 'ok' 'Nessun errore' } else { Set-It $it 'err' 'Errori trovati' }
        }
    }
    $r.Out | Set-Content (Join-Path $logDir ("$($it.Key)-" + (Get-Date -Format 'yyyyMMdd-HHmm') + '.log')) -Encoding UTF8
    $it.Sub = 'Log completo salvato in Dati\Logs'
} 'Eseguo'
'@

$ScanHistory = @'
$p = Join-Path $DataDir 'history.jsonl'
if (Test-Path $p) {
    $lines = @(Get-Content $p -Encoding UTF8 -Tail 500)
    [array]::Reverse($lines)
    foreach ($l in $lines) {
        try { $h = $l | ConvertFrom-Json } catch { continue }
        $rows.Add((New-Row @{ Name = $h.Name; Sub = $h.Area; C1 = ([datetime]$h.Time).ToString('dd/MM/yy HH:mm'); Tag = $h.Result; TagKind = $h.Kind; Checkable = $false }))
    }
}
$sync.ScanInfo = if ($rows.Count) { "Ultime $($rows.Count) operazioni." } else { $null }
'@

$ScanExclusions = @'
foreach ($id in Read-Exclusions) { $rows.Add((New-Row @{ Name = $id; Sub = 'Escluso dagli aggiornamenti manuali e automatici'; Key = $id })) }
'@

$ActExclusions = @'
$ex = [System.Collections.ArrayList]@(Read-Exclusions)
Invoke-Each $items { param($it) $ex.Remove($it.Key); Set-It $it 'ok' 'Rimosso' } 'Rimuovo'
Save-Json 'exclusions.json' @($ex)
'@


$ScanFull = @'
$rows.Add((New-Row @{ Name = 'Aggiorna programmi'; Sub = 'Tutti gli aggiornamenti winget e Microsoft Store, escluse le esclusioni'; Key = 'upd'; Selected = $true; Glyph = [string][char]0xE895 }))
$rows.Add((New-Row @{ Name = 'Windows Update'; Sub = 'Aggiornamenti di sistema consigliati (non i facoltativi)'; Key = 'wu'; Selected = $true; Glyph = [string][char]0xE777 }))
$rows.Add((New-Row @{ Name = 'Pulizia disco'; Sub = 'Temporanei, cache di Windows Update, report errori e dump'; Key = 'clean'; Selected = $true; Glyph = [string][char]0xE894 }))
$rows.Add((New-Row @{ Name = 'Controllo driver'; Sub = 'Cerca dispositivi con problemi'; Key = 'drv'; Selected = $true; Glyph = [string][char]0xE950 }))
$rows.Add((New-Row @{ Name = 'Riparazione di sistema'; Sub = 'DISM + SFC  ·  lenta (20-30 minuti)'; Key = 'repair'; Selected = $false; Glyph = [string][char]0xE90F }))
$sync.ScanInfo = 'Scegli i passaggi e premi AVVIA: verranno eseguiti uno dopo l''altro, alla fine trovi il rapporto.'
'@

$ActFull = @'
Invoke-Each $items { param($it) Invoke-MaintStep $it } 'Eseguo'
'@

$ScanPrivacy = @'
foreach ($t in Get-PrivacyTweaks) {
    $on = Test-Tweak $t
    $rows.Add((New-Row @{ Name = $t.Name; Sub = $t.Desc; Key = $t.Id; Data = @{ Kind = 'reg' }; Selected = (-not $on)
        Tag = $(if ($on) { 'applicato' } else { 'non applicato' }); TagKind = $(if ($on) { 'ok' } else { 'none' }); Glyph = [string][char]0xE72E }))
}
foreach ($b in Get-BloatApps) {
    $pk = @(Get-AppxPackage -Name $b.N -ErrorAction SilentlyContinue)
    if (-not $pk.Count) { continue }
    $rows.Add((New-Row @{ Name = "Rimuovi app: $($b.T)"; Sub = "$($pk[0].Name)  ·  reinstallabile dal Microsoft Store"; Key = $b.N; Data = @{ Kind = 'appx' }
        Selected = $false; Tag = 'installata'; TagKind = 'warn'; Glyph = [string][char]0xE74D }))
}
$sync.ScanInfo = 'APPLICA attiva le opzioni selezionate, RIPRISTINA riporta i valori di prima (salvati in Dati\privacy-backup.json).'
'@

$ActPrivacy = @'
$all = Get-PrivacyTweaks
Invoke-Each $items {
    param($it)
    if ($it.Data.Kind -eq 'reg') {
        $t = $all | Where-Object { $_.Id -eq $it.Key }
        Set-Tweak $t ($op -eq 'apply')
        Set-It $it 'ok' $(if ($op -eq 'apply') { 'Applicato' } else { 'Ripristinato' })
    } else {
        if ($op -eq 'apply') {
            Get-AppxPackage -Name $it.Key -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction Stop
            Set-It $it 'ok' 'Rimossa'
        } else {
            $pk = Get-AppxPackage -AllUsers -Name $it.Key -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pk -and $pk.InstallLocation -and (Test-Path "$($pk.InstallLocation)\AppXManifest.xml")) {
                Add-AppxPackage -DisableDevelopmentMode -Register "$($pk.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
                Set-It $it 'ok' 'Reinstallata'
            } else {
                Start-Process ("ms-windows-store://search/?query=" + [uri]::EscapeDataString(($it.Name -replace '^Rimuovi app: ', '')))
                Set-It $it 'skip' 'Reinstalla dallo Store'
            }
        }
    }
} $(if ($op -eq 'apply') { 'Applico' } else { 'Ripristino' })
$sync.Toast = 'Alcune modifiche saranno attive dopo aver riavviato o disconnesso l''utente'
'@


$HwCode = @'
$sync.Hw = Get-HwInventory
'@

$SensCode = @'
$lhm = $null
if ($useLhm) {
    try {
        $dll = Find-LhmDll
        if (-not $dll) { throw 'LibreHardwareMonitor non trovato' }
        Add-Type -Path $dll -ErrorAction SilentlyContinue
        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        $c.IsCpuEnabled = $true; $c.IsGpuEnabled = $true; $c.IsMotherboardEnabled = $true
        $c.IsStorageEnabled = $true; $c.IsMemoryEnabled = $true; $c.IsControllerEnabled = $true
        $c.Open()
        $lhm = $c
        $sync.SensSrc = 'LibreHardwareMonitor'
    } catch { $sync.SensMsg = "Sensori avanzati non disponibili: $($_.Exception.Message)" }
}
$smi = @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $lhm) { $sync.SensSrc = 'Windows' + $(if ($smi) { ' + NVIDIA SMI' } else { '' }) }
$units = @{ Temperature = '°C'; Fan = 'RPM'; Load = '%'; Clock = 'MHz'; Power = 'W'; Control = '%' }
$logFile = Join-Path $DataDir 'sensori.csv'; $lastLog = [datetime]::MinValue
while ($sync.SensGen -eq $gen -and ($sync.SensOn -or $sync.SensLog)) {
    $out = New-Object System.Collections.ArrayList
    try {
        if ($lhm) {
            foreach ($h in $lhm.Hardware) {
                $h.Update(); foreach ($sh in $h.SubHardware) { $sh.Update() }
                $all = @($h.Sensors) + @($h.SubHardware | ForEach-Object { $_.Sensors })
                foreach ($se in $all) {
                    if ($null -eq $se.Value) { continue }
                    $t = [string]$se.SensorType
                    if (-not $units.ContainsKey($t)) { continue }
                    if ($t -eq 'Load' -and $se.Name -notmatch 'Total|^GPU Core$|^Memory$|Used Space') { continue }
                    if ($t -eq 'Clock' -and $se.Name -notmatch '^(Core #1|GPU Core|GPU Memory)$') { continue }
                    if ($t -eq 'Power' -and $se.Name -notmatch 'Package|GPU (Package|Power)') { continue }
                    if ($t -eq 'Control' -and $se.Name -notmatch 'Fan') { continue }
                    [void]$out.Add(@{ K = [string]$se.Identifier; N = $se.Name; G = $h.Name; T = $t; V = [double]$se.Value; U = $units[$t] })
                }
            }
        } else {
            foreach ($z in Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue) {
                $v = [math]::Round($z.CurrentTemperature / 10 - 273.15, 1)
                if ($v -gt 0 -and $v -lt 130) { [void]$out.Add(@{ K = "acpi$($z.InstanceName)"; N = 'Zona termica'; G = ($z.InstanceName -replace '^.*\\', ''); T = 'Temperature'; V = $v; U = '°C' }) }
            }
            foreach ($f in Get-CimInstance Win32_Fan -ErrorAction SilentlyContinue) {
                if ($f.DesiredSpeed) { [void]$out.Add(@{ K = "fan$($f.DeviceID)"; N = 'Ventola'; G = $f.Name; T = 'Fan'; V = [double]$f.DesiredSpeed; U = 'RPM' }) }
            }
            foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue) {
                $rc = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                if ($rc.Temperature) { [void]$out.Add(@{ K = "disk$($d.DeviceId)"; N = 'Disco'; G = $d.FriendlyName; T = 'Temperature'; V = [double]$rc.Temperature; U = '°C' }) }
            }
            $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
            [void]$out.Add(@{ K = 'cpuload'; N = 'Carico CPU'; G = 'Processore'; T = 'Load'; V = [double]$cpu; U = '%' })
            $os = Get-CimInstance Win32_OperatingSystem
            [void]$out.Add(@{ K = 'ram'; N = 'Memoria usata'; G = 'RAM'; T = 'Load'; V = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100); U = '%' })
            if ($smi) {
                $r = Invoke-Hidden $smi '--query-gpu=name,temperature.gpu,fan.speed,utilization.gpu,clocks.gr,power.draw --format=csv,noheader,nounits'
                foreach ($l in ($r.Out -split "`n" | Where-Object { $_.Trim() })) {
                    $p = $l.Split(',') | ForEach-Object { $_.Trim() }
                    $map = @(@(1, 'Temperatura GPU', 'Temperature', '°C'), @(2, 'Ventola GPU', 'Control', '%'), @(3, 'Carico GPU', 'Load', '%'), @(4, 'Frequenza GPU', 'Clock', 'MHz'), @(5, 'Consumo GPU', 'Power', 'W'))
                    foreach ($m in $map) {
                        $v = 0.0
                        if ([double]::TryParse($p[$m[0]], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
                            [void]$out.Add(@{ K = "smi$($m[1])"; N = $m[1]; G = $p[0]; T = $m[2]; V = $v; U = $m[3] })
                        }
                    }
                }
            }
        }
    } catch { $sync.SensMsg = "Errore sensori: $($_.Exception.Message)" }
    $sync.Sens = $out; $sync.SensVer++
    if ($sync.SensLog -and ((Get-Date) - $lastLog).TotalSeconds -ge 30) {
        $lastLog = Get-Date; $ts = $lastLog.ToString('s')
        $lines = foreach ($o in $out) { if ($o.T -in 'Temperature', 'Fan') { "$ts;$($o.G -replace ';', ',');$($o.N -replace ';', ',');$($o.T);$($o.V.ToString([Globalization.CultureInfo]::InvariantCulture))" } }
        if ($lines) { try { Add-Content -Path $logFile -Value $lines -Encoding UTF8 } catch {} }
        try { if ((Get-Item $logFile -ErrorAction SilentlyContinue).Length -gt 8MB) { (Get-Content $logFile -Tail 60000) | Set-Content $logFile -Encoding UTF8 } } catch {}
    }
    $wait = if ($sync.SensOn) { 2 } else { 30 }
    for ($w = 0; $w -lt $wait -and $sync.SensGen -eq $gen; $w++) { if ($sync.SensOn -and $wait -eq 30) { break }; Start-Sleep -Seconds 1 }
}
if ($lhm) { try { $lhm.Close() } catch {} }
'@

$LhmInstallCode = @'
try {
    $sync.HwToast = 'Installo LibreHardwareMonitor…'
    $r = Invoke-Winget 'install' 'LibreHardwareMonitor.LibreHardwareMonitor' 'winget'
    $s2 = Invoke-Hidden (Get-WingetPath) 'search PawnIO --accept-source-agreements --disable-interactivity'
    $hit = ConvertFrom-WingetTable $s2.Out | Where-Object { $_.Cols[1] -match 'PawnIO' } | Select-Object -First 1
    if ($hit) { $sync.HwToast = 'Installo il driver PawnIO…'; [void](Invoke-Winget 'install' $hit.Cols[1] '') }
    $sync.LhmResult = if (Find-LhmDll) { 'ok' } else { 'LibreHardwareMonitor non installato (codice 0x{0:X8})' -f $r.Code }
} catch { $sync.LhmResult = $_.Exception.Message }
'@


$ScanDeliver = @'
foreach ($f in Get-ChildItem $ProfDir -Filter *.json -ErrorAction SilentlyContinue) {
    $n = $f.BaseName; try { $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j.name) { $n = $j.name } } catch {}
    $rows.Add((New-Row @{ Name = "Installa profilo: $n"; Sub = $f.Name; Key = "prof"; Data = $f.FullName; Glyph = [string][char]0xE8F1 }))
}
$rows.Add((New-Row @{ Name = 'Rimuovi app preinstallate inutili'; Sub = 'Giochi e app promozionali, reinstallabili dallo Store'; Key = 'bloat'; Selected = $true; Glyph = [string][char]0xE74D }))
$rows.Add((New-Row @{ Name = 'Applica impostazioni privacy'; Sub = 'Telemetria minima, niente pubblicità e suggerimenti'; Key = 'privacy'; Selected = $true; Glyph = [string][char]0xE72E }))
$rows.Add((New-Row @{ Name = 'Windows Update'; Sub = 'Aggiornamenti di sistema consigliati'; Key = 'wu'; Selected = $true; Glyph = [string][char]0xE777 }))
$rows.Add((New-Row @{ Name = 'Aggiorna programmi'; Sub = 'winget e Microsoft Store'; Key = 'upd'; Selected = $true; Glyph = [string][char]0xE895 }))
$rows.Add((New-Row @{ Name = 'Pulizia disco'; Sub = 'Temporanei e cache degli aggiornamenti'; Key = 'clean'; Selected = $true; Glyph = [string][char]0xE894 }))
$rows.Add((New-Row @{ Name = 'Controllo driver'; Sub = 'Dispositivi con problemi'; Key = 'drv'; Selected = $true; Glyph = [string][char]0xE950 }))
$rows.Add((New-Row @{ Name = 'Rapporto di consegna'; Sub = 'Hardware, programmi installati, garanzia e firme (HTML stampabile)'; Key = 'report'; Selected = $true; Glyph = [string][char]0xE8A5 }))
$rows.Add((New-Row @{ Name = 'Etichetta con codice QR'; Sub = 'Da stampare e attaccare al case'; Key = 'label'; Selected = $true; Glyph = [string][char]0xE8A5 }))
$sync.ScanInfo = 'Prepara il PC per il cliente: scegli i passaggi e premi AVVIA. Dati del negozio in Impostazioni.'
'@

$ActDeliver = @'
Invoke-Each $items {
    param($it)
    switch ($it.Key) {
        'prof' { Install-Profile $it ([string]$it.Data) $true }
        'bloat' {
            $n = 0
            foreach ($b in Get-BloatApps) { foreach ($p in Get-AppxPackage -Name $b.N -ErrorAction SilentlyContinue) { $it.Sub = "Rimuovo $($b.T)…"; try { $p | Remove-AppxPackage -ErrorAction Stop; $n++ } catch {} } }
            $it.Sub = "$n app rimosse"; Set-It $it 'ok' "$n rimosse"
        }
        'privacy' { foreach ($t in Get-PrivacyTweaks) { Set-Tweak $t $true }; $it.Sub = "$(@(Get-PrivacyTweaks).Count) impostazioni applicate"; Set-It $it 'ok' 'Applicate' }
        'report' { $f = New-DeliveryReport; Start-Process $f; $it.Sub = $f; Set-It $it 'ok' 'Creato' }
        'label' { $f = New-PcLabel; Start-Process $f; $it.Sub = $f; Set-It $it 'ok' 'Creata' }
        default { Invoke-MaintStep $it }
    }
} 'Eseguo'
'@

$ScanBackup = @'
$dest = (Get-Settings).BackupDest
foreach ($f in Get-BackupFolders) {
    if (-not $f.Path -or -not (Test-Path $f.Path)) { continue }
    $sync.Status = "Calcolo: $($f.Name)…"
    $sz = Get-DirSize @($f.Path)
    $rows.Add((New-Row @{ Name = $f.Name; Sub = $f.Path; Key = $f.Id; Data = $f.Path; C1 = (Format-Size $sz); Selected = $f.Def; Glyph = [string][char]0xE8B7 }))
}
$sync.ScanInfo = if ($dest) { "Destinazione: $dest\MultiTool-Backup\$env:COMPUTERNAME  ·  copia solo i file nuovi o modificati, non cancella nulla" } else { 'Scegli prima la destinazione (disco esterno o cartella di rete) con il pulsante in alto.' }
'@

$ActBackup = @'
$dest = (Get-Settings).BackupDest
if (-not $dest -or -not (Test-Path $dest)) { throw 'Destinazione del backup non disponibile: collega il disco o sceglila di nuovo' }
$root = Join-Path $dest "MultiTool-Backup\$env:COMPUTERNAME"
Invoke-Each $items {
    param($it)
    $r = Invoke-FolderBackup ([string]$it.Data) (Join-Path $root $it.Name)
    $it.C2 = Format-Size (Get-DirSize @(Join-Path $root $it.Name))
    if ($r.Code -lt 8) { Set-It $it 'ok' $(if ($r.Copied -ge 0) { "$($r.Copied) file copiati" } else { 'Completato' }) } else { Set-It $it 'err' "Errore robocopy $($r.Code)" }
} 'Copio'
$sync.LastBackup = (Get-Date).ToString('s')
$sync.Extra = "Backup in $root"
'@

$ScanNetwork = @'
$sync.Status = 'Leggo le schede di rete…'
foreach ($n in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') {
    $ip = (Get-NetIPAddress -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    $rows.Add((New-Row @{ Name = $n.Name; Sub = $n.InterfaceDescription; C1 = $ip; C2 = $n.LinkSpeed; Tag = 'connessa'; TagKind = 'ok'; Checkable = $false; Glyph = [string][char]0xE774 }))
}
$wl = (Invoke-Hidden "$env:SystemRoot\System32\netsh.exe" 'wlan show interfaces').Out
$ssid = [regex]::Match($wl, '(?m)^\s*SSID\s*:\s*(.+)$').Groups[1].Value.Trim()
if ($ssid) {
    $sig = [regex]::Match($wl, '(?m)^\s*(Signal|Segnale)\s*:\s*(\d+)%').Groups[2].Value
    $rows.Add((New-Row @{ Name = "Wi-Fi: $ssid"; Sub = 'Qualità del segnale'; C1 = "$sig%"; Tag = $(if ([int]$sig -ge 70) { 'ottimo' } elseif ([int]$sig -ge 45) { 'discreto' } else { 'debole' }); TagKind = $(if ([int]$sig -ge 70) { 'ok' } elseif ([int]$sig -ge 45) { 'warn' } else { 'err' }); Checkable = $false; Glyph = [string][char]0xE701 }))
}
$sync.Status = 'Misuro le risposte…'
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
$tests = @(@('Router (gateway)', $gw), @('Internet (1.1.1.1)', '1.1.1.1'), @('Internet (8.8.8.8)', '8.8.8.8'))
foreach ($t in $tests) {
    if (-not $t[1]) { continue }
    $ms = Test-Ping $t[1]
    $rows.Add((New-Row @{ Name = $t[0]; Sub = $t[1]; C1 = $(if ($null -ne $ms) { "$ms ms" } else { 'nessuna risposta' }); Checkable = $false; Glyph = [string][char]0xE774
        Tag = $(if ($null -eq $ms) { 'irraggiungibile' } elseif ($ms -lt 60) { 'ok' } else { 'lento' }); TagKind = $(if ($null -eq $ms) { 'err' } elseif ($ms -lt 60) { 'ok' } else { 'warn' }) }))
}
$sw = [Diagnostics.Stopwatch]::StartNew(); $dnsOk = $true
try { [void][Net.Dns]::GetHostAddresses('www.microsoft.com') } catch { $dnsOk = $false }
$sw.Stop()
$dns = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses -join ', '
$rows.Add((New-Row @{ Name = 'Risoluzione nomi (DNS)'; Sub = $dns; C1 = $(if ($dnsOk) { "$([int]$sw.ElapsedMilliseconds) ms" } else { 'errore' }); Checkable = $false; Glyph = [string][char]0xE774
    Tag = $(if ($dnsOk) { 'ok' } else { 'non funziona' }); TagKind = $(if ($dnsOk) { 'ok' } else { 'err' }) }))
try { $pub = (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 6); $rows.Add((New-Row @{ Name = 'IP pubblico'; Sub = 'Indirizzo visto da internet'; C1 = $pub; Checkable = $false; Glyph = [string][char]0xE774 })) } catch {}
$sync.ScanInfo = 'TEST VELOCITÀ misura download e upload; RIPARA CONNESSIONE azzera la configurazione di rete di Windows.'
'@

$ActNetwork = @'
if ($op -eq 'speed') {
    $sync.Status = 'Misuro il download (circa 12 secondi)…'
    $dl = Measure-Download
    $sync.Status = 'Misuro l''upload…'
    $ul = try { Measure-Upload } catch { $null }
    $sync.ExtraRows = New-Object System.Collections.ArrayList
    [void]$sync.ExtraRows.Add((New-Row @{ Name = 'Velocità download'; Sub = 'Server Cloudflare più vicino'; C1 = "$dl Mbit/s"; Checkable = $false; Status = 'Misurato'; StatusKind = 'ok'; Glyph = [string][char]0xE896 }))
    if ($ul) { [void]$sync.ExtraRows.Add((New-Row @{ Name = 'Velocità upload'; Sub = 'Server Cloudflare più vicino'; C1 = "$ul Mbit/s"; Checkable = $false; Status = 'Misurato'; StatusKind = 'ok'; Glyph = [string][char]0xE898 })) }
    Add-History $area 'Test velocità' "$dl / $ul Mbit/s" 'ok'
    $sync.Extra = "Download $dl Mbit/s  ·  upload $ul Mbit/s"
} else {
    foreach ($c in @(@('ipconfig.exe', '/flushdns'), @('netsh.exe', 'winsock reset'), @('netsh.exe', 'int ip reset'), @('ipconfig.exe', '/release'), @('ipconfig.exe', '/renew'))) {
        $sync.Status = "Eseguo $($c[0]) $($c[1])…"
        [void](Invoke-Hidden "$env:SystemRoot\System32\$($c[0])" $c[1])
    }
    $sync.Reboot = $true
    Add-History $area 'Ripara connessione' 'Eseguito' 'ok'
    $sync.Extra = 'Configurazione di rete azzerata: riavvia il PC per completare'
}
$sync.Done = 1
'@

$ScanSecurity = @'
$ok = 0; $tot = 0
function Chk([string]$Name, [string]$Sub, [string]$Val, [string]$Kind, [string]$Fix) {
    $script:tot++; if ($Kind -eq 'ok') { $script:ok++ }
    $rows.Add((New-Row @{ Name = $Name; Sub = $Sub; C1 = $Val; Key = $Fix; Data = $Fix; Glyph = [string][char]0xEA18
        Tag = $(switch ($Kind) { 'ok' { 'ok' } 'warn' { 'attenzione' } default { 'a rischio' } }); TagKind = $Kind
        Checkable = [bool]($Fix -and $Kind -ne 'ok'); Selected = [bool]($Fix -and $Kind -ne 'ok') })) | Out-Null
}
$sync.Status = 'Antivirus…'
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Chk 'Protezione in tempo reale' 'Microsoft Defender' $(if ($mp.RealTimeProtectionEnabled) { 'attiva' } else { 'disattiva' }) $(if ($mp.RealTimeProtectionEnabled) { 'ok' } else { 'err' }) 'rtp'
    Chk 'Firme antivirus' "Aggiornate il $($mp.AntivirusSignatureLastUpdated.ToString('dd/MM/yyyy'))" "$($mp.AntivirusSignatureAge) giorni" $(if ($mp.AntivirusSignatureAge -le 3) { 'ok' } else { 'warn' }) 'sig'
    $qa = if ($mp.QuickScanAge -lt 1000) { "$($mp.QuickScanAge) giorni fa" } else { 'mai' }
    Chk 'Ultima scansione rapida' 'Defender' $qa $(if ($mp.QuickScanAge -le 7) { 'ok' } else { 'warn' }) 'scan'
} catch { Chk 'Antivirus' 'Defender non attivo: probabilmente c''è un antivirus di terze parti' 'n.d.' 'warn' '' }
$sync.Status = 'Firewall…'
foreach ($f in Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
    Chk "Firewall · profilo $($f.Name)" 'Windows Defender Firewall' $(if ($f.Enabled) { 'attivo' } else { 'disattivo' }) $(if ($f.Enabled) { 'ok' } else { 'err' }) 'fw'
}
$lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
Chk 'Controllo account utente (UAC)' 'Chiede conferma prima delle modifiche di sistema' $(if ($lua -ne 0) { 'attivo' } else { 'disattivo' }) $(if ($lua -ne 0) { 'ok' } else { 'err' }) 'uac'
$sbv = 'n.d.'; $sbk = 'warn'
try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { $sbv = 'attivo'; $sbk = 'ok' } else { $sbv = 'disattivo' } } catch { $sbv = 'non supportato' }
Chk 'Secure Boot' 'Si attiva dal firmware UEFI' $sbv $sbk ''
try { $t = Get-Tpm -ErrorAction Stop; Chk 'Chip di sicurezza TPM' 'Necessario per BitLocker e Windows 11' $(if ($t.TpmReady) { 'pronto' } elseif ($t.TpmPresent) { 'presente' } else { 'assente' }) $(if ($t.TpmReady) { 'ok' } else { 'warn' }) '' } catch {}
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    Chk "Crittografia disco $env:SystemDrive" 'BitLocker / crittografia dispositivo' $(if ($bl.ProtectionStatus -eq 'On') { 'attiva' } else { 'non attiva' }) $(if ($bl.ProtectionStatus -eq 'On') { 'ok' } else { 'warn' }) ''
} catch { Chk "Crittografia disco $env:SystemDrive" 'BitLocker non disponibile in questa edizione' 'n.d.' 'warn' '' }
$adm = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID -like '*-500' }
if ($adm) { Chk 'Account Administrator integrato' 'Va lasciato disattivato' $(if ($adm.Enabled) { 'attivo' } else { 'disattivo' }) $(if ($adm.Enabled) { 'warn' } else { 'ok' }) 'admin' }
$sync.Status = 'Componenti di sistema…'
try { $smb = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction Stop; Chk 'Protocollo SMBv1' 'Obsoleto e vulnerabile' $(if ($smb.State -eq 'Enabled') { 'attivo' } else { 'disattivo' }) $(if ($smb.State -eq 'Enabled') { 'err' } else { 'ok' }) 'smb1' } catch {}
$rdp = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections
Chk 'Desktop remoto' 'Accesso remoto al PC' $(if ($rdp -eq 0) { 'attivo' } else { 'disattivo' }) $(if ($rdp -eq 0) { 'warn' } else { 'ok' }) 'rdp'
$ar = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -ErrorAction SilentlyContinue).NoDriveTypeAutoRun
Chk 'Esecuzione automatica da USB' 'Blocca i programmi che partono da chiavette e CD' $(if ($ar -eq 255) { 'bloccata' } else { 'permessa' }) $(if ($ar -eq 255) { 'ok' } else { 'warn' }) 'autorun'
$hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
if ($hf) { $d = [int]((Get-Date) - $hf.InstalledOn).TotalDays; Chk 'Ultimo aggiornamento di Windows' "$($hf.HotFixID) del $($hf.InstalledOn.ToString('dd/MM/yyyy'))" "$d giorni fa" $(if ($d -le 45) { 'ok' } else { 'warn' }) '' }
$score = if ($tot) { [int]($ok / $tot * 100) } else { 0 }
$sync.ScanInfo = "Punteggio sicurezza: $score/100  ·  $ok controlli superati su $tot. Seleziona i problemi e premi CORREGGI."
'@

$ActSecurity = @'
Invoke-Each $items {
    param($it)
    switch ([string]$it.Data) {
        'rtp'     { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop }
        'sig'     { Update-MpSignature -ErrorAction Stop }
        'scan'    { $it.Status = 'Scansione…'; Start-MpScan -ScanType QuickScan -ErrorAction Stop }
        'fw'      { Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -ErrorAction Stop }
        'uac'     { Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 1 -Type DWord; $sync.Reboot = $true }
        'admin'   { Get-LocalUser | Where-Object { $_.SID -like '*-500' } | Disable-LocalUser -ErrorAction Stop }
        'smb1'    { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null; $sync.Reboot = $true }
        'rdp'     { Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1 -Type DWord }
        'autorun' { $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }; Set-ItemProperty $k -Name NoDriveTypeAutoRun -Value 255 -Type DWord }
    }
    Set-It $it 'ok' 'Corretto'
} 'Correggo'
'@

$ScanBench = @'
$prev = Read-Json 'bench.json' $null
foreach ($t in Get-BenchTests) {
    $pv = if ($prev -and $prev.($t.Id)) { $prev.($t.Id) } else { $null }
    $rows.Add((New-Row @{ Name = $t.Name; Sub = $(if ($pv) { "Ultimo test: $($pv.D)" } else { 'Mai eseguito' }); Key = $t.Id; Data = $t.Args
        C1 = $(if ($pv) { "{0:N0} MB/s" -f [double]$pv.V } else { '' }); Arrow = $true; Selected = $true; Glyph = [string][char]0xE916 }))
}
$sync.ScanInfo = 'Test di Windows (WinSAT): circa 1-3 minuti in tutto. Chiudi gli altri programmi per risultati affidabili.'
'@

$ActBench = @'
$res = @{}
$prev = Read-Json 'bench.json' $null
if ($prev) { foreach ($p in $prev.PSObject.Properties) { $res[$p.Name] = $p.Value } }
Invoke-Each $items {
    param($it)
    $r = Invoke-Hidden "$env:SystemRoot\System32\winsat.exe" ([string]$it.Data)
    $m = [regex]::Matches($r.Out, '([\d\.,]+)\s*MB/s')
    if (-not $m.Count) { Set-It $it 'err' 'Nessun risultato'; return }
    $v = [double](($m[$m.Count - 1].Groups[1].Value) -replace ',', '.')
    $it.C2 = "{0:N0} MB/s" -f $v
    $old = if ($res[$it.Key]) { [double]$res[$it.Key].V } else { 0 }
    $res[$it.Key] = @{ V = $v; D = (Get-Date).ToString('dd/MM/yyyy HH:mm') }
    if ($old -gt 0) { $d = [int](($v - $old) / $old * 100); Set-It $it $(if ($d -lt -15) { 'err' } else { 'ok' }) $(if ($d -ge 0) { "+$d%" } else { "$d%" }) } else { Set-It $it 'ok' 'Misurato' }
} 'Misuro'
Save-Json 'bench.json' $res
'@

$ScanRestore = @'
try {
    $pts = @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending)
    foreach ($r in $pts) {
        $dt = [Management.ManagementDateTimeConverter]::ToDateTime($r.CreationTime)
        $type = switch ([int]$r.RestorePointType) { 0 { 'installazione' } 1 { 'disinstallazione' } 10 { 'driver' } 12 { 'impostazioni' } 13 { 'annullamento' } default { 'sistema' } }
        $rows.Add((New-Row @{ Name = $r.Description; Sub = "Punto n. $($r.SequenceNumber)"; C1 = $dt.ToString('dd/MM/yyyy HH:mm'); Tag = $type; Key = [string]$r.SequenceNumber; Glyph = [string][char]0xE7A7 }))
    }
    $sync.ScanInfo = "$($pts.Count) punti di ripristino. Per tornare indietro selezionane UNO e premi RIPRISTINA (il PC si riavvia)."
} catch { $sync.ScanInfo = 'Protezione sistema disattivata o nessun punto disponibile: premi CREA PUNTO per attivarla.' }
'@

$ActRestore = @'
if ($op -eq 'create') {
    $sync.Status = 'Creo il punto di ripristino…'
    if (New-RestorePoint "MultiTool - manuale $(Get-Date -Format 'dd/MM/yyyy HH:mm')") { $sync.Extra = 'Punto di ripristino creato'; Add-History $area 'Punto di ripristino' 'Creato' 'ok' }
    else { throw 'Creazione non riuscita: la protezione sistema potrebbe essere disattivata' }
    $sync.Done = 1
} else {
    if ($items.Count -ne 1) { throw 'Seleziona un solo punto di ripristino' }
    Add-History $area "Ripristino a: $($items[0].Name)" 'Avviato' 'ok'
    Set-It $items[0] 'run' 'Riavvio…'
    Restore-Computer -RestorePoint ([int]$items[0].Key) -Confirm:$false
}
'@

$InfoCode = @'
$info = @{}
try {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $info.OS    = $(if ([int]$cv.CurrentBuildNumber -ge 22000) { 'Windows 11' } else { 'Windows 10' }) + " $($cv.DisplayVersion)"
    $info.Build = "$($cv.EditionID)  ·  build $($cv.CurrentBuildNumber).$($cv.UBR)"
    $info.CPU   = ($cpu.Name -replace '\s+', ' ').Trim()
    $info.Cores = "$($cpu.NumberOfCores) core  ·  $($cpu.NumberOfLogicalProcessors) thread"
    $tot = [double]$cs.TotalPhysicalMemory; $free = [double]$os.FreePhysicalMemory * 1KB
    $info.RamPct = [int][Math]::Round(($tot - $free) / $tot * 100)
    $info.Ram    = '{0:N1} / {1:N0} GB' -f (($tot - $free) / 1GB), ($tot / 1GB)
    $up = (Get-Date) - $os.LastBootUpTime
    $info.Uptime = '{0}g {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes
    $info.Disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        @{ Name = $_.DeviceID; Label = [string]$_.VolumeName; Size = [double]$_.Size; Free = [double]$_.FreeSpace } })
} catch {}
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $info.DefOk  = [bool]$mp.RealTimeProtectionEnabled
    $info.Def    = if ($info.DefOk) { 'Attiva' } else { 'Disattivata' }
    $info.DefSig = 'Firme del ' + $mp.AntivirusSignatureLastUpdated.ToString('dd/MM/yyyy')
} catch { $info.DefOk = $null; $info.Def = 'Non rilevata'; $info.DefSig = 'Antivirus di terze parti?' }
try {
    $info.PD = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
        $rc = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        @{ Name = [string]$_.FriendlyName; Media = [string]$_.MediaType; Health = [string]$_.HealthStatus; Size = [double]$_.Size
           Temp = $rc.Temperature; Wear = $rc.Wear; Hours = $rc.PowerOnHours } })
} catch { $info.PD = @() }
try {
    $b = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1
    if ($b) {
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
        $des  = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
        $info.Bat = @{ Charge = [int]$b.EstimatedChargeRemaining; Health = $(if ($full -and $des) { [int][Math]::Min(100, $full / $des * 100) } else { $null }) }
    }
} catch {}
$info.Pending = Test-PendingReboot
$sync.Info = $info
'@

# ============================================================
#  Definizione delle sezioni
# ============================================================
$Modes = @{
    updates = @{ Nav = 'NavUpdates'; Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' }, @{ T = 'Microsoft Store'; U = 'https://apps.microsoft.com' });  Title = 'Aggiorna programmi'; Glyph = (G 0xE895); Arrow = $true
        Sub = 'Analisi di winget e Microsoft Store…'; H = 'INSTALLATA', 'NUOVA', 'ORIGINE', 'STATO'
        Scan = $ScanUpdates; Action = $ActUpdates; Go = 'PROCEDI'; Restore = $true
        X1 = @{ Text = 'Escludi selezionati'; Click = { Add-Exclusions } }
        X2 = @{ Text = 'Ricerca di nuovo'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE73E); Title = 'Tutto aggiornato'; Text = 'winget non ha trovato aggiornamenti disponibili.' } }

    wu = @{ Nav = 'NavWU'; Credits = @(@{ T = 'Windows Update · Microsoft'; U = 'https://support.microsoft.com/windows' });  Title = 'Windows Update'; Glyph = (G 0xE777)
        Sub = 'Ricerca aggiornamenti di Windows…'; H = 'DIMENSIONE', '', 'TIPO', 'STATO'
        Scan = $ScanWU; Action = $ActWU; Go = 'INSTALLA'; Restore = $true
        X1 = @{ Text = 'Impostazioni Windows Update'; Click = { Start-Process 'ms-settings:windowsupdate' } }
        X2 = @{ Text = 'Ricerca di nuovo'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE73E); Title = 'Windows è aggiornato'; Text = 'Nessun aggiornamento di sistema in attesa.' } }

    drivers = @{ Nav = 'NavDrivers'; Title = 'Driver'; Glyph = (G 0xE950); Checks = $false
        Sub = 'Controllo dello stato dei driver…'; H = 'VERSIONE', 'DATA', 'STATO', ''
        Scan = $ScanDrivers
        X1 = @{ Text = 'Gestione dispositivi'; Click = { Start-Process devmgmt.msc } }
        X2 = @{ Text = 'Backup driver'; Click = { Start-DriverBackup } }
        Empty = @{ Glyph = (G 0xE73E); Title = 'Nessun driver da segnalare'; Text = 'Nessun problema e nessun driver di terze parti rilevato.' } }

    installers = @{ Nav = 'NavInstall'; Title = 'Installer locali'; Glyph = (G 0xE7B8); Silent = $true
        Sub = 'Lettura della cartella Installers…'; H = 'TIPO', 'DIMENSIONE', 'MODALITÀ', 'STATO'
        Scan = $ScanInstallers; Action = $ActInstallers; Go = 'INSTALLA'; Restore = $true
        X1 = @{ Text = 'Apri cartella'; Click = { Start-Process explorer.exe $InstDir } }
        X2 = @{ Text = 'Ricarica'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE8B7); Title = 'Nessun installer trovato'; Text = 'Copia file .exe, .msi, .msix o .appx nella cartella Installers, poi premi Ricarica.' } }

    catalog = @{ Nav = 'NavCatalog'; Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' }, @{ T = 'Repository comunitario winget-pkgs'; U = 'https://github.com/microsoft/winget-pkgs' });  Title = 'Catalogo winget'; Glyph = (G 0xE896); Search = $true
        Sub = 'Cerca tra migliaia di programmi e installali senza scaricare nulla a mano.'; H = 'VERSIONE', 'CORRISPONDENZA', 'ORIGINE', 'STATO'
        Scan = $ScanCatalog; Action = $ActWingetInstall; Go = 'INSTALLA'; Restore = $true
        Empty = @{ Glyph = (G 0xE721); Title = 'Cerca un programma'; Text = 'Scrivi un nome, ad esempio "vlc", "firefox" o "7zip", e premi Invio.' } }

    profiles = @{ Nav = 'NavProfiles'; Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' });  Title = 'Profili'; Glyph = (G 0xE8F1); Silent = $true
        Sub = 'Gruppi di programmi da installare in un colpo solo.'; H = 'WINGET', 'LOCALI', '', 'STATO'
        Scan = $ScanProfiles; Action = $ActProfiles; Go = 'INSTALLA PROFILI'; Restore = $true
        X1 = @{ Text = 'Apri cartella profili'; Click = { Start-Process explorer.exe $ProfDir } }
        X2 = @{ Text = 'Ricarica'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE8F1); Title = 'Nessun profilo'; Text = 'Crea un file .json nella cartella Profili (vedi gli esempi inclusi).' } }

    import = @{ Nav = 'NavSettings'; Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' });  Title = 'Importa elenco'; Glyph = (G 0xE896)
        Sub = 'Lettura del file…'; H = '', '', 'ORIGINE', 'STATO'
        Scan = $ScanImport; Action = $ActWingetInstall; Go = 'INSTALLA'; Restore = $true
        Empty = @{ Glyph = (G 0xE7BA); Title = 'Elenco vuoto'; Text = 'Il file non contiene pacchetti winget validi.' } }

    uninstall = @{ Nav = 'NavUninstall'; Title = 'Disinstalla'; Glyph = (G 0xE74D); Silent = $true
        Sub = 'Lettura dei programmi installati…'; H = 'VERSIONE', 'DIMENSIONE', 'TIPO', 'STATO'
        Scan = $ScanUninstall; Action = $ActUninstall; Go = 'DISINSTALLA'; Restore = $true
        Confirm = 'Disinstallare {0} programmi? L''operazione non si può annullare.'
        X1 = @{ Text = 'Programmi e funzionalità'; Click = { Start-Process appwiz.cpl } }
        X2 = @{ Text = 'Ricarica'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE74D); Title = 'Nessun programma'; Text = 'Non ho trovato programmi disinstallabili.' } }

    startup = @{ Nav = 'NavStartup'; Title = 'Avvio automatico'; Glyph = (G 0xE7E8); AfterDone = 'review'
        Sub = 'Lettura dei programmi all''avvio…'; H = 'AMBITO', '', 'AVVIO', 'ESITO'
        Scan = $ScanStartup; Action = $ActStartup; Go = 'DISATTIVA'; GoOp = 'disable'; Go2 = 'ATTIVA'; Go2Op = 'enable'
        X1 = @{ Text = 'Gestione attività'; Click = { Start-Process taskmgr.exe '/0 /startup' } }
        X2 = @{ Text = 'Ricarica'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE7E8); Title = 'Nessun programma all''avvio'; Text = 'Windows parte già leggero.' } }

    cleanup = @{ Nav = 'NavCleanup'; Title = 'Pulizia disco'; Glyph = (G 0xE894)
        Sub = 'Calcolo dello spazio recuperabile…'; H = 'DIMENSIONE', '', '', 'ESITO'
        Scan = $ScanCleanup; Action = $ActCleanup; Go = 'PULISCI'
        Confirm = 'Eliminare definitivamente il contenuto di {0} categorie?'
        X1 = @{ Text = 'Ricalcola'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE73E); Title = 'Niente da pulire'; Text = '' } }

    repair = @{ Nav = 'NavRepair'; Credits = @(@{ T = 'DISM, SFC e CHKDSK · strumenti di Windows'; U = 'https://learn.microsoft.com/windows-hardware/manufacture/desktop/repair-a-windows-image' });  Title = 'Riparazione'; Glyph = (G 0xE90F)
        Sub = ''; H = '', '', '', 'ESITO'
        Scan = $ScanRepair; Action = $ActRepair; Go = 'AVVIA'
        X1 = @{ Text = 'Apri log'; Click = { $l = Join-Path $DataDir 'Logs'; New-Item -ItemType Directory $l -Force | Out-Null; Start-Process explorer.exe $l } }
        Empty = @{ Glyph = (G 0xE90F); Title = ''; Text = '' } }

    history = @{ Nav = 'NavHistory'; Title = 'Cronologia'; Glyph = (G 0xE81C); Checks = $false
        Sub = 'Lettura della cronologia…'; H = 'DATA', '', 'ESITO', ''
        Scan = $ScanHistory
        X1 = @{ Text = 'Svuota cronologia'; Click = { Clear-History2 } }
        Empty = @{ Glyph = (G 0xE81C); Title = 'Nessuna operazione registrata'; Text = 'Qui troverai aggiornamenti, installazioni e pulizie eseguite.' } }

    full = @{ Nav = 'NavFull'; Title = 'Manutenzione completa'; Glyph = (G 0xE768)
        Sub = ''; H = '', '', '', 'ESITO'
        Scan = $ScanFull; Action = $ActFull; Go = 'AVVIA'; Restore = $true
        Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' }, @{ T = 'Windows Update · Microsoft'; U = 'https://support.microsoft.com/windows' })
        Empty = @{ Glyph = (G 0xE768); Title = ''; Text = '' } }

    privacy = @{ Nav = 'NavPrivacy'; Title = 'Privacy'; Glyph = (G 0xE72E); AfterDone = 'rescan'
        Sub = 'Lettura delle impostazioni…'; H = '', '', 'STATO', 'ESITO'
        Scan = $ScanPrivacy; Action = $ActPrivacy; Go = 'APPLICA'; GoOp = 'apply'; Go2 = 'RIPRISTINA'; Go2Op = 'restore'; Restore = $true
        Empty = @{ Glyph = (G 0xE72E); Title = ''; Text = '' } }

    deliver = @{ Nav = 'NavDeliver'; Title = 'Preparazione consegna'; Glyph = (G 0xE719)
        Sub = ''; H = '', '', '', 'ESITO'; Scan = $ScanDeliver; Action = $ActDeliver; Go = 'AVVIA'; Restore = $true
        Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' }, @{ T = 'QR: qrcodejs'; U = 'https://github.com/davidshimjs/qrcodejs' })
        X1 = @{ Text = 'Dati del negozio'; Click = { Stop-AnyScan; $ui.NavSettings.IsChecked = $true; Show-View 'ViewSettings' } }
        X2 = @{ Text = 'Solo etichetta QR'; Click = { Start-Bg '$f = New-PcLabel; Start-Process $f' @{}; Toast 'Creo l''etichetta…' } }
        Empty = @{ Glyph = ''; Title = ''; Text = '' } }

    backup = @{ Nav = 'NavBackup'; Title = 'Backup'; Glyph = (G 0xE753)
        Sub = 'Calcolo delle cartelle…'; H = 'DIMENSIONE', 'NEL BACKUP', '', 'ESITO'; Scan = $ScanBackup; Action = $ActBackup; Go = 'AVVIA BACKUP'
        X1 = @{ Text = 'Scegli destinazione'; Click = { Select-BackupDest } }
        X2 = @{ Text = 'Apri backup'; Click = { if ($Settings.BackupDest -and (Test-Path $Settings.BackupDest)) { Start-Process explorer.exe $Settings.BackupDest } else { Toast 'Destinazione non disponibile' } } }
        Empty = @{ Glyph = (G 0xE753); Title = 'Nessuna cartella'; Text = '' } }

    network = @{ Nav = 'NavNetwork'; Title = 'Rete'; Glyph = (G 0xE774); Checks = $false; NoSelect = $true; AfterDone = 'review'
        Sub = 'Diagnosi della connessione…'; H = 'VALORE', 'VELOCITÀ', 'STATO', ''; Scan = $ScanNetwork; Action = $ActNetwork
        Go = 'TEST VELOCITÀ'; GoOp = 'speed'; Go2 = 'RIPARA CONNESSIONE'; Go2Op = 'repair'
        ConfirmOp = @{ repair = 'La connessione verrà interrotta per qualche secondo e servirà un riavvio. Procedere?' }
        Credits = @(@{ T = 'Test velocità: Cloudflare'; U = 'https://speed.cloudflare.com' }, @{ T = 'IP pubblico: ipify'; U = 'https://www.ipify.org' })
        X1 = @{ Text = 'Ricontrolla'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE774); Title = 'Nessuna rete connessa'; Text = 'Collega un cavo o una rete Wi-Fi.' } }

    security = @{ Nav = 'NavSecurity'; Title = 'Sicurezza'; Glyph = (G 0xEA18); AfterDone = 'rescan'
        Sub = 'Controllo delle protezioni…'; H = 'VALORE', '', 'STATO', 'ESITO'; Scan = $ScanSecurity; Action = $ActSecurity; Go = 'CORREGGI'; Restore = $true
        X1 = @{ Text = 'Sicurezza di Windows'; Click = { Start-Process 'windowsdefender:' } }
        X2 = @{ Text = 'Ricontrolla'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xEA18); Title = ''; Text = '' } }

    bench = @{ Nav = 'NavBench'; Title = 'Benchmark'; Glyph = (G 0xE916)
        Sub = ''; H = 'PRECEDENTE', 'ORA', '', 'VARIAZIONE'; Scan = $ScanBench; Action = $ActBench; Go = 'AVVIA TEST'
        Credits = @(@{ T = 'WinSAT · strumento di Windows'; U = 'https://learn.microsoft.com/windows-hardware/manufacture/desktop/winsat-command-line-reference' })
        Empty = @{ Glyph = ''; Title = ''; Text = '' } }

    restore = @{ Nav = 'NavRestore'; Title = 'Punti di ripristino'; Glyph = (G 0xE7A7); AfterDone = 'rescan'; NoSelectOps = @('create')
        Sub = 'Lettura dei punti di ripristino…'; H = 'DATA', '', 'TIPO', 'ESITO'; Scan = $ScanRestore; Action = $ActRestore
        Go = 'CREA PUNTO'; GoOp = 'create'; Go2 = 'RIPRISTINA'; Go2Op = 'restore'
        ConfirmOp = @{ restore = 'Il PC verrà riportato allo stato del punto selezionato e si RIAVVIERÀ SUBITO. I tuoi file personali non vengono toccati, ma programmi e driver installati dopo verranno rimossi. Salva il lavoro aperto. Procedere?' }
        X1 = @{ Text = 'Elimina il più vecchio'; Click = { Remove-OldestRestore } }
        X2 = @{ Text = 'Ripristina driver da backup'; Click = { Restore-DriverBackup } }
        Empty = @{ Glyph = (G 0xE7A7); Title = 'Nessun punto di ripristino'; Text = 'Premi CREA PUNTO: verrà attivata anche la protezione sistema.' } }

    exclusions = @{ Nav = 'NavSettings'; Title = 'Esclusioni'; Glyph = (G 0xE72E); AfterDone = 'rescan'
        Sub = 'Programmi che non verranno mai aggiornati.'; H = '', '', '', 'STATO'
        Scan = $ScanExclusions; Action = $ActExclusions; Go = 'RIMUOVI ESCLUSIONE'
        Empty = @{ Glyph = (G 0xE72E); Title = 'Nessuna esclusione'; Text = 'In "Aggiorna programmi" seleziona un programma e premi "Escludi selezionati".' } }
}

if ($Settings.Lang -eq 'en') {
    foreach ($m in $Modes.Values) {
        foreach ($k in 'Title', 'Sub', 'Go', 'Go2') { if ($m[$k]) { $m[$k] = T $m[$k] } }
        if ($m.H) { $m.H = @($m.H | ForEach-Object { T $_ }) }
        foreach ($x in 'X1', 'X2') { if ($m[$x]) { $m[$x].Text = T $m[$x].Text } }
        if ($m.Empty) { $m.Empty.Title = T $m.Empty.Title; $m.Empty.Text = T $m.Empty.Text }
    }
}

# ============================================================
#  Motore UI
# ============================================================
function Show-View([string]$v) {
    foreach ($n in 'ViewHome', 'ViewList', 'ViewSettings', 'ViewLogs', 'ViewHw') { $ui[$n].Visibility = 'Collapsed' }
    if ($v -ne 'ViewHw') { $sync.SensOn = $false }
    $el = $ui[$v]; $el.Visibility = 'Visible'
    $tt = New-Object Windows.Media.TranslateTransform 0, 12
    $el.RenderTransform = $tt
    $d = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(260))
    $ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'
    $a1 = New-Object Windows.Media.Animation.DoubleAnimation ([double]0), ([double]1), $d
    $a2 = New-Object Windows.Media.Animation.DoubleAnimation ([double]12), ([double]0), $d
    $a2.EasingFunction = $ease
    $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $a1)
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $a2)
}

function Start-Shimmer {
    $ui.LFill.Width = 0
    $ui.LShimmer.Visibility = 'Visible'
    $w = [Math]::Max(700, $ui.LTrack.ActualWidth)
    $a = New-Object Windows.Media.Animation.DoubleAnimation ([double]-200), ([double]$w), (New-Object Windows.Duration ([TimeSpan]::FromSeconds(1.4)))
    $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.LShimmer.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $a)
}
function Stop-Shimmer {
    $ui.LShimmer.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null)
    $ui.LShimmer.Visibility = 'Collapsed'
}

function Show-Empty($e) {
    $ui.LEmptyGlyph.Text = $e.Glyph; $ui.LEmptyTitle.Text = $e.Title; $ui.LEmptyText.Text = $e.Text
    $ui.LEmpty.Visibility = 'Visible'; $ui.LList.Visibility = 'Collapsed'; $ui.LHeader.Visibility = 'Collapsed'
}
function Hide-Empty {
    $ui.LEmpty.Visibility = 'Collapsed'; $ui.LList.Visibility = 'Visible'; $ui.LHeader.Visibility = 'Visible'
}

function Set-Busy([bool]$busy) {
    $ui.NavPanel.IsEnabled = -not $busy
    foreach ($c in 'LX1', 'LX2', 'LAll', 'LNone', 'LSilent', 'LSearchBox') { $ui[$c].IsEnabled = -not $busy }
}

function Reset-Footer {
    $M = $Modes[$State.Mode]
    $ui.LGo.Visibility  = Vis $M.Go;  if ($M.Go)  { $ui.LGo.Content = $M.Go }
    $ui.LGo2.Visibility = Vis $M.Go2; if ($M.Go2) { $ui.LGo2.Content = $M.Go2 }
    $ui.LGo.IsEnabled = $false; $ui.LGo2.IsEnabled = $false
    $ui.LCancel.Content = if ($M.Go) { T 'ANNULLA' } else { T 'CHIUDI' }
    $ui.LCancel.IsEnabled = $true
}

function Start-Scan([hashtable]$Vars) {
    $M = $Modes[$State.Mode]
    $Items.Clear(); Hide-Empty; Reset-Footer; $ui.LReport.Visibility = 'Collapsed'
    $ui.LAll.IsEnabled = $false; $ui.LNone.IsEnabled = $false
    $ui.LSummary.Text = ''; $ui.LSub.Text = $M.Sub
    $sync.Error = $null; $sync.ScanInfo = $null; $sync.Status = $M.Sub
    $sync.Token++; $sync.Phase = 'scan'
    $win.UpdateLayout(); Start-Shimmer
    $code = "`$rows = New-Object System.Collections.ArrayList; `$sync.Rows = `$rows`ntry {`n" + $M.Scan +
            "`n} catch { `$sync.Error = `$_.Exception.Message; Write-ErrLog ('Analisi: ' + `$_.Exception.Message) }`nif (`$sync.Token -eq `$token) { `$sync.Phase = 'scanned' }"
    $v = @{ token = $sync.Token }
    if (-not $Vars) { $Vars = $State.Vars }
    if ($Vars) { foreach ($k in $Vars.Keys) { $v[$k] = $Vars[$k] } }
    Start-Bg $code $v
}

# --- Preparazione delle sezioni in background ---
$sync.Cache = [hashtable]::Synchronized(@{})
$PrefetchOrder = 'full', 'deliver', 'updates', 'installers', 'profiles', 'uninstall', 'backup', 'hw', 'wu', 'drivers',
                 'startup', 'cleanup', 'repair', 'privacy', 'security', 'network', 'bench', 'restore', 'history'
$PrefetchCode = @'
$realSync = $sync
try { [Threading.Thread]::CurrentThread.Priority = 'BelowNormal' } catch {}
$i = 0
foreach ($m in $list) {
    $i++
    while ($realSync.Phase -eq 'run' -and $realSync.PrefetchGen -eq $pgen) { Start-Sleep -Seconds 2 }
    if ($realSync.PrefetchGen -ne $pgen) { break }
    $realSync.PrefetchStatus = "$i/$($list.Count)"
    $sync = @{}
    $rows = New-Object System.Collections.ArrayList
    $err = $null
    try {
        if ($m -eq 'hw') { $realSync.HwCache = Get-HwInventory; continue }
        . ([scriptblock]::Create($codes[$m]))
    } catch { $err = $_.Exception.Message }
    if ($realSync.PrefetchGen -ne $pgen) { break }
    $realSync.Cache[$m] = @{ Rows = $rows; Info = $sync.ScanInfo; Error = $err; Time = Get-Date }
}
$sync = $realSync
if ($realSync.PrefetchGen -eq $pgen) { $realSync.PrefetchStatus = 'done' }
'@
function Start-Prefetch {
    if (-not $Settings.Prefetch) { $ui.PrefInfo.Text = ''; return }
    $sync.PrefetchGen = [int]$sync.PrefetchGen + 1
    $codes = @{}
    foreach ($m in $PrefetchOrder) { if ($Modes[$m] -and $Modes[$m].Scan) { $codes[$m] = $Modes[$m].Scan } }
    Start-Bg $PrefetchCode @{ list = $PrefetchOrder; codes = $codes; pgen = $sync.PrefetchGen }
}
function Invalidate-Cache {
    $sync.Cache.Clear(); $sync.HwCache = $null; $State.HwLoaded = $false
    Start-Prefetch
}
function Use-Cache([string]$m, $c) {
    $Items.Clear(); Hide-Empty; Reset-Footer; $ui.LReport.Visibility = 'Collapsed'
    $ui.LAll.IsEnabled = $false; $ui.LNone.IsEnabled = $false; $ui.LSummary.Text = ''
    $sync.Error = $c.Error; $sync.Rows = $c.Rows; $sync.ScanInfo = $c.Info
    $State.FromCache = $c.Time
    $sync.Token++; $sync.Phase = 'scanned'
}

function Stop-AnyScan {
    if ($sync.Phase -eq 'scan') { $sync.Token++; Stop-Shimmer }
    $sync.Phase = 'idle'
}

function Open-Mode([string]$m, [hashtable]$Vars) {
    Stop-AnyScan
    $State.Mode = $m; $State.Vars = $Vars
    $M = $Modes[$m]
    $Items.Clear()
    $ui.LTitle.Text = $M.Title; $ui.LSub.Text = $M.Sub; $ui.LSummary.Text = ''
    $ui.LH1.Text = $M.H[0]; $ui.LH2.Text = $M.H[1]; $ui.LH3.Text = $M.H[2]; $ui.LH4.Text = $M.H[3]
    $ui.LSearchBox.Visibility = Vis $M.Search
    $ui.LSilent.Visibility = Vis $M.Silent
    foreach ($x in 'X1', 'X2') {
        $b = $ui["L$x"]
        if ($M[$x]) { $b.Content = $M[$x].Text; $b.Visibility = 'Visible' } else { $b.Visibility = 'Collapsed' }
    }
    $ui.LCredits.Children.Clear()
    foreach ($c in @($M.Credits)) {
        if (-not $c) { continue }
        $b = New-Object Windows.Controls.Button
        $b.Style = $win.FindResource('LinkBtn')
        $b.Content = $c.T; $b.Tag = $c.U; $b.ToolTip = $c.U
        $b.FontSize = 12; $b.Padding = '6,2'; $b.Foreground = '#A78BFA'
        $b.Add_Click({ param($s, $e) Start-Process $s.Tag })
        [void]$ui.LCredits.Children.Add($b)
    }
    $ui.LCreditsBar.Visibility = Vis (@($M.Credits).Count -gt 0 -and $M.Credits)
    $ck = $M.Checks -ne $false
    $ui.LAll.Visibility = Vis $ck; $ui.LNone.Visibility = Vis $ck
    $ui.LFill.Width = 0; $ui.LReport.Visibility = 'Collapsed'
    Set-Busy $false
    Reset-Footer
    if ($ui[$M.Nav]) { $ui[$M.Nav].IsChecked = $true }
    Show-View 'ViewList'
    if ($M.Search) {
        $sync.Phase = 'review'; Show-Empty $M.Empty
        $ui.LSearch.Text = ''; [void]$ui.LSearch.Focus()
    } else {
        $c = $sync.Cache[$m]
        if ($c -and -not $Vars -and -not $c.Error -and ((Get-Date) - $c.Time).TotalMinutes -lt 20) { Use-Cache $m $c } else { Start-Scan }
    }
}

function Start-Action([string]$op) {
    $M = $Modes[$State.Mode]
    $noSel = $M.NoSelect -or (@($M.NoSelectOps) -contains $op)
    $sel = if ($noSel) { @() } else { @($Items | Where-Object { $_.Selected -and $_.Checkable }) }
    if ($op -ne 'web' -and $M.GoFilter) { $sel = @($sel | Where-Object $M.GoFilter) }
    if (-not $noSel -and -not $sel.Count) { if ($M.GoFilterMsg) { Toast $M.GoFilterMsg }; return }
    if ($M.ConfirmOp -and $M.ConfirmOp[$op]) {
        if ([Windows.MessageBox]::Show($M.ConfirmOp[$op], 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if ($M.Confirm) {
        if ([Windows.MessageBox]::Show(($M.Confirm -f $sel.Count), 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    foreach ($it in $Items) {
        if ($noSel -or -not $it.Checkable) { continue }
        $it.Editable = $false
        if ($sel -contains $it) { Set-It $it 'wait' 'In coda' } elseif ($it.StatusKind -eq 'none') { Set-It $it 'skip' 'Saltato' }
    }
    $sync.Total = [Math]::Max(1, $sel.Count); $sync.Done = 0; $sync.Cancel = $false; $sync.Extra = ''; $sync.ExtraRows = $null
    $sync.Status = 'Operazione in corso…'; $sync.Phase = 'run'
    $ui.LGo.IsEnabled = $false; $ui.LGo2.IsEnabled = $false
    $ui.LCancel.Content = 'ANNULLA'; $ui.LCancel.IsEnabled = $true
    Set-Busy $true
    $restore = [bool]$M.Restore -and [bool]$Settings.Restore -and $op -notin 'web', 'restore', 'enable'
    $code = @'
if ($restore) {
    $sync.Status = 'Creo un punto di ripristino…'
    if (New-RestorePoint "MultiTool - $area") { $sync.Toast = 'Punto di ripristino creato' }
    else { $sync.Toast = 'Punto di ripristino non creato (Protezione sistema disattivata?)' }
}
try {
'@ + "`n" + $M.Action + "`n" + @'
} catch { $sync.Extra = 'Errore: ' + $_.Exception.Message; Write-ErrLog "Azione $area`: $($_.Exception.Message)" }
$sync.Phase = 'done'
'@
    Start-Bg $code @{ items = $sel; op = $op; silent = [bool]$ui.LSilent.IsChecked; area = $M.Title; restore = $restore }
}

function Go-Home {
    Stop-AnyScan
    $ui.NavHome.IsChecked = $true
    Show-View 'ViewHome'
    Refresh-Info
}

function Refresh-Info {
    $State.InfoPending = $true
    $sync.Info = $null
    Start-Bg $InfoCode @{}
}

function Get-Counts($coll) {
    $ok   = @($coll | Where-Object { $_.StatusKind -eq 'ok' }).Count
    $err  = @($coll | Where-Object { $_.StatusKind -eq 'err' }).Count
    $skip = @($coll | Where-Object { $_.Status -eq 'Annullato' }).Count
    "$ok completati" + $(if ($err) { "  ·  $err con errori" } else { '' }) + $(if ($skip) { "  ·  $skip annullati" } else { '' })
}

# --- Hardware ---
$SensTpl = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="176" Margin="0,0,10,10" CornerRadius="12" Background="#161A25" BorderBrush="#232838" BorderThickness="1" Padding="14,10">
  <StackPanel>
    <TextBlock Name="n" FontSize="11" Foreground="#9AA0B8" TextTrimming="CharacterEllipsis"/>
    <TextBlock Name="v" FontSize="21" FontWeight="SemiBold" Foreground="#E8EAF2" Margin="0,2,0,0"/>
    <TextBlock Name="g" FontSize="11" Foreground="#6B7290" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
</Border>
'@
$State.Tiles = @{}
function Open-Hw {
    Stop-AnyScan
    $ui.NavHw.IsChecked = $true
    Show-View 'ViewHw'
    if (-not $State.HwLoaded) {
        if ($sync.HwCache) { $State.HwLoaded = $true; $sync.Hw = $sync.HwCache } else { Load-Hw }
    }
    $State.HwOpening = $true; Start-Sensors; $State.HwOpening = $false
}
function Load-Hw {
    $State.HwLoaded = $true
    $ui.HwCol1.Children.Clear(); $ui.HwCol2.Children.Clear()
    $sync.Hw = $null; $sync.HwStatus = 'Raccolgo le informazioni…'
    Start-Bg $HwCode @{}
}
function Start-Sensors {
    $sync.SensGen = [int]$sync.SensGen + 1; $sync.SensOn = ($ui.ViewHw.Visibility -eq 'Visible' -or $State.HwOpening); $sync.SensLog = [bool]$Settings.SensLog; $sync.SensMsg = $null; $sync.SensVer = 0
    $ui.HwSens.Children.Clear(); $State.Tiles = @{}; $State.SensSeen = -1
    $useLhm = [bool]$Settings.Lhm
    $ui.HwAdv.Content = if ($useLhm) { 'Sensori avanzati: attivi' } else { 'Attiva sensori avanzati' }
    $ui.HwSensMsg.Text = if ($useLhm) { 'Lettura dei sensori…' } else { 'Windows espone solo alcuni sensori (zone termiche, dischi, carico). Per temperature dei core, ventole e consumi premi "Attiva sensori avanzati".' }
    Start-Bg $SensCode @{ gen = $sync.SensGen; useLhm = $useLhm }
}
function New-HwCard($c) {
    $E = { param($t) [Security.SecurityElement]::Escape([string]$t) }
    $rd = ($c.Rows | ForEach-Object { '<RowDefinition Height="Auto"/>' }) -join ''
    $i = 0
    $cells = foreach ($r in $c.Rows) {
        "<TextBlock Grid.Row=`"$i`" Text=`"$(& $E $r.L)`" Foreground=`"#9AA0B8`" FontSize=`"13`" Margin=`"0,4,12,4`"/>" +
        "<TextBox Grid.Row=`"$i`" Grid.Column=`"1`" Text=`"$(& $E $r.V)`" IsReadOnly=`"True`" BorderThickness=`"0`" Background=`"Transparent`" Foreground=`"#E8EAF2`" FontSize=`"13`" TextWrapping=`"Wrap`" Margin=`"0,4,0,4`" Padding=`"0`"/>"
        $i++
    }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" CornerRadius="18" Background="#12151D" BorderBrush="#1F2434" BorderThickness="1" Padding="22" Margin="6">
  <StackPanel>
    <StackPanel Orientation="Horizontal">
      <Border Width="32" Height="32" CornerRadius="9" Background="#7C5CFF"><TextBlock Text="$(& $E $c.G)" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      <TextBlock Text="$(& $E $c.T)" FontSize="17" FontWeight="SemiBold" Foreground="#E8EAF2" Margin="12,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
    <Grid Margin="0,14,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" MinWidth="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions>$rd</Grid.RowDefinitions>
      $($cells -join "`n")
    </Grid>
  </StackPanel>
</Border>
"@
    [Windows.Markup.XamlReader]::Parse((Apply-Theme $x))
}
function Export-Hw {
    if (-not $State.HwCards) { Toast 'Attendi la fine della raccolta delle informazioni'; return }
    $dir = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ('{0}-Inventario-hardware.html' -f (Get-Date -Format 'yyyyMMdd-HHmm'))
    $E = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $body = foreach ($c in $State.HwCards) {
        "<h2>$(& $E $c.T)</h2><table>" + (($c.Rows | ForEach-Object { "<tr><th>$(& $E $_.L)</th><td>$(& $E $_.V)</td></tr>" }) -join '') + '</table>'
    }
    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>Inventario hardware - $env:COMPUTERNAME</title>
<style>body{font-family:Segoe UI,sans-serif;background:#f4f5f9;color:#1b1e27;margin:40px;max-width:1000px}h1{margin:0}h2{font-size:17px;margin:28px 0 8px}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 1px 3px #0001}
th,td{padding:9px 14px;text-align:left;border-bottom:1px solid #eceef4;font-size:14px}th{width:220px;color:#5b6175;font-weight:600}.m{color:#5b6175}</style></head>
<body><h1>Inventario hardware</h1><p class="m">$env:COMPUTERNAME  ·  $(Get-Date -Format 'dd/MM/yyyy HH:mm')  ·  MultiTool $AppVersion</p>$($body -join '')</body></html>
"@
    Set-Content -Path $file -Value $html -Encoding UTF8
    Start-Process $file
}

# --- Backup / ripristino ---
function Select-BackupDest {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Scegli dove salvare il backup (disco esterno, chiavetta o cartella di rete)'
    if ($Settings.BackupDest -and (Test-Path $Settings.BackupDest)) { $d.SelectedPath = $Settings.BackupDest }
    if ($d.ShowDialog() -eq 'OK') {
        if ($d.SelectedPath -like "$env:SystemDrive\*" -and [Windows.MessageBox]::Show('La destinazione è sullo stesso disco di Windows: se il disco si guasta perdi anche il backup. Usarla comunque?', 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return }
        $Settings.BackupDest = $d.SelectedPath; Save-Json 'settings.json' $Settings
        Update-BackupTask
        if ($State.Mode -eq 'backup') { Start-Scan }
    }
}
$BkTaskName = 'MultiTool - Backup automatico'
function Update-BackupTask {
    try {
        if ($Settings.BackupAuto -and $Settings.BackupDest) {
            $vbs = Join-Path $DataDir 'backup.vbs'
            @('Set sh = CreateObject("WScript.Shell")', ('sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ScriptPath + '"" -Backup", 0, True')) | Set-Content $vbs -Encoding ASCII
            $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
            $trg = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($Settings.BackupTime, 'H:mm', $null))
            $pr  = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
            $st  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
            Register-ScheduledTask -TaskName $BkTaskName -Action $act -Trigger $trg -Principal $pr -Settings $st -Force | Out-Null
        } else { Unregister-ScheduledTask -TaskName $BkTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    } catch { Toast "Pianificazione backup non riuscita: $($_.Exception.Message)" }
    Update-BackupInfo
}
function Update-BackupInfo {
    $last = if ($Settings.LastBackup) { ([datetime]$Settings.LastBackup).ToString('dd/MM/yyyy HH:mm') } else { 'mai' }
    $ui.SetBkInfo.Text = "Destinazione: $(if ($Settings.BackupDest) { $Settings.BackupDest } else { 'non scelta (vai in Backup)' })  ·  ultimo backup: $last"
}
function Remove-OldestRestore {
    if ([Windows.MessageBox]::Show('Eliminare il punto di ripristino più vecchio?', 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { return }
    Start-Bg '$r = Invoke-Hidden "$env:SystemRoot\System32\vssadmin.exe" "delete shadows /for=$env:SystemDrive /oldest /quiet"; $sync.Toast = $(if ($r.Code -eq 0) { "Punto di ripristino eliminato" } else { "Eliminazione non riuscita (codice $($r.Code))" })' @{}
    Toast 'Elimino il punto più vecchio…'
}
function Restore-DriverBackup {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Scegli la cartella di backup dei driver (Dati\DriverBackup\data)'
    $bk = Join-Path $DataDir 'DriverBackup'; if (Test-Path $bk) { $d.SelectedPath = $bk }
    if ($d.ShowDialog() -ne 'OK') { return }
    if (-not (Get-ChildItem $d.SelectedPath -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1)) { Toast 'Nella cartella non ci sono driver (.inf)'; return }
    Toast 'Reinstallo i driver dal backup…'
    Start-Bg @'
$r = Invoke-Hidden "$env:SystemRoot\System32\pnputil.exe" "/add-driver `"$path\*.inf`" /subdirs /install"
$n = ([regex]::Matches($r.Out, '(?im)^(Driver package added|Pacchetto driver aggiunto)')).Count
$sync.Toast = if ($r.Code -in 0, 3010) { "Driver reinstallati dal backup ($n pacchetti)" } else { "Ripristino driver: codice $($r.Code)" }
if ($r.Code -eq 3010) { $sync.Reboot = $true }
Add-History 'Driver' 'Ripristino driver da backup' "Codice $($r.Code)" $(if ($r.Code -in 0, 3010) { 'ok' } else { 'err' })
'@ @{ path = $d.SelectedPath }
}

# --- Storico sensori ---
function Export-SensorHistory {
    $f = Join-Path $DataDir 'sensori.csv'
    if (-not (Test-Path $f)) { Toast 'Nessun dato: attiva "Registra temperature e ventole" in Impostazioni o tieni aperta la sezione Hardware'; return }
    $since = (Get-Date).AddHours(-48)
    $data = Import-Csv $f -Delimiter ';' -Header T, G, N, K, V -Encoding UTF8 | Where-Object { [datetime]$_.T -ge $since }
    if (-not $data) { Toast 'Nessun dato nelle ultime 48 ore'; return }
    $groups = $data | Group-Object { "$($_.G) · $($_.N)" } | Sort-Object { ($_.Group | Select-Object -First 1).K }, Name | Select-Object -First 16
    $colors = '#7C5CFF', '#22D3EE', '#F87171', '#FBBF24', '#34D399', '#F472B6', '#60A5FA', '#A3E635'
    $i = 0
    $sets = foreach ($g in $groups) {
        $pts = ($g.Group | ForEach-Object { "{x:'$(([datetime]$_.T).ToString('s'))',y:$(([double]($_.V -replace ',', '.')).ToString([Globalization.CultureInfo]::InvariantCulture))}" }) -join ','
        $axis = if (($g.Group | Select-Object -First 1).K -eq 'Fan') { 'y2' } else { 'y' }
        "{label:$(ConvertTo-Json $g.Name),data:[$pts],borderColor:'$($colors[$i % 8])',yAxisID:'$axis',pointRadius:0,borderWidth:1.5,tension:.2}"; $i++
    }
    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>Storico sensori - $env:COMPUTERNAME</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
<style>body{font-family:Segoe UI,sans-serif;background:#0b0d12;color:#e8eaf2;margin:30px}h1{margin:0 0 4px}p{color:#9aa0b8;margin:0 0 20px}.c{background:#12151d;border:1px solid #1f2434;border-radius:16px;padding:20px;height:70vh}</style></head>
<body><h1>Storico sensori</h1><p>$env:COMPUTERNAME  ·  ultime 48 ore  ·  temperature in °C a sinistra, ventole in RPM a destra</p><div class="c"><canvas id="c"></canvas></div>
<script>Chart.defaults.color='#9aa0b8';Chart.defaults.borderColor='#1f2434';
new Chart(document.getElementById('c'),{type:'line',data:{datasets:[$($sets -join ',')]},options:{maintainAspectRatio:false,parsing:true,interaction:{mode:'nearest',intersect:false},
scales:{x:{type:'time',time:{tooltipFormat:'dd/MM HH:mm'}},y:{title:{display:true,text:'°C'}},y2:{position:'right',title:{display:true,text:'RPM'},grid:{drawOnChartArea:false}}}}});</script></body></html>
"@
    $out = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory $out -Force | Out-Null
    $file = Join-Path $out 'Storico-sensori.html'
    Set-Content -Path $file -Value $html -Encoding UTF8
    Start-Process $file
}

# --- Installazione nel PC ---
$InstTarget = Join-Path $env:ProgramFiles 'MultiTool'
$UninstKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MultiTool'
function Install-Self {
    try {
        New-Item -ItemType Directory -Path $InstTarget -Force | Out-Null
        foreach ($f in 'MultiTool.ps1', 'MultiTool.exe', 'MultiTool.ico', 'Avvia.vbs', 'MultiTool-512.png') {
            $src = Join-Path $Root $f; if (Test-Path $src) { Copy-Item $src $InstTarget -Force }
        }
        $pd = Join-Path $env:ProgramData 'MultiTool'
        foreach ($d in 'Installers', 'Profili', 'Dati') {
            $src = Join-Path $Base $d; $dst = Join-Path $pd $d
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            if (Test-Path $src) { Copy-Item "$src\*" $dst -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $exe = Join-Path $InstTarget 'MultiTool.exe'
        $sh = New-Object -ComObject WScript.Shell
        foreach ($lnkDir in [Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('CommonDesktopDirectory')) {
            $l = $sh.CreateShortcut((Join-Path $lnkDir 'MultiTool.lnk')); $l.TargetPath = $exe; $l.WorkingDirectory = $InstTarget
            $l.IconLocation = "$exe,0"; $l.Description = 'Manutenzione del PC'; $l.Save()
        }
        New-Item -Path $UninstKey -Force | Out-Null
        $size = [int]((Get-ChildItem $InstTarget -Recurse | Measure-Object Length -Sum).Sum / 1KB)
        $vals = @{ DisplayName = 'MultiTool'; DisplayVersion = $AppVersion; Publisher = $(if ($Settings.ShopName) { $Settings.ShopName } else { 'MultiTool' })
                   DisplayIcon = "$exe,0"; InstallLocation = $InstTarget; UninstallString = "`"$exe`" -Uninstall"; URLInfoAbout = [string]$Settings.ShopWeb }
        foreach ($k in $vals.Keys) { Set-ItemProperty $UninstKey -Name $k -Value $vals[$k] }
        foreach ($k in 'NoModify', 'NoRepair') { Set-ItemProperty $UninstKey -Name $k -Value 1 -Type DWord }
        Set-ItemProperty $UninstKey -Name EstimatedSize -Value $size -Type DWord
        if ([Windows.MessageBox]::Show("MultiTool è installato in $InstTarget, con collegamenti nel menu Start e sul desktop.`n`nAprire ora la versione installata?", 'MultiTool', 'YesNo', 'Information') -eq 'Yes') {
            $State.ForceClose = $true; $Mutex.ReleaseMutex()
            Start-Process $exe; $win.Close()
        }
    } catch { Toast "Installazione non riuscita: $($_.Exception.Message)" }
}

# --- Rapporto HTML ---
function Export-Report([string]$Summary) {
    $M = $Modes[$State.Mode]
    $dir = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ('{0}-{1}.html' -f (Get-Date -Format 'yyyyMMdd-HHmm'), ($M.Title -replace '[^\w]+', '-'))
    $E = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $rowsHtml = foreach ($it in $Items) {
        if ($it.StatusKind -eq 'none') { continue }
        "<tr><td><b>$(& $E $it.Name)</b><div class='s'>$(& $E $it.Sub)</div></td><td>$(& $E $it.C1)</td><td>$(& $E $it.C2)</td><td><span class='p $($it.StatusKind)'>$(& $E $it.Status)</span></td></tr>"
    }
    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>MultiTool - $(& $E $M.Title)</title>
<style>body{font-family:Segoe UI,sans-serif;background:#f4f5f9;color:#1b1e27;margin:40px}h1{margin:0;font-size:28px}
.m{color:#5b6175;margin:6px 0 24px}table{width:100%;border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 1px 3px #0001}
th,td{padding:12px 14px;text-align:left;border-bottom:1px solid #eceef4;font-size:14px;vertical-align:top}th{font-size:11px;color:#8a90a6;text-transform:uppercase}
.s{color:#7a8096;font-size:12px;margin-top:2px}.p{padding:3px 10px;border-radius:8px;font-size:12px;font-weight:600;background:#eceef4}
.ok{background:#d7f5ea;color:#047857}.err{background:#fde2e2;color:#b91c1c}.skip{color:#8a90a6}.run,.wait{background:#dce8ff;color:#1d4ed8}</style></head>
<body><h1>$(& $E $M.Title)</h1><div class="m">$env:COMPUTERNAME  ·  $(Get-Date -Format 'dd/MM/yyyy HH:mm')  ·  $(& $E $Summary)</div>
<table><tr><th>Elemento</th><th>Prima</th><th>Dopo</th><th>Esito</th></tr>$($rowsHtml -join '')</table>
<p class="m" style="margin-top:20px">Generato da MultiTool $AppVersion</p></body></html>
"@
    Set-Content -Path $file -Value $html -Encoding UTF8
    $State.Report = $file
    $ui.LReport.Visibility = 'Visible'
}

# --- Log ---
function Load-Logs {
    $d = Join-Path $DataDir 'Logs'; New-Item -ItemType Directory -Path $d -Force | Out-Null
    $ui.LogFiles.ItemsSource = @(Get-ChildItem $d -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $ui.LogText.Text = if ($ui.LogFiles.Items.Count) { '' } else { 'Nessun log presente.' }
    if ($ui.LogFiles.Items.Count) { $ui.LogFiles.SelectedIndex = 0 }
}

# --- Auto-aggiornamento ---
$UpdCode = @'
try {
    $u = $url.TrimEnd('/')
    $v = (Invoke-WebRequest "$u/version.txt" -UseBasicParsing -TimeoutSec 20).Content.Trim()
    $sync.NewVersion = if ([version]$v -gt [version]$cur) { $v } else { '' }
    $sync.UpdChecked = $true
} catch { $sync.NewVersion = ''; $sync.UpdChecked = $true; $sync.UpdError = $_.Exception.Message }
'@
function Start-UpdCheck {
    if (-not $Settings.UpdateUrl) { $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  nessun indirizzo di aggiornamento impostato"; return }
    $sync.UpdChecked = $false; $sync.UpdError = $null
    $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  controllo in corso…"
    Start-Bg $UpdCode @{ url = $Settings.UpdateUrl; cur = $AppVersion }
}
function Install-SelfUpdate {
    try {
        $u = $Settings.UpdateUrl.TrimEnd('/')
        $tmp = Join-Path $env:TEMP 'MultiTool-new.ps1'
        Invoke-WebRequest "$u/MultiTool.ps1" -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        $errs = $null; $tok = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tok, [ref]$errs)
        if ($errs.Count -or -not (Select-String -Path $tmp -Pattern '\$AppVersion' -Quiet)) { throw 'il file scaricato non è valido' }
        Copy-Item $ScriptPath (Join-Path $DataDir "backup-MultiTool-$AppVersion.ps1") -Force
        Copy-Item $tmp $ScriptPath -Force
        Restart-App
    } catch { Toast "Aggiornamento non riuscito: $($_.Exception.Message)" }
}
function Restart-App {
    $State.ForceClose = $true
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`"" -WindowStyle Hidden
    $Mutex.ReleaseMutex()
    $win.Close()
}

# --- Icona nell'area di notifica ---
$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = if (Test-Path $IcoPath) { New-Object System.Drawing.Icon $IcoPath } else { [System.Drawing.SystemIcons]::Application }
$Tray.Text = 'MultiTool'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Apri MultiTool')
$miUpd  = $menu.Items.Add('Aggiorna programmi')
$miFull = $menu.Items.Add('Manutenzione completa')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Esci')
$Tray.ContextMenuStrip = $menu
function Show-Main { $win.Show(); if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }; [void]$win.Activate() }
$Tray.Add_DoubleClick({ Show-Main })
$Tray.Add_BalloonTipClicked({ Show-Main; Open-Mode 'updates' })
$miOpen.Add_Click({ Show-Main })
$miUpd.Add_Click({ Show-Main; Open-Mode 'updates' })
$miFull.Add_Click({ Show-Main; Open-Mode 'full' })
$miExit.Add_Click({ $State.ForceClose = $true; Show-Main; $win.Close() })
$Tray.Visible = [bool]$Settings.Tray

$CountCode = @'
try {
    $excl = Read-Exclusions
    $r = Invoke-Hidden (Get-WingetPath) 'upgrade --include-unknown --accept-source-agreements --disable-interactivity'
    $sync.UpdCount = @(ConvertFrom-WingetTable $r.Out | Where-Object { $_.Cols.Count -ge 4 -and $excl -notcontains $_.Cols[1] }).Count
} catch { $sync.UpdCount = -1 }
'@
function Start-CountCheck { $sync.UpdCount = $null; Start-Bg $CountCode @{} }
$bgTimer = New-Object Windows.Threading.DispatcherTimer
$bgTimer.Interval = [TimeSpan]::FromHours(6)
$bgTimer.Add_Tick({ if ($sync.Phase -ne 'run') { Start-CountCheck } })
$bgTimer.Start()

# --- Azioni speciali ---
function Add-Exclusions {
    $ex = [System.Collections.ArrayList]@(Read-Exclusions)
    $n = 0
    foreach ($it in @($Items | Where-Object Selected)) {
        if ($ex -notcontains $it.Key) { [void]$ex.Add($it.Key) }
        $it.Selected = $false; $it.Tag = 'escluso'; $it.TagKind = 'warn'; $n++
    }
    Save-Json 'exclusions.json' @($ex)
    Toast $(if ($n) { "$n programmi esclusi dagli aggiornamenti" } else { 'Seleziona prima i programmi da escludere' })
}

function Clear-History2 {
    if ([Windows.MessageBox]::Show('Svuotare la cronologia?', 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { return }
    Remove-Item (Join-Path $DataDir 'history.jsonl') -ErrorAction SilentlyContinue
    Start-Scan
}

function Start-DriverBackup {
    $dest = Join-Path $DataDir ('DriverBackup\' + (Get-Date -Format 'yyyy-MM-dd_HHmm'))
    Toast 'Backup dei driver in corso…'
    Start-Bg @'
try {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Export-WindowsDriver -Online -Destination $dest -ErrorAction Stop | Out-Null
    $sync.Toast = "Backup driver completato in Dati\DriverBackup"
    Add-History 'Driver' 'Backup driver' 'Completato' 'ok'
} catch { $sync.Toast = "Backup driver non riuscito: $($_.Exception.Message)" }
'@ @{ dest = $dest }
}

# ============================================================
#  Eventi
# ============================================================
$navMap = @{ NavUpdates = 'updates'; NavInstall = 'installers'; NavCatalog = 'catalog'; NavProfiles = 'profiles'; NavUninstall = 'uninstall'
             NavWU = 'wu'; NavDrivers = 'drivers'; NavStartup = 'startup'; NavCleanup = 'cleanup'; NavRepair = 'repair'; NavHistory = 'history'
             NavFull = 'full'; NavPrivacy = 'privacy'; NavDeliver = 'deliver'; NavBackup = 'backup'; NavNetwork = 'network'
             NavSecurity = 'security'; NavBench = 'bench'; NavRestore = 'restore' }
foreach ($n in $navMap.Keys) {
    $ui[$n].Add_Click({ param($s, $e) Open-Mode $navMap[$s.Name] })
}
$ui.NavHome.Add_Click({ Go-Home })
$ui.NavSettings.Add_Click({ Stop-AnyScan; Show-View 'ViewSettings' })
$ui.NavLogs.Add_Click({ Stop-AnyScan; Show-View 'ViewLogs'; Load-Logs })
$ui.NavHw.Add_Click({ Open-Hw })
$ui.HHwMore.Add_Click({ Open-Hw })
$ui.HwReload.Add_Click({ Load-Hw; Start-Sensors })
$ui.HwExport.Add_Click({ Export-Hw })
$ui.HwHist.Add_Click({ Export-SensorHistory })
$ui.HwLabel.Add_Click({ Toast 'Creo l''etichetta…'; Start-Bg '$f = New-PcLabel; Start-Process $f' @{} })
foreach ($b in 'HwCr1', 'HwCr2', 'HwCr3', 'HwCr4') { $ui[$b].Add_Click({ param($s, $e) Start-Process $s.Tag }) }
$ui.HwAdv.Add_Click({
    if ($Settings.Lhm) {
        if ([Windows.MessageBox]::Show('Disattivare i sensori avanzati?', 'MultiTool', 'YesNo', 'Question') -eq 'Yes') {
            $Settings.Lhm = $false; Save-Json 'settings.json' $Settings; Start-Sensors
        }
        return
    }
    $msg = "Per leggere temperature dei core, ventole e consumi serve un componente che accede ai sensori della scheda madre." +
           "`n`nVerranno installati tramite winget:`n- LibreHardwareMonitor (open source)`n- PawnIO, il driver firmato che usa per leggere i sensori`n`nProcedere?"
    if ([Windows.MessageBox]::Show($msg, 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { return }
    if (Find-LhmDll) { $sync.LhmResult = 'ok' }
    else { $ui.HwAdv.IsEnabled = $false; $ui.HwSensMsg.Text = 'Installazione in corso…'; $sync.LhmResult = $null; Start-Bg $LhmInstallCode @{} }
})
$ui.LogFiles.Add_SelectionChanged({
    $f = $ui.LogFiles.SelectedItem
    if ($f) { try { $ui.LogText.Text = (Get-Content $f.FullName -Tail 3000 -ErrorAction Stop) -join "`r`n"; $ui.LogText.ScrollToEnd() } catch { $ui.LogText.Text = $_.Exception.Message } }
})
$ui.LogReload.Add_Click({ Load-Logs })
$ui.LogOpen.Add_Click({ Start-Process explorer.exe (Join-Path $DataDir 'Logs') })
$ui.LogDelete.Add_Click({
    if ([Windows.MessageBox]::Show('Eliminare tutti i log?', 'MultiTool', 'YesNo', 'Question') -eq 'Yes') {
        Get-ChildItem (Join-Path $DataDir 'Logs') -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Load-Logs
    }
})
$ui.LReport.Add_Click({ if ($State.Report) { Start-Process $State.Report } })

$ui.QUpd.Add_Click({ Open-Mode 'updates' })
$ui.QWU.Add_Click({ Open-Mode 'wu' })
$ui.QDrv.Add_Click({ Open-Mode 'full' })
$ui.QClean.Add_Click({ Open-Mode 'cleanup' })

$ui.LX1.Add_Click({ & $Modes[$State.Mode].X1.Click })
$ui.LX2.Add_Click({ & $Modes[$State.Mode].X2.Click })
$ui.LAll.Add_Click({  foreach ($i in $Items) { if ($i.Checkable -and $i.Editable) { $i.Selected = $true } } })
$ui.LNone.Add_Click({ foreach ($i in $Items) { if ($i.Checkable -and $i.Editable) { $i.Selected = $false } } })
$ui.LGo.Add_Click({  Start-Action ([string]$Modes[$State.Mode].GoOp) })
$ui.LGo2.Add_Click({ Start-Action ([string]$Modes[$State.Mode].Go2Op) })
$ui.LCancel.Add_Click({
    if ($sync.Phase -eq 'run') {
        $sync.Cancel = $true
        $ui.LCancel.IsEnabled = $false; $ui.LCancel.Content = 'Annullamento…'
        $ui.LSub.Text = 'Annullamento dopo l''elemento in corso…'
        return
    }
    if ($Modes[$State.Mode].Nav -eq 'NavSettings') { Stop-AnyScan; Show-View 'ViewSettings' } else { Go-Home }
})

$doSearch = {
    $q = ($ui.LSearch.Text -replace '["`]', '').Trim()
    if ($q.Length -ge 2) { $State.Vars = @{ query = $q }; Start-Scan }
}
$ui.LSearchGo.Add_Click($doSearch)
$ui.LSearch.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $doSearch } })

$ui.RebootGo.Add_Click({
    if ([Windows.MessageBox]::Show('Riavviare il computer adesso? Salva prima il lavoro aperto.', 'MultiTool', 'YesNo', 'Warning') -eq 'Yes') {
        Restart-Computer -Force
    }
})

# --- Impostazioni ---
$days = 'SetD1', 'SetD2', 'SetD3', 'SetD4', 'SetD5', 'SetD6', 'SetD7'
$ui.SetRestore.IsChecked = [bool]$Settings.Restore
$ui.SetAuto.IsChecked = [bool]$Settings.AutoEnabled
$ui.SetTime.Text = $Settings.AutoTime
foreach ($d in $days) { if ($ui[$d].Tag -eq $Settings.AutoDay) { $ui[$d].IsChecked = $true } }

$TaskName = 'MultiTool - Aggiornamento automatico'
function Update-AutoInfo {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $ui.SetAutoInfo.Text = if ($t) {
        $nx = (Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue).NextRunTime
        if ($nx) { "Prossima esecuzione: $($nx.ToString('ddd dd/MM HH:mm'))" } else { 'Attività pianificata attiva' }
    } else { 'Non pianificato' }
}

$ui.SetRestore.Add_Click({
    $Settings.Restore = [bool]$ui.SetRestore.IsChecked
    Save-Json 'settings.json' $Settings
})

$ui.SetSave.Add_Click({
    $time = $ui.SetTime.Text.Trim()
    if ($time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { Toast 'Orario non valido: usa il formato HH:MM'; return }
    $day = ($days | ForEach-Object { $ui[$_] } | Where-Object { $_.IsChecked } | Select-Object -First 1).Tag
    if (-not $day) { $day = 'Sunday' }
    $Settings.AutoEnabled = [bool]$ui.SetAuto.IsChecked; $Settings.AutoDay = $day; $Settings.AutoTime = $time
    Save-Json 'settings.json' $Settings
    try {
        if ($Settings.AutoEnabled) {
            $vbs = Join-Path $DataDir 'auto.vbs'
            @(
                'Set sh = CreateObject("WScript.Shell")'
                ('sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ScriptPath + '"" -Auto", 0, True')
            ) | Set-Content $vbs -Encoding ASCII
            $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
            $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At ([datetime]::ParseExact($time, 'H:mm', $null))
            $pr  = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
            $st  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
            Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $pr -Settings $st -Force | Out-Null
            Toast 'Aggiornamento automatico pianificato'
        } else {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Toast 'Aggiornamento automatico disattivato'
        }
    } catch { Toast "Errore pianificazione: $($_.Exception.Message)" }
    Update-AutoInfo
})

$ui.SetExcl.Add_Click({ Open-Mode 'exclusions' })
$ui.SetImport.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Elenco winget (*.json)|*.json'
    if ($dlg.ShowDialog($win)) { Open-Mode 'import' @{ file = $dlg.FileName } }
})
$ui.SetExport.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Elenco winget (*.json)|*.json'
    $dlg.FileName = "programmi-$env:COMPUTERNAME.json"
    if (-not $dlg.ShowDialog($win)) { return }
    Toast 'Esportazione in corso…'
    Start-Bg @'
try {
    $r = Invoke-Hidden (Get-WingetPath) "export -o `"$file`" --accept-source-agreements --disable-interactivity"
    $sync.Toast = if (Test-Path $file) { 'Elenco esportato. Usa "Importa elenco" sull''altro PC.' } else { 'Esportazione non riuscita' }
} catch { $sync.Toast = "Errore: $($_.Exception.Message)" }
'@ @{ file = $dlg.FileName }
})
$ui.SetOpenInst.Add_Click({ Start-Process explorer.exe $InstDir })
$ui.SetOpenProf.Add_Click({ Start-Process explorer.exe $ProfDir })
$ui.SetOpenData.Add_Click({ Start-Process explorer.exe $DataDir })
$ui.SetOpenRep.Add_Click({ $d = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory $d -Force | Out-Null; Start-Process explorer.exe $d })
foreach ($tb in 'SetShopName', 'SetShopPhone', 'SetShopEmail', 'SetShopWeb', 'SetWarranty') {
    $ui[$tb].Text = [string]$Settings.($ui[$tb].Tag)
    $ui[$tb].Add_LostFocus({
        param($s, $e)
        $v = $s.Text.Trim()
        if ($s.Tag -eq 'WarrantyMonths') { $n = 0; if ([int]::TryParse($v, [ref]$n) -and $n -ge 0) { $v = $n } else { $s.Text = $Settings.WarrantyMonths; return } }
        $Settings.($s.Tag) = $v; Save-Json 'settings.json' $Settings
    })
}
$ui.SetLogoInfo.Text = if ($Settings.ShopLogo) { Split-Path $Settings.ShopLogo -Leaf } else { 'nessuno' }
$ui.SetLogo.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Filter = 'Immagini (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg'
    if ($d.ShowDialog($win)) {
        $dst = Join-Path $DataDir ('logo' + [IO.Path]::GetExtension($d.FileName)); Copy-Item $d.FileName $dst -Force
        $Settings.ShopLogo = $dst; Save-Json 'settings.json' $Settings; $ui.SetLogoInfo.Text = Split-Path $d.FileName -Leaf
    }
})
$ui.SetBkAuto.IsChecked = [bool]$Settings.BackupAuto
$ui.SetBkTime.Text = $Settings.BackupTime
$ui.SetBkSave.Add_Click({
    $t = $ui.SetBkTime.Text.Trim()
    if ($t -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { Toast 'Orario non valido: usa il formato HH:MM'; return }
    if ($ui.SetBkAuto.IsChecked -and -not $Settings.BackupDest) { Toast 'Scegli prima la destinazione nella sezione Backup'; $ui.SetBkAuto.IsChecked = $false; return }
    $Settings.BackupAuto = [bool]$ui.SetBkAuto.IsChecked; $Settings.BackupTime = $t; Save-Json 'settings.json' $Settings
    Update-BackupTask; Toast $(if ($Settings.BackupAuto) { "Backup automatico ogni giorno alle $t" } else { 'Backup automatico disattivato' })
})
$ui.SetSensLog.IsChecked = [bool]$Settings.SensLog
$ui.SetSensLog.Add_Click({
    $Settings.SensLog = [bool]$ui.SetSensLog.IsChecked; Save-Json 'settings.json' $Settings
    $sync.SensLog = $Settings.SensLog
    if ($Settings.SensLog -and $ui.ViewHw.Visibility -ne 'Visible') { Start-Sensors }
})
$ui.SetInstInfo.Text = if ($Installed) { "Installato in $Root  ·  dati in $Base" } else { "In esecuzione da $Root (versione portatile)" }
$ui.SetInstall.Visibility = Vis (-not $Installed)
$ui.SetUninst.Visibility = Vis $Installed
$ui.SetInstall.Add_Click({ Install-Self })
$ui.SetUninst.Add_Click({
    $un = Join-Path $Root 'Uninstall.exe'
    if (Test-Path $un) { Start-Process $un } else { Start-Process (Join-Path $Root 'MultiTool.exe') '-Uninstall' }
    $State.ForceClose = $true; $Mutex.ReleaseMutex(); $win.Close()
})
$ui.SetEnglish.IsChecked = ($Settings.Lang -eq 'en')
$ui.SetEnglish.Add_Click({
    $Settings.Lang = if ($ui.SetEnglish.IsChecked) { 'en' } else { 'it' }; Save-Json 'settings.json' $Settings
    if ($sync.Phase -ne 'run') { Restart-App }
})
Update-BackupInfo
$ui.SetLight.IsChecked = ($Settings.Theme -eq 'light')
$ui.SetTray.IsChecked = [bool]$Settings.Tray
$ui.SetPrefetch.IsChecked = [bool]$Settings.Prefetch
$ui.SetPrefetch.Add_Click({
    $Settings.Prefetch = [bool]$ui.SetPrefetch.IsChecked; Save-Json 'settings.json' $Settings
    if ($Settings.Prefetch) { Start-Prefetch } else { $sync.PrefetchGen = [int]$sync.PrefetchGen + 1; $ui.PrefInfo.Text = '' }
})
$ui.SetUpdUrl.Text = [string]$Settings.UpdateUrl
$ui.SetLight.Add_Click({
    $Settings.Theme = if ($ui.SetLight.IsChecked) { 'light' } else { 'dark' }
    Save-Json 'settings.json' $Settings
    if ($sync.Phase -ne 'run') { Restart-App } else { Toast 'Il tema verrà applicato al prossimo avvio' }
})
$ui.SetTray.Add_Click({ $Settings.Tray = [bool]$ui.SetTray.IsChecked; $Tray.Visible = $Settings.Tray; Save-Json 'settings.json' $Settings })
$ui.SetUpdUrl.Add_LostFocus({ $Settings.UpdateUrl = $ui.SetUpdUrl.Text.Trim(); Save-Json 'settings.json' $Settings })
$ui.SetUpdCheck.Add_Click({ $Settings.UpdateUrl = $ui.SetUpdUrl.Text.Trim(); Save-Json 'settings.json' $Settings; Start-UpdCheck })
$ui.SetUpdGo.Add_Click({
    if ($sync.Phase -eq 'run') { Toast 'Attendi la fine dell''operazione in corso'; return }
    if ([Windows.MessageBox]::Show("Aggiornare MultiTool alla versione $($sync.NewVersion)? Il programma verrà riavviato.", 'MultiTool', 'YesNo', 'Question') -eq 'Yes') { Install-SelfUpdate }
})

# ============================================================
#  Timer di aggiornamento UI
# ============================================================
$DiskTpl = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,18">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock FontSize="14" FontWeight="SemiBold" Foreground="#E8EAF2" Text="{0}"/>
  <TextBlock HorizontalAlignment="Right" FontSize="12" Foreground="#9AA0B8" Text="{1}"/>
  <Border Grid.Row="1" Height="6" CornerRadius="3" Background="#1A1E2A" Margin="0,8,0,0" ClipToBounds="True">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="{2}*"/><ColumnDefinition Width="{3}*"/></Grid.ColumnDefinitions>
      <Border CornerRadius="3" Background="{4}"/>
    </Grid>
  </Border>
</Grid>
'@

$HealthTpl = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,14">
  <StackPanel Margin="0,0,90,0">
    <TextBlock FontSize="14" FontWeight="SemiBold" Foreground="#E8EAF2" Text="{0}" TextTrimming="CharacterEllipsis"/>
    <TextBlock FontSize="12" Foreground="#9AA0B8" Text="{1}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
  </StackPanel>
  <Border HorizontalAlignment="Right" VerticalAlignment="Top" CornerRadius="8" Padding="10,3" Background="#1C2030">
    <TextBlock FontSize="12" FontWeight="SemiBold" Foreground="{3}" Text="{2}"/>
  </Border>
</Grid>
'@

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
  try {
    Clear-Jobs
    # Toast (coda)
    if ($sync.Toast) { [void]$State.Q.Add($sync.Toast); $sync.Toast = $null }
    if ((Get-Date) -gt $State.ToastUntil) {
        if ($State.Q.Count) {
            $ui.ToastText.Text = $State.Q[0]; $State.Q.RemoveAt(0)
            $ui.Toast.Visibility = 'Visible'; $State.ToastUntil = (Get-Date).AddSeconds(4)
        } elseif ($ui.Toast.Visibility -eq 'Visible') { $ui.Toast.Visibility = 'Collapsed' }
    }

    # Conteggio aggiornamenti in background
    if ($null -ne $sync.UpdCount) {
        $n = $sync.UpdCount; $sync.UpdCount = $null
        if ($n -gt 0) {
            $ui.QUpdSub.Text = "$n aggiornamenti disponibili"
            if ($Tray.Visible) { $Tray.ShowBalloonTip(6000, 'MultiTool', "$n aggiornamenti disponibili. Clicca per vederli.", 'Info') }
        } elseif ($n -eq 0) { $ui.QUpdSub.Text = 'Tutto aggiornato' }
    }

    # Auto-aggiornamento
    if ($sync.UpdChecked) {
        $sync.UpdChecked = $false
        if ($sync.UpdError) { $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  controllo non riuscito: $($sync.UpdError)" }
        elseif ($sync.NewVersion) {
            $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  disponibile la $($sync.NewVersion)"
            $ui.SetUpdGo.Visibility = 'Visible'
            Toast "È disponibile MultiTool $($sync.NewVersion): vai in Impostazioni per aggiornare"
        } else { $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  è la più recente" }
    }

    # Banner riavvio
    $ui.RebootBar.Visibility = Vis ($sync.Reboot -or $State.Pending)

    # Info sistema
    if ($State.InfoPending -and $sync.Info) {
        $State.InfoPending = $false
        $i = $sync.Info
        $ui.HOs.Text = $i.OS; $ui.HBuild.Text = $i.Build
        $ui.HCpu.Text = $i.CPU; $ui.HCpu.ToolTip = $i.CPU; $ui.HCores.Text = $i.Cores
        $ui.HRam.Text = $i.Ram
        $ui.HRamA.Width = New-Object Windows.GridLength ([double]$i.RamPct), ([Windows.GridUnitType]::Star)
        $ui.HRamB.Width = New-Object Windows.GridLength ([double](100 - $i.RamPct)), ([Windows.GridUnitType]::Star)
        $ui.HDef.Text = $i.Def; $ui.HDefSig.Text = $i.DefSig
        $ui.HDefDot.Fill = if ($i.DefOk -eq $true) { '#34D399' } elseif ($i.DefOk -eq $false) { '#F87171' } else { '#FBBF24' }
        $ui.HSub.Text = "$env:COMPUTERNAME  ·  acceso da $($i.Uptime)"
        $State.Pending = [bool]$i.Pending
        $ui.HHealth.Children.Clear()
        foreach ($d in @($i.PD)) {
            $ok = $d.Health -eq 'Healthy'
            $st = switch ($d.Health) { 'Healthy' { 'Integro' } 'Warning' { 'Attenzione' } 'Unhealthy' { 'Guasto' } default { 'Sconosciuto' } }
            $det = @($(if ($d.Media -and $d.Media -ne 'Unspecified') { $d.Media }), $(if ($d.Size) { Format-Size $d.Size }),
                     $(if ($d.Temp) { "$($d.Temp) °C" }), $(if ($null -ne $d.Wear) { "usura $($d.Wear)%" }), $(if ($d.Hours) { "$($d.Hours) ore" })) | Where-Object { $_ }
            $col = if ($ok) { '#34D399' } elseif ($d.Health -eq 'Warning') { '#FBBF24' } else { '#F87171' }
            $ui.HHealth.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($HealthTpl -f [Security.SecurityElement]::Escape($d.Name), [Security.SecurityElement]::Escape($det -join '  ·  '), $st, $col)))) | Out-Null
        }
        if ($i.Bat) {
            $h = $i.Bat.Health
            $col = if ($null -eq $h) { '#9AA0B8' } elseif ($h -ge 80) { '#34D399' } elseif ($h -ge 60) { '#FBBF24' } else { '#F87171' }
            $txt = "Carica $($i.Bat.Charge)%" + $(if ($null -ne $h) { "  ·  capacità $h% rispetto al nuovo" } else { '' })
            $ui.HHealth.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($HealthTpl -f 'Batteria', $txt, $(if ($null -eq $h) { 'n.d.' } elseif ($h -ge 80) { 'Buona' } elseif ($h -ge 60) { 'Usurata' } else { 'Da sostituire' }), $col)))) | Out-Null
        }
        if (-not $ui.HHealth.Children.Count) { $ui.HHealth.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($HealthTpl -f 'Dati non disponibili', 'Il sistema non espone lo stato dei dischi', '—', '#9AA0B8')))) | Out-Null }
        $ui.HDisks.Children.Clear()
        foreach ($d in $i.Disks) {
            if (-not $d.Size) { continue }
            $pct = [int][Math]::Round(($d.Size - $d.Free) / $d.Size * 100)
            $name = [Security.SecurityElement]::Escape("$($d.Name)  $($d.Label)")
            $txt  = [Security.SecurityElement]::Escape("$(Format-Size $d.Free) liberi di $(Format-Size $d.Size)")
            $col  = if ($pct -ge 90) { '#F87171' } elseif ($pct -ge 75) { '#FBBF24' } else { '#8B6CFF' }
            $ui.HDisks.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($DiskTpl -f $name, $txt, $pct, (100 - $pct), $col)))) | Out-Null
        }
    }

    # Preparazione sezioni
    if ($sync.PrefetchStatus -and $sync.PrefetchStatus -ne $State.PrefShown) {
        $State.PrefShown = $sync.PrefetchStatus
        $ui.PrefInfo.Text = if ($sync.PrefetchStatus -eq 'done') { if ($Settings.Lang -eq 'en') { 'All sections ready' } else { 'Tutte le sezioni sono pronte' } }
                            else { $(if ($Settings.Lang -eq 'en') { 'Preparing sections… ' } else { 'Preparo le sezioni… ' }) + $sync.PrefetchStatus }
    }

    # Hardware
    if ($ui.ViewHw.Visibility -eq 'Visible') {
        if ($sync.HwToast) { Toast $sync.HwToast; $sync.HwToast = $null }
        if ($sync.LhmResult) {
            $ui.HwAdv.IsEnabled = $true
            if ($sync.LhmResult -eq 'ok') { $Settings.Lhm = $true; Save-Json 'settings.json' $Settings; Toast 'Sensori avanzati attivati'; Start-Sensors }
            else { $ui.HwSensMsg.Text = "Installazione non riuscita: $($sync.LhmResult)" }
            $sync.LhmResult = $null
        }
        if ($sync.Hw) {
            $State.HwCards = $sync.Hw; $sync.Hw = $null
            $ui.HwCol1.Children.Clear(); $ui.HwCol2.Children.Clear()
            $h1 = 0; $h2 = 0
            foreach ($c in $State.HwCards) {
                try {
                    $el = New-HwCard $c
                    if ($h1 -le $h2) { [void]$ui.HwCol1.Children.Add($el); $h1 += $c.Rows.Count + 3 } else { [void]$ui.HwCol2.Children.Add($el); $h2 += $c.Rows.Count + 3 }
                } catch { Write-ErrLog "Scheda hardware $($c.T): $($_.Exception.Message)" }
            }
            $ui.HwSub.Text = "$($State.HwCards.Count) componenti rilevati  ·  i valori si possono selezionare e copiare"
        } elseif (-not $State.HwCards) { $ui.HwSub.Text = $sync.HwStatus }
        if ($sync.SensMsg) { $ui.HwSensMsg.Text = $sync.SensMsg; $sync.SensMsg = $null }
        if ($sync.SensVer -ne $State.SensSeen -and $sync.Sens) {
            $State.SensSeen = $sync.SensVer
            $ui.HwSensSrc.Text = "fonte: $($sync.SensSrc)  ·  aggiornamento ogni 2 s"
            if ($Settings.Lhm -and $ui.HwSensMsg.Text -eq 'Lettura dei sensori…') { $ui.HwSensMsg.Text = '' }
            foreach ($se in $sync.Sens.ToArray()) {
                $t = $State.Tiles[$se.K]
                if (-not $t) {
                    $t = [Windows.Markup.XamlReader]::Parse((Apply-Theme $SensTpl))
                    $t.FindName('n').Text = $se.N; $t.FindName('g').Text = $se.G; $t.ToolTip = "$($se.G) - $($se.N)"
                    [void]$ui.HwSens.Children.Add($t); $State.Tiles[$se.K] = $t
                }
                $val = if ($se.U -in 'RPM', 'MHz') { '{0:N0}' -f $se.V } else { '{0:N1}' -f $se.V }
                $vb = $t.FindName('v'); $vb.Text = "$val $($se.U)"
                $vb.Foreground = if ($se.T -eq 'Temperature' -and $se.V -ge 85) { '#F87171' } elseif ($se.T -eq 'Temperature' -and $se.V -ge 70) { '#FBBF24' } elseif ($Settings.Theme -eq 'light') { '#1B1E27' } else { '#E8EAF2' }
            }
        }
    }

    if (-not $State.Mode) { return }
    $M = $Modes[$State.Mode]
    switch ($sync.Phase) {
        'scan' { $ui.LSub.Text = $sync.Status }
        'scanned' {
            Stop-Shimmer
            $sync.Phase = 'review'
            if ($sync.Error) {
                $ui.LSub.Text = "Errore: $($sync.Error)"
                Show-Empty @{ Glyph = (G 0xE7BA); Title = 'Qualcosa è andato storto'; Text = $sync.Error }
                $ui.LGo.Visibility = 'Collapsed'; $ui.LGo2.Visibility = 'Collapsed'; $ui.LCancel.Content = T 'CHIUDI'
                $sync.Phase = 'idle'; return
            }
            $bad = 0
            foreach ($r in $sync.Rows.ToArray()) {
                try {
                    $it = New-Object MtItem
                    foreach ($k in @($r.Keys)) { if ($null -ne $r[$k]) { $it.$k = $r[$k] } }
                    if (-not $it.Glyph) { $it.Glyph = $M.Glyph }
                    $Items.Add($it)
                } catch { $bad++ }
            }
            if ($bad) { Toast "$bad elementi non mostrati per un errore" }
            if ($State.FromCache) {
                $State.CacheNote = "  ·  " + $(if ($Settings.Lang -eq 'en') { 'data from' } else { 'dati delle' }) + " $($State.FromCache.ToString('HH:mm'))"
                $State.FromCache = $null
            } else {
                $State.CacheNote = ''
                if ($PrefetchOrder -contains $State.Mode -and -not $State.Vars) {
                    $sync.Cache[$State.Mode] = @{ Rows = $sync.Rows; Info = $sync.ScanInfo; Error = $null; Time = Get-Date }
                }
            }
            if ($Items.Count -eq 0) {
                Show-Empty $M.Empty
                $ui.LSub.Text = if ($sync.ScanInfo) { $sync.ScanInfo } else { $M.Empty.Title }
                if ($M.NoSelect -or @($M.NoSelectOps).Count) { return }
                $ui.LGo.Visibility = 'Collapsed'; $ui.LGo2.Visibility = 'Collapsed'
                if (-not $M.Search) { $ui.LCancel.Content = T 'CHIUDI' }
            } else {
                $ui.LSub.Text = $(if ($sync.ScanInfo) { $sync.ScanInfo } else { "$($Items.Count) elementi." }) + $State.CacheNote
                $ui.LAll.IsEnabled = $true; $ui.LNone.IsEnabled = $true
            }
        }
        'review' {
            $State.Tick++
            $free = @($M.NoSelectOps)
            if ($M.NoSelect) { $ui.LGo.IsEnabled = $true; $ui.LGo2.IsEnabled = $true; return }
            if ($M.Checks -eq $false -or ($Items.Count -gt 60 -and $State.Tick % 4)) { return }
            $s = @($Items | Where-Object { $_.Selected -and $_.Checkable }).Count
            $c = @($Items | Where-Object { $_.Checkable }).Count
            $ui.LSummary.Text = if ($c) { "$s / $c" + $(if ($Settings.Lang -eq 'en') { ' selected' } else { ' selezionati' }) } else { '' }
            $ui.LGo.IsEnabled = ($s -gt 0 -or $free -contains $M.GoOp); $ui.LGo2.IsEnabled = ($s -gt 0 -or $free -contains $M.Go2Op)
        }
        'run' {
            $ui.LFill.Width = $ui.LTrack.ActualWidth * ($sync.Done / [Math]::Max(1, $sync.Total))
            $ui.LSummary.Text = "$($sync.Done) di $($sync.Total) completati"
            if (-not $sync.Cancel) { $ui.LSub.Text = $sync.Status }
        }
        'done' {
            Invalidate-Cache
            if ($sync.ExtraRows) {
                foreach ($r in $sync.ExtraRows.ToArray()) {
                    $it = New-Object MtItem
                    foreach ($k in @($r.Keys)) { if ($null -ne $r[$k]) { $it.$k = $r[$k] } }
                    if (-not $it.Glyph) { $it.Glyph = $M.Glyph }
                    $Items.Add($it)
                }
                $sync.ExtraRows = $null
            }
            $ui.LFill.Width = $ui.LTrack.ActualWidth
            Set-Busy $false
            $sum = if (@($Items | Where-Object { $_.StatusKind -in 'ok', 'err' }).Count) { Get-Counts $Items } else { '' }
            if ($sync.Extra) { $sum = (@($sum, $sync.Extra) | Where-Object { $_ }) -join '  ·  ' }
            if ($sync.LastBackup) { $Settings.LastBackup = $sync.LastBackup; $sync.LastBackup = $null; Save-Json 'settings.json' $Settings; Update-BackupInfo }
            if ($M.AfterDone -eq 'rescan') { Start-Scan; Toast $sum; return }
            if ($M.AfterDone -eq 'review') {
                foreach ($it in $Items) { $it.Editable = $true; $it.Selected = $false }
                Reset-Footer; $ui.LCancel.Content = T 'CHIUDI'
                $ui.LSub.Text = 'Fatto. Puoi continuare a modificare.'
                Toast $sum
                $sync.Phase = 'review'; return
            }
            $sync.Phase = 'idle'
            $ui.LSub.Text = T 'Operazione completata.'
            $ui.LSummary.Text = $sum
            try { Export-Report $sum } catch { Write-ErrLog "Rapporto: $($_.Exception.Message)" }
            if (-not $win.IsVisible -and $Tray.Visible) { $Tray.ShowBalloonTip(6000, 'MultiTool', "$($M.Title): $sum", 'Info') }
            $ui.LGo.Visibility = 'Collapsed'; $ui.LGo2.Visibility = 'Collapsed'
            $ui.LCancel.Content = T 'CHIUDI'; $ui.LCancel.IsEnabled = $true
        }
    }
  } catch { Write-ErrLog "UI: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
})
$timer.Start()

# ============================================================
#  Finestra
# ============================================================
$ui.TitleBar.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ClickCount -eq 2) { $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } } else { $win.DragMove() } })
$ui.BtnMin.Add_Click({
    if ($Settings.Tray) { $win.Hide(); if (-not $State.TrayTip) { $State.TrayTip = $true; $Tray.ShowBalloonTip(4000, 'MultiTool', 'MultiTool resta attivo qui. Doppio clic per riaprirlo.', 'Info') } }
    else { $win.WindowState = 'Minimized' }
})
$win.Add_StateChanged({
    if ($win.WindowState -eq 'Maximized') {
        $wa = [Windows.SystemParameters]::WorkArea
        $win.MaxHeight = $wa.Height + 2; $win.MaxWidth = $wa.Width + 2
    } else { $win.MaxHeight = [double]::PositiveInfinity; $win.MaxWidth = [double]::PositiveInfinity }
})
if ($Settings.WinW -and $Settings.WinH) {
    $vs = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($Settings.WinL -ge $vs.Left -and $Settings.WinT -ge $vs.Top -and $Settings.WinL -lt $vs.Right - 100 -and $Settings.WinT -lt $vs.Bottom - 100) {
        $win.WindowStartupLocation = 'Manual'
        $win.Left = $Settings.WinL; $win.Top = $Settings.WinT; $win.Width = $Settings.WinW; $win.Height = $Settings.WinH
    }
    if ($Settings.WinMax) { $win.WindowState = 'Maximized' }
}
$ui.BtnMax.Add_Click({ $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$ui.BtnClose.Add_Click({ $win.Close() })
$win.Add_Closing({
    param($s, $e)
    $rb = $win.RestoreBounds
    if (-not $rb.IsEmpty) { $Settings.WinL = $rb.Left; $Settings.WinT = $rb.Top; $Settings.WinW = $rb.Width; $Settings.WinH = $rb.Height }
    $Settings.WinMax = ($win.WindowState -eq 'Maximized')
    try { Save-Json 'settings.json' $Settings } catch {}
    if ($sync.Phase -eq 'run') {
        $r = [Windows.MessageBox]::Show('Un''operazione è in corso: chiudendo ora potresti lasciare un''installazione a metà. Chiudere comunque?', 'MultiTool', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true }
    }
})
$win.Add_Closed({ try { $Tray.Visible = $false; $Tray.Dispose() } catch {}; [Environment]::Exit(0) })

$h = (Get-Date).Hour
$ui.HHello.Text = $(if ($Settings.Lang -eq 'en') { if ($h -lt 12) { 'Good morning' } elseif ($h -lt 18) { 'Good afternoon' } else { 'Good evening' } } elseif ($h -lt 12) { 'Buongiorno' } elseif ($h -lt 18) { 'Buon pomeriggio' } else { 'Buonasera' }) + ", $env:USERNAME"

# --- Controlli all'avvio ---
try { Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}
try {
    $hp = Join-Path $DataDir 'history.jsonl'
    if ((Test-Path $hp) -and (Get-Item $hp).Length -gt 1MB) { $keep = Get-Content $hp -Tail 2000 -Encoding UTF8; $keep | Set-Content $hp -Encoding UTF8 }
} catch {}
try { [void](Get-WingetPath) } catch {
    $sync.Toast = 'winget non trovato: installa "Programma di installazione app" dal Microsoft Store'
    Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1'
}
try {
    $session = (Get-CimInstance Win32_ComputerSystem).UserName
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($session -and $session -ne $me) {
        $sync.Toast = "Stai usando l'account amministratore ${me}: avvio automatico e file temporanei riguardano quell'account, non $session"
    }
} catch {}
try {
    $el = Join-Path $DataDir 'Logs\errori.log'
    if ((Test-Path $el) -and (Get-Item $el).Length -gt 1MB) { (Get-Content $el -Tail 2000) | Set-Content $el -Encoding UTF8 }
} catch {}
$ui.AppVer.Text = "MultiTool $AppVersion"
if ($Settings.BackupDest -and (-not $Settings.LastBackup -or ((Get-Date) - [datetime]$Settings.LastBackup).TotalDays -gt 7)) {
    Toast "L'ultimo backup ha più di 7 giorni: vai nella sezione Backup"
}
if ($Settings.SensLog) { Start-Sensors }
Start-CountCheck
Start-UpdCheck
Update-AutoInfo
Show-View 'ViewHome'
Start-Prefetch
Refresh-Info
[void]$win.ShowDialog()
