param([switch]$Auto, [switch]$Backup, [switch]$Uninstall, [switch]$Hidden, [switch]$Restart, [switch]$Pulizia, [switch]$Aggiorna, [switch]$Manutenzione, [switch]$Logon)
# ============================================================
#  MultiTool 2026 - Manutenzione PC
# ============================================================

$AppVersion = '2026.11.14.1'
$AppAuthor  = 'Erodyne'
$AppRepo    = 'https://github.com/Erodyne/MultiTool'
$TermsVersion = '1'
$DefaultUpdateUrl = 'https://raw.githubusercontent.com/Erodyne/MultiTool/main'
$ScriptPath = $PSCommandPath
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Root    = Split-Path -Parent $ScriptPath
$Installed = $Root -like "$env:ProgramFiles*"
$Base    = if ($Installed) { Join-Path $env:ProgramData 'MultiTool' } else { $Root }
$InstDir = Join-Path $Base 'Installers'
$ProfDir = Join-Path $Base 'Profili'
$DataDir = Join-Path $Base 'Dati'
foreach ($d in $InstDir, $ProfDir, $DataDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

# --- Riga di comando: -Aggiorna, -Manutenzione, -Pulizia ---
$CliMode = if ($Manutenzione) { 'full' } elseif ($Aggiorna) { 'upd' } elseif ($Pulizia) { 'clean' } else { '' }
# --- Elevazione (silenziosa) ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $Auto -and -not $Backup -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $extra = if ($Uninstall) { ' -Uninstall' } elseif ($CliMode) { ' -' + @{ full = 'Manutenzione'; upd = 'Aggiorna'; clean = 'Pulizia' }[$CliMode] } elseif ($Hidden) { ' -Hidden' } else { '' }
    Start-Process $PsExe -Verb RunAs -WindowStyle Hidden -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`"" + $extra)
    exit
}
if ($CliMode) { $Auto = [switch]$true }

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
         Sort-Object { $v = [version]'0.0'; [void][version]::TryParse(($_.Directory.Name -split '_')[1], [ref]$v); $v } -Descending | Select-Object -First 1
    if ($p) { $script:wg = $p.FullName; return $script:wg }
    $u = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $u) { $script:wg = $u; return $u }
    throw 'winget non trovato. Installa "Programma di installazione app" dal Microsoft Store.'
}

function Get-OemEncoding { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
function Invoke-Hidden([string]$File, [string]$Arguments, [int]$TimeoutSec = 0, [Text.Encoding]$Enc) {
    if (-not $Enc) { $Enc = if ([IO.Path]::GetFileName($File) -match '^(netsh|robocopy|vssadmin|powercfg|ipconfig|reg|icacls|pnputil)\.exe$') { Get-OemEncoding } else { [Text.Encoding]::UTF8 } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File; $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Enc; $psi.StandardErrorEncoding = $Enc
    $p = [Diagnostics.Process]::Start($psi)
    $e = $p.StandardError.ReadToEndAsync()
    $o = $p.StandardOutput.ReadToEndAsync()
    if ($TimeoutSec -gt 0 -and -not $p.WaitForExit($TimeoutSec * 1000)) {
        try { [void](Start-Process taskkill.exe "/PID $($p.Id) /T /F" -WindowStyle Hidden -Wait -PassThru) } catch {}
        throw "$([IO.Path]::GetFileName($File)) non ha risposto entro $TimeoutSec secondi"
    }
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $o.Result; Err = $e.Result }
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

function ConvertFrom-WingetTable([string]$Text, [switch]$FirstOnly) {
    $lines = $Text -split "`n" | ForEach-Object { ($_ -split "`r")[-1].TrimEnd() }
    if ($FirstOnly) {
        $stop = -1; $seen = $false
        for ($q = 0; $q -lt $lines.Count; $q++) { if ($lines[$q] -match '^-{20,}$') { if ($seen) { $stop = $q - 2; break }; $seen = $true } }
        if ($stop -gt 0) { $lines = $lines[0..$stop] }
    }
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

function Invoke-Winget([string]$Verb, [string]$Id, [string]$Source, $It, [switch]$NoScope, [switch]$Scoped) {
    if ($Verb -eq 'install' -and -not $NoScope -and -not $Scoped -and (Get-UserCtx).Other -and $Source -ne 'msstore') {
        $r0 = Invoke-Winget $Verb $Id $Source $It -NoScope -Scoped
        if ($r0.Code -ne -1978335216) { return $r0 }
    }
    $a = "$Verb --id `"$Id`" --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
    if ($Scoped) { $a += ' --scope machine' }
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
        '0x8A15010D' { return 'ok', 'Già installato' }
        '0x8A15010A' { $sync.Reboot = $true; return 'err', 'Serve prima un riavvio' }
        '0x8A15010B' { $sync.Reboot = $true; return 'ok', 'Riavvio richiesto' }
        { $_ -in '0x8A150101', '0x8A150111' } { return 'err', 'Programma aperto: chiudilo e riprova' }
        '0x8A150102' { return 'err', 'Un''altra installazione è in corso' }
        '0x8A150103' { return 'err', 'File in uso: chiudi il programma e riprova' }
        '0x8A150104' { return 'err', 'Manca un componente richiesto' }
        '0x8A150105' { return 'err', 'Disco pieno' }
        '0x8A150106' { return 'err', 'Memoria insufficiente' }
        '0x8A150107' { return 'err', 'Connessione a internet assente' }
        '0x8A15010C' { return 'skip', 'Annullato dall''utente' }
        '0x8A15010E' { return 'ok', 'Già presente una versione più recente' }
        '0x8A15010F' { return 'err', 'Bloccato dai criteri aziendali' }
        '0x8A150011' { return 'err', 'File scaricato non valido (hash diverso)' }
        '0x8A150010' { return 'err', 'Nessun installer adatto a questo PC' }
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
    elseif ($code -in 1602, 1223) { Set-It $it 'skip' 'Annullato dall''utente' }
    elseif ($code -eq 1618)       { Set-It $it 'err' 'Un''altra installazione è in corso' }
    elseif ($code -eq 1638)       { Set-It $it 'ok' 'Già installata un''altra versione' }
    elseif ($code -in 1619, 1620) { Set-It $it 'err' 'Pacchetto non leggibile o danneggiato' }
    elseif ($code -eq 1625)       { Set-It $it 'err' 'Bloccato dai criteri di sistema' }
    elseif ($code -eq 1603)       { Set-It $it 'err' 'Errore grave dell''installer (dettagli in Dati\Logs)' }
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
    if ($d.ContainsKey('RawName')) { $d.Remove('Name') }
    $d
}

function Format-Size([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) }
    elseif ($b -gt 0) { '{0:N0} KB' -f ($b / 1KB) } else { '0 KB' }
}

function Read-Json([string]$Name, $Default) {
    $p = Join-Path $DataDir $Name
    foreach ($f in $p, "$p.bak") {
        if (Test-Path $f) { try { $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop; if ($null -ne $j) { return $j } } catch {} }
    }
    $Default
}
function Save-Json([string]$Name, $Obj) {
    $p = Join-Path $DataDir $Name; $tmp = "$p.tmp"
    ConvertTo-Json -InputObject $Obj -Depth 5 | Set-Content $tmp -Encoding UTF8 -ErrorAction Stop
    if (Test-Path $p) { Copy-Item $p "$p.bak" -Force -ErrorAction SilentlyContinue }
    Move-Item $tmp $p -Force
}
function Read-Exclusions { @(@(Read-Json 'exclusions.json' @()) | Where-Object { $_ }) }
function Test-SkippedVer($c) { if (-not $script:skv) { $script:skv = Read-Json 'skipped.json' ([pscustomobject]@{}) }; $v = $script:skv.($c[1]); [bool]($v -and $v -eq $c[3]) }

function Get-Settings {
    $s = Read-Json 'settings.json' $null
    if (-not $s) { $s = [pscustomobject]@{} }
    $def = @{ Restore = $true; AutoEnabled = $false; AutoDay = 'Sunday'; AutoTime = '12:00'; Theme = 'dark'; Tray = $true; UpdateUrl = 'https://raw.githubusercontent.com/Erodyne/MultiTool/main'
              WinL = $null; WinT = $null; WinW = $null; WinH = $null; WinMax = $false; Lhm = $false
              ShopName = ''; ShopPhone = ''; ShopEmail = ''; ShopWeb = ''; ShopLogo = ''; WarrantyMonths = 24
              BackupDest = ''; LastBackup = ''; BackupAuto = $false; BackupTime = '13:00'; SensLog = $false; Lang = 'it'; Prefetch = $true; AutoSelfUpdate = $true; TermsAccepted = ''; AutoFull = $false; StartWithWindows = $false; Zoom = 1.0 }
    foreach ($k in $def.Keys) { if (-not ($s.PSObject.Properties.Name -contains $k)) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $def[$k] -Force } }
    $s
}

function Save-Settings {
    $disk = Read-Json 'settings.json' $null
    foreach ($k in 'LastBackup', 'LastAutoRun') {
        $dv = if ($disk) { [string]$disk.$k } else { '' }; $mv = [string]$Settings.$k
        if ($dv -and (-not $mv -or [datetime]$dv -gt [datetime]$mv)) { $Settings | Add-Member -NotePropertyName $k -NotePropertyValue $dv -Force }
    }
    Save-Json 'settings.json' $Settings
}

function Add-History([string]$Area, [string]$Name, [string]$Result, [string]$Kind) {
    $line = [pscustomobject]@{ Time = (Get-Date).ToString('s'); Area = $Area; Name = $Name; Result = $Result; Kind = $Kind } | ConvertTo-Json -Compress
    $mx = $null
    try {
        $mx = New-Object Threading.Mutex($false, 'Global\MultiTool2026.History')
        try { [void]$mx.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}
        for ($k = 0; $k -lt 3; $k++) { try { Add-Content -Path (Join-Path $DataDir 'history.jsonl') -Value $line -Encoding UTF8 -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 200 } }
    } catch {} finally { if ($mx) { try { $mx.ReleaseMutex() } catch {}; $mx.Dispose() } }
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

function Test-Online {
    if (-not [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) { return $false }
    foreach ($h in '1.1.1.1', '8.8.8.8') { try { if ((New-Object Net.NetworkInformation.Ping).Send($h, 1500).Status -eq 'Success') { return $true } } catch {} }
    try { [void][Net.Dns]::GetHostAddresses('github.com'); return $true } catch { return $false }
}

function Get-SecProducts([string]$Class) {
    try {
        @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName $Class -ErrorAction Stop |
          Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender|Windows Firewall' -and (([int64]$_.productState -band 0xF000) -eq 0x1000) })
    } catch { @() }
}
function Add-Leftovers($d) {
    $nm = (([string]$d.Name -replace '\s*\(.*?\)', '') -replace '\s+v?\d+([\.\-]\d+)*.*$', '').Trim()
    if ($nm.Length -lt 3 -or $nm -match '^(Microsoft|Windows|Intel|AMD|NVIDIA|Realtek)$') { return 0 }
    $U = Get-UserCtx
    $pub = ([string]$d.Pub -replace ',?\s+(Inc|Ltd|LLC|GmbH|S\.?r\.?l|Corporation|Corp|Co)\.?$', '').Trim()
    if ($pub -match 'Microsoft') { $pub = '' }
    $c = New-Object System.Collections.ArrayList
    $dirs = @([string]$d.Loc)
    foreach ($b in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $U.Roam, $U.Local) {
        if (-not $b) { continue }
        $dirs += Join-Path $b $nm
        if ($pub) { $dirs += Join-Path (Join-Path $b $pub) $nm }
    }
    foreach ($x in $dirs | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique) {
        $leaf = Split-Path $x -Leaf; $w1 = ($nm -split '[\s\-_\.]+')[0]
        if ($leaf.IndexOf($w1, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $nm.IndexOf($leaf, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($x.Length -gt 12 -and $x -notmatch '\\(Windows|Microsoft|Common Files|WindowsApps|Programs|Program Files( \(x86\))?|ProgramData|AppData\\(Local|Roaming))$' -and (Test-Path -LiteralPath $x)) { [void]$c.Add(@{ T = 'dir'; P = $x }) }
    }
    $regs = @("HKLM:\SOFTWARE\$nm", "HKLM:\SOFTWARE\WOW6432Node\$nm", "$($U.Hive)\Software\$nm")
    if ($pub) { $regs += "HKLM:\SOFTWARE\$pub\$nm", "HKLM:\SOFTWARE\WOW6432Node\$pub\$nm", "$($U.Hive)\Software\$pub\$nm" }
    foreach ($h in $regs) { if (Test-Path -LiteralPath $h) { [void]$c.Add(@{ T = 'reg'; P = $h }) } }
    if (-not $c.Count) { return 0 }
    $all = [System.Collections.ArrayList]@(@(Read-Json 'leftovers.json' @()) | Where-Object { $_ })
    foreach ($x in $c) { if (-not @($all | Where-Object { $_.P -eq $x.P }).Count) { [void]$all.Add([pscustomobject]@{ App = [string]$d.Name; T = $x.T; P = $x.P; D = (Get-Date).ToString('s') }) } }
    Save-Json 'leftovers.json' @($all)
    $c.Count
}
function Get-UserAppx([string]$Name = '*') {
    $u = Get-UserCtx
    if ($u.Other -and $u.Sid) { @(Get-AppxPackage -User $u.Sid -Name $Name -ErrorAction SilentlyContinue) } else { @(Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue) }
}
function Remove-UserAppx($p) {
    $u = Get-UserCtx
    if ($u.Other -and $u.Sid) { Remove-AppxPackage -Package $p.PackageFullName -User $u.Sid -ErrorAction Stop } else { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
}
function Get-UserCtx {
    if ($script:UCtx) { return $script:UCtx }
    $c = @{ Hive = 'HKCU:'; Local = $env:LOCALAPPDATA; Roam = $env:APPDATA; Temp = $env:TEMP; Prof = $env:USERPROFILE; Startup = [Environment]::GetFolderPath('Startup'); Other = $false; Name = $env:USERNAME }
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($ex in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
            $o = Invoke-CimMethod -InputObject $ex -MethodName GetOwnerSid -ErrorAction Stop
            if (-not $o.Sid -or $o.Sid -eq $me -or $ex.SessionId -ne (Get-Process -Id $PID).SessionId) { continue }
            if (-not (Test-Path "Registry::HKEY_USERS\$($o.Sid)")) { continue }
            $prof = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($o.Sid)" -ErrorAction Stop).ProfileImagePath
            $c.Hive = "Registry::HKEY_USERS\$($o.Sid)"; $c.Prof = $prof; $c.Local = "$prof\AppData\Local"; $c.Roam = "$prof\AppData\Roaming"
            $c.Temp = "$prof\AppData\Local\Temp"; $c.Startup = "$prof\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"; $c.Other = $true; $c.Name = Split-Path $prof -Leaf; $c.Sid = $o.Sid
            break
        }
    } catch {}
    $script:UCtx = $c
    $c
}
function Get-UserFolder([string]$Value, [string]$Fallback) {
    $u = Get-UserCtx
    if (-not $u.Other) { return $Fallback }
    try {
        $v = (Get-Item "$($u.Hive)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction Stop).GetValue($Value, $null, 'DoNotExpandEnvironmentNames')
        if ($v) { return ($v -replace '(?i)%USERPROFILE%', $u.Prof) }
    } catch {}
    Join-Path $u.Prof (Split-Path $Fallback -Leaf)
}
function Test-Abort { $null -ne $token -and $sync.Token -ne $token }
function Test-Metered {
    try {
        [void][Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
        $pr = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if (-not $pr) { return $false }
        return ([string]$pr.GetConnectionCost().NetworkCostType) -in 'Fixed', 'Variable'
    } catch { $false }
}
function Test-OnBattery { [bool]@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Where-Object { $_.BatteryStatus -eq 1 }).Count }
function Get-RealBootTime {
    $t = $null
    try { $t = (Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 27 } -MaxEvents 1 -ErrorAction Stop).TimeCreated } catch {}
    try { $lb = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime; if (-not $t -or $lb -gt $t) { $t = $lb } } catch {}
    if ($t) { $t } else { Get-Date }
}
function Get-RealUptimeDays { [int]((Get-Date) - (Get-RealBootTime)).TotalDays }
function Get-SfcResult([datetime]$Since) {
    $log = "$env:SystemRoot\Logs\CBS\CBS.log"
    $lines = @(); try { $lines = @(Get-Content $log -Tail 20000 -ErrorAction Stop | Where-Object { $_ -match '\[SR\]' }) } catch {}
    $recent = @($lines | Where-Object { $_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})' -and [datetime]$Matches[1] -ge $Since.AddMinutes(-1) })
    if (@($recent | Where-Object { $_ -match 'Cannot repair' }).Count) { return 'bad' }
    if (@($recent | Where-Object { $_ -match 'Repairing corrupted file|Repaired file' }).Count) { return 'fixed' }
    'ok'
}
function Get-JsLib([string]$Name, [string]$Cdn) {
    $f = Join-Path $Root "Strumenti\$Name"
    if (Test-Path $f) { "<script>$([IO.File]::ReadAllText($f))</script>" } else { "<script src=`"$Cdn`"></script>" }
}
function Tr([string]$t) { if ('MtTr' -as [type]) { [MtTr]::T($t) } else { $t } }
function Open-Shell([string]$Target) { Start-Process explorer.exe "`"$Target`"" }
function Protect-Csv($v) { $t = [string]$v; if ($t -match '^[=+\-@\t]') { "'" + $t } else { $t } }
function Write-TaskVbs([string]$Path, [string[]]$Lines) {
    Remove-Item $Path -Force -ErrorAction SilentlyContinue
    $Lines | Set-Content $Path -Encoding ASCII
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
        if ($e -lt 0) { return $c.Trim('"'), '' }
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
    try { Unblock-File -Path $Path -ErrorAction SilentlyContinue } catch {}
    $ua  = if (Test-Path $af) { (Get-Content $af -Raw).Trim() } else { $null }
    switch -Regex ($ext) {
        '^\.msi$' {
            $lg = Join-Path $DataDir ('Logs\msi-' + [IO.Path]::GetFileNameWithoutExtension($Path) + '.log'); New-Item -ItemType Directory (Split-Path $lg) -Force | Out-Null
            $a = "/i `"$Path`" /l*v `"$lg`""
            if ($ua) { $a += " $ua" } elseif ($Silent) { $a += ' /qn /norestart' }
            return Run-Wait 'msiexec.exe' $a $dir 'Normal'
        }
        '^\.(msix|msixbundle|appx|appxbundle)$' { Add-AppxPackage -Path $Path -ErrorAction Stop; return 0 }
        '^\.(bat|cmd)$' { return Run-Wait 'cmd.exe' "/c `"$Path`"" $dir $(if ($Silent) { 'Hidden' } else { 'Normal' }) }
        default { return Run-Wait $Path $(if ($Silent -and $ua) { $ua } else { '' }) $dir 'Normal' }
    }
}

function Get-WuError($e) {
    $h = '0x{0:X8}' -f $e.Exception.HResult
    switch ($h) {
        '0x80070422' { 'Il servizio Windows Update è disattivato' }
        { $_ -in '0x8024402C', '0x80072EE7', '0x80072EFD', '0x80072EFE', '0x8024401C' } { 'Windows Update non raggiunge i server: controlla la connessione' }
        '0x8024001E' { 'Operazione interrotta: Windows si sta spegnendo o riavviando' }
        '0x80240016' { 'Windows Update è già al lavoro: riprova tra qualche minuto' }
        '0x8024A10A' { 'Il servizio Windows Update si è fermato: riprova' }
        '0x80070005' { 'Accesso negato a Windows Update' }
        default { "Windows Update: errore $h" }
    }
}
function Search-WU($sr, [string]$Query) { try { $sr.Search($Query) } catch { throw (Get-WuError $_) } }
function Install-WU($items, [string]$Type) {
    $s = New-Object -ComObject Microsoft.Update.Session
    $s.ClientApplicationID = 'MultiTool'
    $sync.Status = 'Preparo gli aggiornamenti selezionati…'
    $sr = $s.CreateUpdateSearcher(); $sr.ServerSelection = 2; $sr.Online = $true
    $res = Search-WU $sr "IsInstalled=0 and IsHidden=0 and Type='$Type'"
    $map = @{}
    foreach ($u in $res.Updates) { $map[$u.Identity.UpdateID] = $u }
    Invoke-Each $items {
        param($it)
        $u = $map[$it.Key]
        if (-not $u) { Set-It $it 'err' 'Non più disponibile'; return }
        if ($u.InstallationBehavior.CanRequestUserInput) { Set-It $it 'skip' 'Richiede conferme: installalo da Impostazioni › Windows Update'; return }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        $c = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$c.Add($u)
        Set-It $it 'run' 'Download…'
        $d = $s.CreateUpdateDownloader(); $d.Updates = $c; $dr = $d.Download()
        if ($dr.ResultCode -notin 2, 3) { Set-It $it 'err' 'Download non riuscito'; return }
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
    $procs = @{ edge = 'msedge'; chrome = 'chrome'; firefox = 'firefox' }
    if ($procs.ContainsKey($t.Id) -and (Get-Process $procs[$t.Id] -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Freed = 0; After = (Get-DirSize $t.Paths $t.Age); Busy = $true; Why = 'Browser aperto: chiudilo e riprova' }
    }
    if ($t.Id -eq 'wu') {
        $busy = $false
        try { $busy = (New-Object -ComObject Microsoft.Update.Installer).IsBusy } catch {}
        if ($busy -or (Get-Process TiWorker -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Freed = 0; After = (Get-DirSize $t.Paths); Busy = $true; Why = 'Windows Update al lavoro: riprova più tardi' } }
    }
    $before = Get-TargetSize $t
    switch ($t.Id) {
        'oldrp' {
            $n = @(Get-SysShadows).Count
            for ($k = 1; $k -lt $n; $k++) { [void](Invoke-Hidden "$env:SystemRoot\System32\vssadmin.exe" "delete shadows /for=$env:SystemDrive /oldest /quiet" 120) }
        }
        'recycle' {
            $up = @(Get-UserRecyclePaths)
            if ($up.Count) { foreach ($p in $up) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } }
            else { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        }
        'wu' {
            Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
            Remove-Items $t.Paths
            Start-Service wuauserv, bits -ErrorAction SilentlyContinue
        }
        'do' { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { Remove-Items $t.Paths } }
        default { Remove-Items $t.Paths $t.Age }
    }
    $after = Get-TargetSize $t
    $why = if ($before -gt 10MB -and $after -gt $before * 0.8) { 'File in uso: liberato poco, riprova dopo un riavvio' } else { '' }
    [pscustomobject]@{ Freed = [Math]::Max(0, $before - $after); After = $after; Why = $why }
}
function Get-SysShadows {
    $vol = (Get-CimInstance Win32_Volume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction SilentlyContinue).DeviceID
    @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object { -not $vol -or $_.VolumeName -eq $vol })
}
function Get-TargetSize($t) {
    switch ($t.Id) {
        'recycle' { return Get-RecycleSize }
        'oldrp' {
            $sc = @(Get-SysShadows)
            if ($sc.Count -le 1) { return [double]0 }
            $u = (Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue | Measure-Object UsedSpace -Sum).Sum
            return [double]($u * ($sc.Count - 1) / $sc.Count)
        }
        default { return Get-DirSize $t.Paths $t.Age }
    }
}
function Get-UserRecyclePaths {
    $u = Get-UserCtx
    if (-not $u.Other -or -not $u.Sid) { return @() }
    @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.DeviceID)\`$Recycle.Bin\$($u.Sid)" } | Where-Object { Test-Path -LiteralPath $_ })
}
function Get-RecycleSize {
    $s = 0
    $up = @(Get-UserRecyclePaths)
    if ($up.Count) { foreach ($p in $up) { $s += (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | Measure-Object Length -Sum).Sum }; return [double]$s }
    try { foreach ($i in (New-Object -ComObject Shell.Application).Namespace(10).Items()) { $s += [double]$i.ExtendedProperty('Size') } } catch {}
    $s
}
function Get-CleanTargets {
    $U = Get-UserCtx
    @(
        @{ Id = 'tmpuser'; Name = 'File temporanei utente';      Def = $true;  Age = 24; Desc = "$($U.Temp)  ·  esclusi quelli delle ultime 24 ore"; Paths = @($U.Temp) }
        @{ Id = 'tmpwin';  Name = 'File temporanei di Windows';   Def = $true;  Age = 24; Desc = "$env:SystemRoot\Temp  ·  esclusi quelli delle ultime 24 ore"; Paths = @("$env:SystemRoot\Temp") }
        @{ Id = 'wu';      Name = 'Cache di Windows Update';      Def = $true;  Desc = 'Pacchetti di aggiornamento già installati'; Paths = @("$env:SystemRoot\SoftwareDistribution\Download") }
        @{ Id = 'do';      Name = 'Ottimizzazione recapito';      Def = $true;  Desc = 'Cache di condivisione aggiornamenti'; Paths = @("$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") }
        @{ Id = 'wer';     Name = 'Segnalazioni errori';          Def = $true;  Desc = 'Report di errore di Windows'; Paths = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue") }
        @{ Id = 'dump';    Name = 'Dump di arresto anomalo';      Def = $true;  Desc = 'Minidump e crash dump delle app'; Paths = @("$env:SystemRoot\Minidump", "$($U.Local)\CrashDumps") }
        @{ Id = 'edge';    Name = 'Cache di Microsoft Edge';     Def = $false; Desc = 'Chiudi Edge prima di pulire  ·  password e cronologia non vengono toccate'; Paths = @("$($U.Local)\Microsoft\Edge\User Data\*\Cache\Cache_Data", "$($U.Local)\Microsoft\Edge\User Data\*\Code Cache") }
        @{ Id = 'chrome';  Name = 'Cache di Google Chrome';      Def = $false; Desc = 'Chiudi Chrome prima di pulire  ·  password e cronologia non vengono toccate'; Paths = @("$($U.Local)\Google\Chrome\User Data\*\Cache\Cache_Data", "$($U.Local)\Google\Chrome\User Data\*\Code Cache") }
        @{ Id = 'firefox'; Name = 'Cache di Mozilla Firefox';    Def = $false; Desc = 'Chiudi Firefox prima di pulire  ·  password e cronologia non vengono toccate'; Paths = @("$($U.Local)\Mozilla\Firefox\Profiles\*\cache2") }
        @{ Id = 'shader';  Name = 'Cache degli shader (DirectX, NVIDIA, AMD)'; Def = $false; Desc = 'Verrà ricreata dai giochi al primo avvio'; Paths = @("$($U.Local)\D3DSCache", "$($U.Local)\NVIDIA\DXCache", "$($U.Local)\NVIDIA\GLCache", "$($U.Local)\AMD\DxCache", "$($U.Local)\AMD\DxcCache") }
        @{ Id = 'winlogs'; Name = 'Log di Windows vecchi';        Def = $true;  Age = 336; Desc = 'Log di installazione e diagnostica più vecchi di 14 giorni'; Paths = @("$env:SystemRoot\Logs\CBS", "$env:SystemRoot\Logs\DISM", "$env:SystemRoot\Logs\MoSetup") }
        @{ Id = 'thumb';   Name = 'Cache miniature';              Def = $false; Desc = 'Verrà ricreata automaticamente'; Paths = @("$($U.Local)\Microsoft\Windows\Explorer\thumbcache_*.db") }
        @{ Id = 'olddl';   Name = 'Download più vecchi di 90 giorni'; Def = $false; Age = 2160; Desc = "Elimina DEFINITIVAMENTE i file in $(Get-UserFolder '{374DE290-123F-4565-9164-39C4925E467B}' (Join-Path $U.Prof 'Downloads')) non modificati da 3 mesi"; Paths = @((Get-UserFolder '{374DE290-123F-4565-9164-39C4925E467B}' (Join-Path $U.Prof 'Downloads'))) }
        @{ Id = 'oldrp';   Name = 'Punti di ripristino vecchi';   Def = $false; Desc = 'Tiene solo il più recente'; Paths = @() }
        @{ Id = 'recycle'; Name = 'Cestino';                      Def = $false; Desc = 'Svuota definitivamente il cestino'; Paths = @() }
    )
}


function Get-PrivacyTweaks {
    $H = (Get-UserCtx).Hive
    $cdm = "$H\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    @(
        @{ Id = 'tel';  Name = 'Telemetria al minimo'; Desc = 'Invia a Microsoft solo i dati diagnostici indispensabili'
           Reg = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; V = 0 }) }
        @{ Id = 'ads';  Name = 'ID pubblicità disattivato'; Desc = 'Le app non usano il tuo ID per gli annunci personalizzati'
           Reg = @(@{ P = "$H\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; N = 'Enabled'; V = 0 }) }
        @{ Id = 'tail'; Name = 'Esperienze personalizzate disattivate'; Desc = 'Niente suggerimenti basati sui tuoi dati diagnostici'
           Reg = @(@{ P = "$H\Software\Microsoft\Windows\CurrentVersion\Privacy"; N = 'TailoredExperiencesWithDiagnosticDataEnabled'; V = 0 }) }
        @{ Id = 'sugg'; Name = 'Niente app promosse e suggerimenti in Start'; Desc = 'Blocca le app installate in automatico e i suggerimenti'
           Reg = @(@{ P = $cdm; N = 'SubscribedContent-338388Enabled'; V = 0 }, @{ P = $cdm; N = 'SubscribedContent-338389Enabled'; V = 0 },
                   @{ P = $cdm; N = 'SystemPaneSuggestionsEnabled'; V = 0 }, @{ P = $cdm; N = 'SilentInstalledAppsEnabled'; V = 0 }, @{ P = $cdm; N = 'SoftLandingEnabled'; V = 0 }) }
        @{ Id = 'lock'; Name = 'Niente pubblicità nella schermata di blocco'; Desc = 'Disattiva consigli e curiosità sulla schermata di blocco'
           Reg = @(@{ P = $cdm; N = 'RotatingLockScreenOverlayEnabled'; V = 0 }, @{ P = $cdm; N = 'SubscribedContent-338387Enabled'; V = 0 }) }
        @{ Id = 'act';  Name = 'Cronologia attività disattivata'; Desc = 'Windows non registra né invia le attività svolte'
           Reg = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'PublishUserActivities'; V = 0 },
                   @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'UploadUserActivities'; V = 0 }) }
        @{ Id = 'bing'; Name = 'Niente risultati Bing nella ricerca di Start'; Desc = 'La ricerca mostra solo file e app del PC (riavvio di Esplora risorse)'
           Reg = @(@{ P = "$H\Software\Policies\Microsoft\Windows\Explorer"; N = 'DisableSearchBoxSuggestions'; V = 1 }) }
        @{ Id = 'copilot'; Name = 'Copilot disattivato'; Desc = 'Nasconde e disattiva Copilot di Windows'
           Reg = @(@{ P = "$H\Software\Policies\Microsoft\Windows\WindowsCopilot"; N = 'TurnOffWindowsCopilot'; V = 1 },
                   @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; V = 1 }) }
        @{ Id = 'recall'; Name = 'Recall disattivato'; Desc = 'Windows non salva istantanee dello schermo (PC Copilot+)'
           Reg = @(@{ P = "$H\Software\Policies\Microsoft\Windows\WindowsAI"; N = 'DisableAIDataAnalysis'; V = 1 },
                   @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; V = 1 }) }
        @{ Id = 'expads'; Name = 'Niente pubblicità in Esplora file e Start'; Desc = 'Disattiva notifiche promozionali e consigli nel menu Start'
           Reg = @(@{ P = "$H\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; N = 'ShowSyncProviderNotifications'; V = 0 },
                   @{ P = "$H\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; N = 'Start_IrisRecommendations'; V = 0 }) }
        @{ Id = 'fb';   Name = 'Nessuna richiesta di feedback'; Desc = 'Windows non chiede più valutazioni e opinioni'
           Reg = @(@{ P = "$H\Software\Microsoft\Siuf\Rules"; N = 'NumberOfSIUFInPeriod'; V = 0 }) }
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
function Wait-Uninstallers([datetime]$Since, [int]$Minutes = 5) {
    $end = (Get-Date).AddMinutes($Minutes)
    Start-Sleep -Seconds 2
    while ((Get-Date) -lt $end -and -not $sync.Cancel) {
        $p = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $st = $null; try { $st = $_.StartTime } catch {}
            $st -and $st -ge $Since -and (($_.ProcessName -match '^(Au_|Un_A|Un_|unins\d*|_iu14D2N|uninstall|uninst|Uninstaller)') -or ($_.Path -and $_.Path -like "$env:TEMP*" -and $_.ProcessName -match '^(is-|_is|~|un|setup|.*\.tmp$)')) }
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

    $sync.HwStatus = 'Licenza di Windows…'
    $lic = $null; $oemk = ''
    try { $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { $oemk = (Get-CimInstance SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey } catch {}
    $ls = if ($lic) { switch ([int]$lic.LicenseStatus) { 1 { 'Attivato' } 0 { 'Non attivato' } 2 { 'Periodo di tolleranza' } 3 { 'Tolleranza scaduta' } 5 { 'Non attivato (notifiche)' } default { "Stato $($lic.LicenseStatus)" } } } else { 'Non rilevata' }
    $chan = if ($lic.ProductKeyChannel) { $lic.ProductKeyChannel } elseif ([string]$lic.Description -match 'OEM|RETAIL|VOLUME') { $Matches[0] } else { '' }
    Add-Card 'Licenza di Windows' 0xE8D7 @((Row 'Stato' $ls); (Row 'Edizione' $lic.Name); (Row 'Canale' $chan)
        (Row 'Codice parziale' $(if ($lic.PartialProductKey) { "xxxxx-xxxxx-xxxxx-xxxxx-$($lic.PartialProductKey)" })); (Row 'Codice OEM nel firmware' $oemk))

    $sync.HwStatus = 'Compatibilità Windows 11…'
    $cpuName = [string](Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $cpuOk = $null
    if ($cpuName -match 'Core\(TM\) Ultra|Core Ultra|Snapdragon') { $cpuOk = $true }
    elseif ($cpuName -match 'i[3579]-(\d{4,5})') { $nn = $Matches[1]; $gen = if ($nn.Length -eq 5 -or $nn.StartsWith('1')) { [int]$nn.Substring(0, 2) } else { [int]$nn.Substring(0, 1) }; $cpuOk = $gen -ge 8 }
    elseif ($cpuName -match 'Ryzen\s+(?:Threadripper\s+)?(?:\d\s+)?(?:PRO\s+)?(\d)\d{3}') { $g1 = [int]$Matches[1]; $cpuOk = if ($g1 -ge 3) { $true } elseif ($g1 -eq 1) { $false } else { $null } }
    elseif ($cpuName -match 'Core\(TM\)2|Pentium\(R\) (Dual|D|4)|Athlon|Phenom|FX-') { $cpuOk = $false }
    $tpm2 = $false
    try { $tt = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm -ErrorAction Stop; $tpm2 = ([string]$tt.SpecVersion -split ',')[0].Trim() -like '2.*' } catch {}
    $uefi = $sb -ne 'Legacy BIOS'
    $ramOk = [double]$cs.TotalPhysicalMemory -ge 3.8GB
    $diskOk = [double](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").Size -ge 60GB
    $fv = { param($ok) if ($null -eq $ok) { 'da verificare' } elseif ($ok) { 'ok' } else { 'NON compatibile' } }
    $allc = @($cpuOk, $tpm2, $uefi, $ramOk, $diskOk)
    $verd = if ($allc -contains $false) { 'Non compatibile' } elseif ($allc -contains $null) { 'Probabilmente compatibile' } else { 'Compatibile' }
    if ([int]$cv.CurrentBuildNumber -ge 22000) { $verd = "Windows 11 già installato  ·  $verd" }
    Add-Card 'Compatibilità Windows 11' 0xE7F8 @((Row 'Esito' $verd); (Row 'Processore' (& $fv $cpuOk)); (Row 'TPM 2.0' (& $fv $tpm2)); (Row 'UEFI (Secure Boot)' (& $fv $uefi))
        (Row 'RAM almeno 4 GB' (& $fv $ramOk)); (Row 'Disco almeno 64 GB' (& $fv $diskOk)))

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
    $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
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
            $r = Invoke-Hidden (Get-WingetPath) 'upgrade --include-unknown --accept-source-agreements --disable-interactivity' 300
            $list = @(ConvertFrom-WingetTable $r.Out -FirstOnly | Where-Object { $_.Cols.Count -ge 4 -and $excl -notcontains $_.Cols[1] -and $_.Cols[1] -notmatch '…$' -and -not (Test-SkippedVer $_.Cols) } |
                      Sort-Object { $_.Cols[1] -eq 'Microsoft.AppInstaller' })
            $ok = 0; $err = 0; $i = 0; $skp = 0
            foreach ($t in $list) {
                if ($sync.Cancel) { break }
                $i++; $c = $t.Cols
                $it.Sub = "($i/$($list.Count)) $($c[0])"
                $x = Invoke-Winget 'upgrade' $c[1] $(if ($c.Count -ge 5) { $c[4] } else { '' })
                $k, $txt = Get-WingetResult $x.Code 'Aggiornato'
                Add-History $area $c[0] $txt $k
                if ($k -eq 'ok') { $ok++ } elseif ($k -eq 'skip') { $skp++ } else { $err++ }
            }
            $it.Sub = if ($list.Count) { "$ok aggiornati, $err errori" + $(if ($skp) { ", $skp annullati" } else { '' }) } else { 'Nessun aggiornamento disponibile' }
            if ($err) { Set-It $it 'err' "$err errori" } else { Set-It $it 'ok' "$ok aggiornati" }
        }
        'wu' {
            $it.Sub = 'Cerco aggiornamenti di Windows…'
            $s = New-Object -ComObject Microsoft.Update.Session; $s.ClientApplicationID = 'MultiTool'
            $sr = $s.CreateUpdateSearcher(); $sr.ServerSelection = 2; $sr.Online = $true
            $c = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in (Search-WU $sr "IsInstalled=0 and IsHidden=0 and Type='Software'").Updates) {
                if ($u.BrowseOnly -or $u.InstallationBehavior.CanRequestUserInput -or @($u.Categories | Where-Object { $_.Name -eq 'Upgrades' }).Count) { continue }
                if (-not $u.EulaAccepted) { $u.AcceptEula() }
                [void]$c.Add($u)
            }
            if ($c.Count -eq 0) { $it.Sub = 'Windows è aggiornato'; Set-It $it 'ok' 'Nessuno'; return }
            $it.Sub = "Scarico $($c.Count) aggiornamenti…"
            $d = $s.CreateUpdateDownloader(); $d.Updates = $c; $dr = $d.Download()
            if ($dr.ResultCode -notin 2, 3) { $it.Sub = 'Download degli aggiornamenti non riuscito'; Set-It $it 'err' 'Download non riuscito'; return }
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
            $t0 = Get-Date
            $r2 = Invoke-Live "$env:SystemRoot\System32\sfc.exe" '/scannow' ([Text.Encoding]::Unicode) $cb
            $sfc = Get-SfcResult $t0
            $bad = $r1.Code -ne 0 -or $sfc -eq 'bad'
            $it.Sub = 'DISM ' + $(if ($r1.Code -eq 0) { 'ok' } else { 'errore' }) + '  ·  SFC ' + $(switch ($sfc) { 'fixed' { 'file riparati' } 'bad' { 'problemi non risolti' } default { 'nessun problema' } })
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
        $r = Invoke-Winget 'install' $id $(if ($id -match '^[0-9A-Z]{12}$') { 'msstore' } else { 'winget' })
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
    $sn = "$($bios.SerialNumber)".Trim()
    if (-not $sn -or $sn -match '(?i)^(to be filled|default|system serial|0+|none|n/?a|123456789|O\.E\.M\.|chassis serial)') {
        $bb = "$((Get-CimInstance Win32_BaseBoard).SerialNumber)".Trim()
        $sn = if ($bb -and $bb -notmatch '(?i)^(to be filled|default|0+|none|n/?a|base board serial)') { $bb } else { $env:COMPUTERNAME }
    }
    [pscustomobject]@{ Maker = "$($cs.Manufacturer)".Trim(); Model = "$($cs.Model)".Trim(); Serial = $sn
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
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', "$((Get-UserCtx).Hive)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
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
$(Get-JsLib 'qrcode.js' 'https://cdn.jsdelivr.net/npm/qrcode-generator@2.0.4/dist/qrcode.js')
<style>body{font-family:Segoe UI,sans-serif;margin:20px}.l{width:90mm;height:50mm;border:1px dashed #999;border-radius:3mm;padding:3mm;box-sizing:border-box;display:flex;gap:3mm}
.t{flex:1;font-size:8.5pt;line-height:1.35;overflow:hidden}.n{font-weight:700;font-size:10.5pt;border-bottom:2px solid #7c5cff;margin-bottom:1.5mm;padding-bottom:1mm}
#q{width:30mm;height:30mm;align-self:center}#q img,#q canvas{width:30mm!important;height:30mm!important}.f{font-size:7pt;color:#555}.np{margin-top:14px}@media print{.np{display:none}body{margin:0}.l{border:none}}</style></head>
<body><div class="l"><div class="t"><div class="n">$(& $E $(if ($S.ShopName) { $S.ShopName } else { 'Assistenza' }))</div>
<b>$(& $E "$($id.Maker) $($id.Model)")</b><br>S/N: $(& $E $id.Serial)<br>$(& $E $id.Cpu)<br>RAM $(& $E $id.Ram)<br>
Vendita: $(Get-Date -Format 'dd/MM/yyyy')  ·  Garanzia: $exp<br><span class="f">$(& $E ((@($S.ShopPhone, $S.ShopEmail) | Where-Object { $_ }) -join '  ·  '))</span></div><div id="q"></div></div>
<div class="np"><button onclick="window.print()">Stampa</button> <span class="f">$(Tr 'Formato 90 × 50 mm, da stampare su carta adesiva.')</span></div>
<script>qrcode.stringToBytes=qrcode.stringToBytesFuncs['UTF-8'];var q=qrcode(0,'M');q.addData($(ConvertTo-Json $qr) .replace(/<\/script/gi,''),'Byte');q.make();document.getElementById('q').innerHTML=q.createSvgTag({cellSize:4,margin:0,scalable:true});</script></body></html>
"@
    $dir = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ("Etichetta-{0}.html" -f ($id.Serial -replace '[^\w-]', ''))
    Set-Content -Path $file -Value $html -Encoding UTF8
    $file
}

# ---------- Backup ----------
function Get-BackupFolders {
    $U = Get-UserCtx
    $dl = try { (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch { Join-Path $env:USERPROFILE 'Downloads' }
    $sel = @((Get-Settings).BackupSel | Where-Object { $_ })
    $list = @(
        @{ Id = 'doc'; Name = 'Documenti'; Path = (Get-UserFolder 'Personal' ([Environment]::GetFolderPath('MyDocuments'))); Def = $true }
        @{ Id = 'desk'; Name = 'Desktop'; Path = (Get-UserFolder 'Desktop' ([Environment]::GetFolderPath('Desktop'))); Def = $true }
        @{ Id = 'pic'; Name = 'Immagini'; Path = (Get-UserFolder 'My Pictures' ([Environment]::GetFolderPath('MyPictures'))); Def = $true }
        @{ Id = 'vid'; Name = 'Video'; Path = (Get-UserFolder 'My Video' ([Environment]::GetFolderPath('MyVideos'))); Def = $false }
        @{ Id = 'mus'; Name = 'Musica'; Path = (Get-UserFolder 'My Music' ([Environment]::GetFolderPath('MyMusic'))); Def = $false }
        @{ Id = 'dl'; Name = 'Download'; Path = (Get-UserFolder '{374DE290-123F-4565-9164-39C4925E467B}' $dl); Def = $false }
        @{ Id = 'fav'; Name = 'Preferiti dei browser'; Path = $U.Local; Def = $true
           Multi = @(@{ N = 'Edge'; P = "$($U.Local)\Microsoft\Edge\User Data"; F = @('Bookmarks') }
                     @{ N = 'Chrome'; P = "$($U.Local)\Google\Chrome\User Data"; F = @('Bookmarks') }
                     @{ N = 'Firefox'; P = "$($U.Roam)\Mozilla\Firefox\Profiles"; F = @('places.sqlite', 'favicons.sqlite') }) }
    )
    if ($sel.Count) { foreach ($f in $list) { $f.Def = $sel -contains $f.Id } }
    $list
}
function Get-BackupEntrySize($f) {
    if (-not $f.Multi) { return Get-DirSize @($f.Path) }
    $s = 0
    foreach ($m in $f.Multi) { if (Test-Path $m.P) { $s += (Get-ChildItem $m.P -Recurse -File -Include $m.F -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
    [double]$s
}
function Invoke-BackupEntry($f, [string]$Root) {
    $dest = Join-Path $Root $f.Name
    if (-not $f.Multi) { return Invoke-FolderBackup $f.Path $dest }
    $code = 0; $n = 0
    foreach ($m in $f.Multi) {
        if (-not (Test-Path $m.P)) { continue }
        $r = Invoke-FolderBackup $m.P (Join-Path $dest $m.N) $m.F
        if ($r.Code -gt $code) { $code = $r.Code }; if ($r.Copied -gt 0) { $n += $r.Copied }
    }
    [pscustomobject]@{ Code = $code; Copied = $n; Suspect = $false }
}
function Invoke-FolderBackup([string]$Src, [string]$Dest, [string[]]$Files) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    if (-not $Files) {
        $have = @(Get-ChildItem $Dest -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 5000).Count
        if ($have -ge 200) {
            $dry = Invoke-Hidden "$env:SystemRoot\System32\robocopy.exe" "`"$Src`" `"$Dest`" /E /XO /FFT /DST /L /R:0 /W:0 /NP /NFL /NDL /XJ /XA:SO"
            $m = [regex]::Match($dry.Out, '(?m)^\s*(File|Files)\s*:\s*(\d+)\s+(\d+)')
            if ($m.Success) {
                $tot = [int]$m.Groups[2].Value; $chg = [int]$m.Groups[3].Value
                if ($tot -ge 200 -and $chg -ge 200 -and $chg / $tot -gt 0.5) {
                    Write-ErrLog "Backup sospeso: $chg file modificati su $tot in $Src"
                    return [pscustomobject]@{ Code = 16; Copied = -1; Suspect = $true }
                }
            }
        }
    }
    $a = if ($Files) { "`"$Src`" `"$Dest`" " + (($Files | ForEach-Object { "`"$_`"" }) -join ' ') + " /S /XO /FFT /DST /R:1 /W:1 /NP /NFL /NDL /XJ /XA:SO" }
         else { "`"$Src`" `"$Dest`" /E /XO /FFT /DST /R:1 /W:1 /MT:8 /NP /NFL /NDL /XJ /XA:SO" }
    $r = Invoke-Hidden "$env:SystemRoot\System32\robocopy.exe" $a
    $m = [regex]::Match($r.Out, '(?m)^\s*(File|Files)\s*:\s*(\d+)\s+(\d+)')
    [pscustomobject]@{ Code = $r.Code; Copied = $(if ($m.Success) { [int]$m.Groups[3].Value } else { -1 }) }
}

# ---------- Rete ----------
function Test-Ping([string]$HostName) {
    try { $p = New-Object Net.NetworkInformation.Ping; $t = @(1..3 | ForEach-Object { $r = $p.Send($HostName, 1500); if ($r.Status -eq 'Success') { $r.RoundtripTime } }); if ($t.Count) { [int]($t | Measure-Object -Average).Average } else { $null } } catch { $null }
}
function Measure-Download([int]$Seconds = 12) {
    $req = [Net.HttpWebRequest]::Create('https://speed.cloudflare.com/__down?bytes=200000000'); $req.Timeout = 15000; $req.ReadWriteTimeout = 10000
    $resp = $req.GetResponse(); $st = $resp.GetResponseStream(); $buf = New-Object byte[] 65536
    $sw = [Diagnostics.Stopwatch]::StartNew(); $tot = 0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $tot += $n }
    $sw.Stop(); $resp.Close()
    [math]::Round($tot * 8 / $sw.Elapsed.TotalSeconds / 1e6, 1)
}
function Measure-Upload([int]$MB = 15) {
    $data = New-Object byte[] ($MB * 1MB); (New-Object Random).NextBytes($data)
    $req = [Net.HttpWebRequest]::Create('https://speed.cloudflare.com/__up'); $req.Method = 'POST'; $req.ContentType = 'application/octet-stream'; $req.Timeout = 60000; $req.ReadWriteTimeout = 30000
    $req.ContentLength = $data.Length
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $st = $req.GetRequestStream(); $st.Write($data, 0, $data.Length); $st.Close()
    $req.GetResponse().Close(); $sw.Stop()
    [math]::Round($data.Length * 8 / $sw.Elapsed.TotalSeconds / 1e6, 1)
}

# ---------- Benchmark ----------
function ConvertTo-Num([string]$t) {
    $t = $t.Trim()
    $lc = $t.LastIndexOf(','); $ld = $t.LastIndexOf('.')
    if ($lc -gt $ld) { $t = $t.Replace('.', '').Replace(',', '.') } else { $t = $t.Replace(',', '') }
    [double]::Parse($t, [Globalization.CultureInfo]::InvariantCulture)
}
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

function New-JobSheet {
    $S = Get-Settings; $E = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $id = Get-PcIdentity
    $ops = @()
    $hp = Join-Path $DataDir 'history.jsonl'
    if (Test-Path $hp) {
        foreach ($l in Get-Content $hp -Tail 3000 -Encoding UTF8) {
            try { $h = $l | ConvertFrom-Json } catch { continue }
            if (([datetime]$h.Time).Date -eq (Get-Date).Date -and $h.Kind -eq 'ok') { $ops += "$($h.Area): $($h.Name)" }
        }
    }
    $ops = @($ops | Select-Object -Unique | Select-Object -Last 40)
    $num = Get-Date -Format 'yyyyMMdd-HHmm'
    $f = { param($label, $val, $h) "<div class='f'><label>$label</label><div class='e' contenteditable='true' style='min-height:$($h)px'>$val</div></div>" }
    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>Scheda intervento $num</title>
<style>body{font-family:Segoe UI,sans-serif;color:#1b1e27;margin:36px;max-width:900px}.shop{display:flex;gap:18px;align-items:center;border-bottom:3px solid #7c5cff;padding-bottom:16px}
.sn{font-size:22px;font-weight:600}.m{color:#5b6175;font-size:13px}h1{font-size:24px;margin:22px 0 2px}.g{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:16px}
.f label{display:block;font-size:12px;color:#5b6175;margin-bottom:4px}.e{border:1px solid #d6d9e3;border-radius:8px;padding:8px 10px;font-size:14px;white-space:pre-wrap}
.full{grid-column:1/3}.sig{display:flex;gap:40px;margin-top:40px}.sig div{flex:1;border-top:1px solid #999;padding-top:6px;font-size:12px;color:#5b6175}
.np{margin-top:20px}button{font-size:14px;padding:8px 16px}@media print{.np{display:none}body{margin:12mm}.e{border-color:#bbb}}</style></head><body>
$(Get-ShopHeader $S)
<h1>$(Tr 'Scheda intervento') n. $num</h1><div class="m">$(Get-Date -Format 'dd/MM/yyyy HH:mm')  ·  $(Tr 'i campi sono modificabili: fai clic e scrivi, poi stampa o salva come PDF')</div>
<div class="g">
$(& $f (Tr 'Cliente') '' 22)$(& $f (Tr 'Telefono / email') '' 22)
$(& $f (Tr 'Computer') (& $E "$($id.Maker) $($id.Model)  ·  S/N $($id.Serial)") 22)$(& $f (Tr 'Sistema') (& $E $id.Os) 22)
<div class="full">$(& $f (Tr 'Problema segnalato') '' 60)</div>
<div class="full">$(& $f (Tr 'Lavoro svolto') (($ops | ForEach-Object { '• ' + (& $E $_) }) -join "`n") 120)</div>
<div class="full">$(& $f (Tr 'Ricambi / materiale') '' 40)</div>
$(& $f (Tr 'Ore di lavoro') '' 22)$(& $f (Tr 'Importo') '' 22)
<div class="full">$(& $f (Tr 'Note') '' 40)</div>
</div>
<div class="sig"><div>$(Tr 'Firma del tecnico')</div><div>$(Tr 'Firma del cliente')</div></div>
<div class="np"><button onclick="window.print()">$(Tr 'Stampa o salva PDF')</button></div>
<p class="m" style="margin-top:20px">$(Tr 'Generato da MultiTool')</p></body></html>
"@
    $dir = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir "Intervento-$num.html"
    Set-Content -Path $file -Value $html -Encoding UTF8
    $file
}
function New-HealthReport {
    $S = Get-Settings; $E = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $id = Get-PcIdentity
    $ck = New-Object System.Collections.ArrayList
    $add = { param($a, $n, $v, $k) [void]$ck.Add(@{ A = $a; N = $n; V = $v; K = $k }) }
    foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $rc = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $k = if ("$($d.HealthStatus)" -ne 'Healthy') { 'err' } elseif ($rc.Wear -ge 80) { 'warn' } else { 'ok' }
        & $add (Tr 'Dischi') $d.FriendlyName ((@("stato $($d.HealthStatus)", $(if ($null -ne $rc.Wear) { "usura $($rc.Wear)%" }), $(if ($rc.Temperature) { "$($rc.Temperature) °C" })) | Where-Object { $_ }) -join '  ·  ') $k
    }
    foreach ($l in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue) {
        if (-not $l.Size) { continue }
        $pct = [int]($l.FreeSpace / $l.Size * 100)
        & $add (Tr 'Dischi') "Spazio libero $($l.DeviceID)" "$(Format-Size $l.FreeSpace) liberi ($pct%)" $(if ($pct -lt 8) { 'err' } elseif ($pct -lt 15) { 'warn' } else { 'ok' })
    }
    $tp = @(Get-SecProducts 'AntiVirusProduct')
    if ($tp.Count) { & $add (Tr 'Sicurezza') (Tr 'Antivirus') "$($tp[0].displayName) attivo" 'ok' }
    else { try { $mp = Get-MpComputerStatus -ErrorAction Stop; & $add (Tr 'Sicurezza') (Tr 'Antivirus') $(if ($mp.RealTimeProtectionEnabled) { "Microsoft Defender attivo  ·  firme di $($mp.AntivirusSignatureAge) giorni" } else { 'Microsoft Defender disattivato' }) $(if ($mp.RealTimeProtectionEnabled -and $mp.AntivirusSignatureAge -le 7) { 'ok' } elseif ($mp.RealTimeProtectionEnabled) { 'warn' } else { 'err' }) } catch { & $add (Tr 'Sicurezza') (Tr 'Antivirus') 'non rilevato' 'err' } }
    $fwOn = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object Enabled).Count -ge 3 -or @(Get-SecProducts 'FirewallProduct').Count
    & $add (Tr 'Sicurezza') (Tr 'Firewall') $(if ($fwOn) { 'attivo' } else { 'disattivato' }) $(if ($fwOn) { 'ok' } else { 'err' })
    $lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
    & $add (Tr 'Sicurezza') (Tr 'Controllo account utente') $(if ($lua -ne 0) { 'attivo' } else { 'disattivato' }) $(if ($lua -ne 0) { 'ok' } else { 'err' })
    try { $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop; & $add (Tr 'Sicurezza') (Tr 'Crittografia del disco') $(if ($bl.ProtectionStatus -eq 'On') { 'attiva' } else { 'non attiva' }) $(if ($bl.ProtectionStatus -eq 'On') { 'ok' } else { 'warn' }) } catch {}
    $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hf) { $dd = [int]((Get-Date) - $hf.InstalledOn).TotalDays; & $add (Tr 'Aggiornamenti') (Tr 'Ultimo aggiornamento di Windows') "$dd giorni fa ($($hf.HotFixID))" $(if ($dd -le 45) { 'ok' } elseif ($dd -le 90) { 'warn' } else { 'err' }) }
    $pr = Test-PendingReboot
    & $add (Tr 'Aggiornamenti') (Tr 'Riavvio in sospeso') $(if ($pr) { 'sì, riavvia per completare gli aggiornamenti' } else { 'no' }) $(if ($pr) { 'warn' } else { 'ok' })
    $up = Get-RealUptimeDays
    & $add (Tr 'Sistema') (Tr 'Acceso senza riavvio da') "$up giorni" $(if ($up -ge 7) { 'warn' } else { 'ok' })
    $nProb = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue).Count
    & $add (Tr 'Sistema') (Tr 'Dispositivi con problemi') "$nProb" $(if ($nProb) { 'warn' } else { 'ok' })
    try {
        $bsod = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop).Count
    } catch { $bsod = 0 }
    & $add (Tr 'Sistema') (Tr 'Schermate blu (30 giorni)') "$bsod" $(if ($bsod -ge 2) { 'err' } elseif ($bsod) { 'warn' } else { 'ok' })
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($b) {
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
        $des = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
        if ($full -and $des) { $bh = [int][math]::Min(100, $full / $des * 100); & $add (Tr 'Sistema') (Tr 'Salute della batteria') "$bh%" $(if ($bh -lt 50) { 'err' } elseif ($bh -lt 70) { 'warn' } else { 'ok' }) }
    }
    $tot = $ck.Count; $okn = @($ck | Where-Object { $_.K -eq 'ok' }).Count; $wn = @($ck | Where-Object { $_.K -eq 'warn' }).Count
    $score = if ($tot) { [int](($okn + $wn * 0.5) / $tot * 100) } else { 0 }
    $col = if ($score -ge 85) { '#10b981' } elseif ($score -ge 65) { '#f59e0b' } else { '#ef4444' }
    $lab = @{ ok = 'OK'; warn = (Tr 'Attenzione'); err = (Tr 'Problema') }
    $rowsH = foreach ($g in $ck | Group-Object { $_.A }) {
        "<h2>$(& $E (Tr $g.Name))</h2><table>" + (($g.Group | ForEach-Object { "<tr><th>$(& $E $_.N)</th><td>$(& $E (Tr $_.V))</td><td><span class='p $($_.K)'>$($lab[$_.K])</span></td></tr>" }) -join '') + '</table>'
    }
    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>Stato del PC - $(& $E $id.Serial)</title>
<style>body{font-family:Segoe UI,sans-serif;color:#1b1e27;margin:36px;max-width:900px}.shop{display:flex;gap:18px;align-items:center;border-bottom:3px solid #7c5cff;padding-bottom:16px}
.sn{font-size:22px;font-weight:600}.m{color:#5b6175;font-size:13px}h1{font-size:26px;margin:22px 0 4px}h2{font-size:16px;margin:24px 0 6px;color:#5b3fd9}
.sc{display:flex;align-items:center;gap:20px;margin:18px 0}.ring{width:96px;height:96px;border-radius:50%;border:10px solid $col;display:flex;align-items:center;justify-content:center;font-size:28px;font-weight:700;color:$col}
table{width:100%;border-collapse:collapse}th,td{padding:8px 10px;text-align:left;border-bottom:1px solid #eceef4;font-size:14px}th{width:260px;font-weight:600;color:#3b4054}
.p{padding:3px 10px;border-radius:8px;font-size:12px;font-weight:600}.ok{background:#d7f5ea;color:#047857}.warn{background:#fef3c7;color:#92400e}.err{background:#fde2e2;color:#b91c1c}
@media print{body{margin:12mm}}</style></head><body>
$(Get-ShopHeader $S)
<h1>$(Tr 'Stato del PC')</h1><div class="m">$(& $E "$($id.Maker) $($id.Model)")  ·  S/N $(& $E $id.Serial)  ·  $(& $E $id.Os)  ·  $(Get-Date -Format 'dd/MM/yyyy HH:mm')</div>
<div class="sc"><div class="ring">$score</div><div><b>$(Tr "Punteggio di salute: $score/100")</b><div class="m">$(Tr "$okn controlli superati, $wn da tenere d'occhio, $($tot - $okn - $wn) problemi")</div></div></div>
$($rowsH -join '')
<p class="m" style="margin-top:24px">$(Tr 'Generato da MultiTool')</p></body></html>
"@
    $dir = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ("Stato-PC-{0}-{1}.html" -f ($id.Serial -replace '[^\w-]', ''), (Get-Date -Format 'yyyyMMdd-HHmm'))
    Set-Content -Path $file -Value $html -Encoding UTF8
    $file
}

function New-SensorHistory {
    $f = Join-Path $DataDir 'sensori.csv'
    if (-not (Test-Path $f)) { return @{ Msg = 'Nessun dato: attiva "Registra temperature e ventole" in Impostazioni o tieni aperta la sezione Hardware' } }
    $since = (Get-Date).AddHours(-48)
    $data = Import-Csv $f -Delimiter ';' -Header T, G, N, K, V -Encoding UTF8 | Where-Object { [datetime]$_.T -ge $since }
    if (-not $data) { return @{ Msg = 'Nessun dato nelle ultime 48 ore' } }
    $groups = $data | Group-Object { "$($_.G) · $($_.N)" } | Sort-Object { ($_.Group | Select-Object -First 1).K }, Name | Select-Object -First 16
    $colors = '#7C5CFF', '#22D3EE', '#F87171', '#FBBF24', '#34D399', '#F472B6', '#60A5FA', '#A3E635'
    $i = 0
    $sets = foreach ($g in $groups) {
        $pts = ($g.Group | ForEach-Object { "{x:$([long](([datetime]$_.T).ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds),y:$(([double]($_.V -replace ',', '.')).ToString([Globalization.CultureInfo]::InvariantCulture))}" }) -join ','
        $axis = if (($g.Group | Select-Object -First 1).K -eq 'Fan') { 'y2' } else { 'y' }
        "{label:$(ConvertTo-Json $g.Name),data:[$pts],borderColor:'$($colors[$i % 8])',yAxisID:'$axis',pointRadius:0,borderWidth:1.5,tension:.2}"; $i++
    }
    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>Storico sensori - $env:COMPUTERNAME</title>
$(Get-JsLib 'chart.umd.min.js' 'https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js')
<style>body{font-family:Segoe UI,sans-serif;background:#0b0d12;color:#e8eaf2;margin:30px}h1{margin:0 0 4px}p{color:#9aa0b8;margin:0 0 20px}.c{background:#12151d;border:1px solid #1f2434;border-radius:16px;padding:20px;height:70vh}</style></head>
<body><h1>Storico sensori</h1><p>$env:COMPUTERNAME  ·  ultime 48 ore  ·  temperature in °C a sinistra, ventole in RPM a destra</p><div class="c"><canvas id="c"></canvas></div>
<script>Chart.defaults.color='#9aa0b8';Chart.defaults.borderColor='#1f2434';
new Chart(document.getElementById('c'),{type:'line',data:{datasets:[$($sets -join ',')]},options:{maintainAspectRatio:false,parsing:true,interaction:{mode:'nearest',intersect:false},
scales:{x:{type:'linear',ticks:{callback:function(v){var d=new Date(v);return ('0'+d.getDate()).slice(-2)+'/'+('0'+(d.getMonth()+1)).slice(-2)+' '+('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);}}},y:{title:{display:true,text:'°C'}},y2:{position:'right',title:{display:true,text:'RPM'},grid:{drawOnChartArea:false}}}}});</script></body></html>
"@
    $out = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory $out -Force | Out-Null
    $file = Join-Path $out 'Storico-sensori.html'
    Set-Content -Path $file -Value $html -Encoding UTF8
    @{ File = $file }
}

function Show-Toast([string]$Title, [string]$Text) {
    if ('MtTr' -as [type]) { $Title = [MtTr]::T($Title); $Text = [MtTr]::T($Text) }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $x = New-Object Windows.Data.Xml.Dom.XmlDocument
        $t = [Security.SecurityElement]::Escape($Title); $m = [Security.SecurityElement]::Escape($Text)
        $x.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$m</text></binding></visual></toast>")
        $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        try {
            $k = 'HKCU:\Software\Classes\AppUserModelId\Erodyne.MultiTool'
            if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
            Set-ItemProperty $k -Name DisplayName -Value 'MultiTool'
            $ico = Join-Path $Root 'MultiTool-512.png'; if (Test-Path $ico) { Set-ItemProperty $k -Name IconUri -Value $ico }
            Set-ItemProperty $k -Name ShowInSettings -Value 1 -Type DWord
            $app = 'Erodyne.MultiTool'
        } catch {}
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show((New-Object Windows.UI.Notifications.ToastNotification $x))
    } catch {}
}
'@

. ([scriptblock]::Create($Helpers))

# ============================================================
#  Traduzione (italiano -> inglese) e tipi condivisi
# ============================================================
$MtCs = @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
public static class MtTr {
    public static bool On = false;
    static readonly Dictionary<string, string> Ex = new Dictionary<string, string>(StringComparer.Ordinal);
    class Pat { public Regex R; public string En, Pre, Suf; }
    static readonly List<Pat> Pt = new List<Pat>();
    static readonly List<KeyValuePair<string, string>> Fr = new List<KeyValuePair<string, string>>();
    static readonly ConcurrentDictionary<string, string> Cache = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
    static readonly string[] Seps = { "\n", "   \u00B7   ", "  \u00B7  " };
    public static int Count { get { return Ex.Count + Pt.Count + Fr.Count; } }
    public static void Load(string table) {
        foreach (var raw in table.Split('\n')) {
            var line = raw.TrimEnd('\r');
            int i = line.IndexOf(" ⇒ ");
            if (i < 0) continue;
            string it = line.Substring(0, i).Replace("\\n", "\n"), en = line.Substring(i + 3).Replace("\\n", "\n");
            if (it.StartsWith("~")) { Fr.Add(new KeyValuePair<string, string>(it.Substring(1), en)); continue; }
            if (Regex.IsMatch(it, @"\{\d\}")) {
                var parts = Regex.Split(it, @"\{(\d)\}");
                var sb = new StringBuilder("^");
                for (int k = 0; k < parts.Length; k++) {
                    if (k % 2 == 0) sb.Append(Regex.Escape(parts[k])); else sb.Append("(?<g" + parts[k] + ">.*?)");
                }
                sb.Append("$");
                Pt.Add(new Pat { R = new Regex(sb.ToString(), RegexOptions.Singleline), En = en, Pre = parts[0], Suf = parts[parts.Length - 1] });
            } else { Ex[it] = en; }
        }
        Pt.Sort((a, b) => (b.Pre.Length + b.Suf.Length).CompareTo(a.Pre.Length + a.Suf.Length));
        Cache.Clear();
    }
    public static string T(string s) { return Tr(s, 0); }
    static string Tr(string s, int depth) {
        if (!On || string.IsNullOrEmpty(s) || depth > 3) return s;
        string r;
        if (Cache.TryGetValue(s, out r)) return r;
        r = Do(s, depth);
        if (Cache.Count < 20000) Cache[s] = r;
        return r;
    }
    static string Do(string s, int depth) {
        string r;
        if (Ex.TryGetValue(s, out r)) return r;
        string tr = s.Trim();
        if (tr.Length != s.Length && tr.Length > 0 && Ex.TryGetValue(tr, out r)) return s.Replace(tr, r);
        foreach (var p in Pt) {
            if (s.Length < p.Pre.Length + p.Suf.Length || !s.StartsWith(p.Pre, StringComparison.Ordinal) || !s.EndsWith(p.Suf, StringComparison.Ordinal)) continue;
            var m = p.R.Match(s);
            if (!m.Success) continue;
            string o = p.En;
            for (int g = 0; g < 10; g++) { var gr = m.Groups["g" + g]; if (gr.Success) o = o.Replace("{" + g + "}", Tr(gr.Value, depth + 1)); }
            return o;
        }
        foreach (var sep in Seps) {
            if (s.IndexOf(sep, StringComparison.Ordinal) < 0) continue;
            var parts = s.Split(new[] { sep }, StringSplitOptions.None);
            for (int k = 0; k < parts.Length; k++) parts[k] = Tr(parts[k], depth + 1);
            return string.Join(sep, parts);
        }
        string f = s;
        foreach (var x in Fr) f = f.Replace(x.Key, x.Value);
        return f;
    }
    public static MessageBoxResult Msg(string t) { return MessageBox.Show(T(t)); }
    public static MessageBoxResult Msg(string t, string c) { return MessageBox.Show(T(t), c); }
    public static MessageBoxResult Msg(string t, string c, MessageBoxButton b) { return MessageBox.Show(T(t), c, b); }
    public static MessageBoxResult Msg(string t, string c, MessageBoxButton b, MessageBoxImage i) { return MessageBox.Show(T(t), c, b, i); }
}

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
    public string Name       { get { return (string)G("Name", ""); }        set { S("Name", MtTr.T(value)); } }
    public string RawName    { get { return (string)G("Name", ""); }        set { S("Name", value); } }
    public string Sub        { get { return (string)G("Sub", ""); }         set { S("Sub", MtTr.T(value)); } }
    public string C1         { get { return (string)G("C1", ""); }          set { S("C1", MtTr.T(value)); } }
    public string C2         { get { return (string)G("C2", ""); }          set { S("C2", MtTr.T(value)); } }
    public string Tag        { get { return (string)G("Tag", ""); }         set { S("Tag", MtTr.T(value)); } }
    public string TagKind    { get { return (string)G("TagKind", "none"); } set { S("TagKind", value); } }
    public string Status     { get { return (string)G("Status", ""); }      set { S("Status", MtTr.T(value)); } }
    public string StatusKind { get { return (string)G("StatusKind", "none"); } set { S("StatusKind", value); } }
    public string Glyph      { get { return (string)G("Glyph", ""); }       set { S("Glyph", value); } }
    public string Key        { get { return (string)G("Key", ""); }         set { S("Key", value); } }
    public object Data       { get { return G("Data", null); }              set { S("Data", value); } }
}

'@
$TrTable = @'
 - riavvio consigliato ⇒  - restart recommended
 selezionati ⇒  selected
  ·  riavvio richiesto ⇒   ·  restart required
Accesso remoto al PC ⇒ Remote access to the PC
Account Administrator integrato ⇒ Built-in Administrator account
Aggiornamenti di sistema consigliati ⇒ Recommended system updates
Aggiornamenti di sistema consigliati (non i facoltativi) ⇒ Recommended system updates (not optional ones)
Aggiornamento automatico disattivato ⇒ Automatic update disabled
Aggiornamento automatico pianificato ⇒ Automatic update scheduled
Alcune modifiche saranno attive dopo aver riavviato o disconnesso l'utente ⇒ Some changes take effect after a restart or sign-out
AMBITO ⇒ SCOPE
Analisi del disco di sistema (CHKDSK) ⇒ System disk check (CHKDSK)
Analisi di winget e Microsoft Store… ⇒ Checking winget and Microsoft Store…
Analizzo i driver installati… ⇒ Analysing installed drivers…
Anno di produzione ⇒ Year of manufacture
Annullamento dopo l'elemento in corso… ⇒ Cancelling after the current item…
Annullamento… ⇒ Cancelling…
Annullato ⇒ Cancelled
APPLICA ⇒ APPLY
APPLICA attiva le opzioni selezionate, RIPRISTINA riporta i valori di prima (salvati in Dati\privacy-backup.json). ⇒ APPLY enables the selected options, RESTORE brings back the previous values (saved in Dati\privacy-backup.json).
Applica impostazioni privacy ⇒ Apply privacy settings
Applicate ⇒ Applied
applicato ⇒ applied
Applicato ⇒ Applied
Applico ⇒ Applying
Apri cartella dati ⇒ Open data folder
assente ⇒ absent
Attendi la fine dell'operazione in corso ⇒ Wait for the current operation to finish
Attendi la fine della raccolta delle informazioni ⇒ Wait until information gathering is finished
Attendo il disinstallatore… ⇒ Waiting for the uninstaller…
attenzione ⇒ warning
ATTIVA ⇒ ENABLE
attiva ⇒ on
Attiva nel firmware ⇒ Enabled in firmware
Attiva sensori avanzati ⇒ Enable advanced sensors
Attivato ⇒ Enabled
Attività pianificata ⇒ Scheduled task
Attività pianificata attiva ⇒ Scheduled task active
attivo ⇒ on
Automatico ⇒ Automatic
Avviato ⇒ Started
AVVIO ⇒ STARTUP
Avvio ⇒ Boot
Avvio automatico ⇒ Startup apps
Avvio la scansione del Microsoft Store… ⇒ Starting the Microsoft Store scan…
Backup automatico ⇒ Automatic backup
Backup automatico disattivato ⇒ Automatic backup disabled
Backup dei driver in corso… ⇒ Backing up drivers…
Backup driver completato in Dati\DriverBackup ⇒ Driver backup completed in Dati\DriverBackup
Batteria ⇒ Battery
BitLocker / crittografia dispositivo ⇒ BitLocker / device encryption
BitLocker non disponibile in questa edizione ⇒ BitLocker not available in this edition
Blocca i programmi che partono da chiavette e CD ⇒ Blocks programs that start from USB sticks and CDs
Blocca le app installate in automatico e i suggerimenti ⇒ Blocks automatically installed apps and suggestions
bloccata ⇒ blocked
Buon pomeriggio ⇒ Good afternoon
Buongiorno ⇒ Good morning
Buonasera ⇒ Good evening
Cache di condivisione aggiornamenti ⇒ Update sharing cache
Cache di Google Chrome ⇒ Google Chrome cache
Cache di Microsoft Edge ⇒ Microsoft Edge cache
Cache di Mozilla Firefox ⇒ Mozilla Firefox cache
Cache di Windows Update ⇒ Windows Update cache
Cache L2 / L3 ⇒ L2 / L3 cache
Cache miniature ⇒ Thumbnail cache
Calcolo delle cartelle… ⇒ Measuring folders…
Calcolo dello spazio recuperabile… ⇒ Measuring reclaimable space…
Capacità ⇒ Capacity
Capacità attuale ⇒ Current capacity
Capacità di progetto ⇒ Design capacity
Carica ⇒ Charge
Carico CPU ⇒ CPU load
Cerca dispositivi con problemi ⇒ Looks for devices with problems
Cerca tra migliaia di programmi e installali senza scaricare nulla a mano. ⇒ Search thousands of apps and install them without downloading anything by hand.
Cerco aggiornamenti di Windows… ⇒ Searching for Windows updates…
Cerco aggiornamenti di Windows… può richiedere qualche minuto ⇒ Searching for Windows updates… this can take a few minutes
Cerco aggiornamenti… ⇒ Searching for updates…
Cestino ⇒ Recycle Bin
Chi usa MultiTool su computer di terzi (ad esempio clienti) è responsabile di avere il loro consenso e di informarli delle operazioni eseguite. ⇒ Anyone using MultiTool on third-party computers (for example customers) is responsible for obtaining their consent and informing them of the operations performed.
Chiede conferma prima delle modifiche di sistema ⇒ Asks for confirmation before system changes
Chimica ⇒ Chemistry
Chip di sicurezza TPM ⇒ TPM security chip
Chiudi Chrome prima di pulire  ·  password e cronologia non vengono toccate ⇒ Close Chrome before cleaning  ·  passwords and history are not touched
Chiudi Edge prima di pulire  ·  password e cronologia non vengono toccate ⇒ Close Edge before cleaning  ·  passwords and history are not touched
Chiudi Firefox prima di pulire  ·  password e cronologia non vengono toccate ⇒ Close Firefox before cleaning  ·  passwords and history are not touched
Cicli di accensione ⇒ Power cycles
Cicli di carica ⇒ Charge cycles
Codice prodotto ⇒ Product code
Collega un cavo o una rete Wi-Fi. ⇒ Connect a cable or a Wi-Fi network.
Completata ⇒ Completed
Completato ⇒ Completed
Componenti di sistema… ⇒ System components…
Condizioni d'uso ed esclusione di garanzia ⇒ Terms of use and disclaimer of warranty
Configurazione di rete azzerata: riavvia il PC per completare ⇒ Network configuration reset: restart the PC to complete
Configurazione esportata: importala sugli altri PC da Impostazioni ⇒ Configuration exported: import it on other PCs from Settings
Configurazione importata. Riavviare MultiTool per applicarla? ⇒ Configuration imported. Restart MultiTool to apply it?
connessa ⇒ connected
Consigliato ⇒ Recommended
Contatti ⇒ People
Controlla aggiornamenti di MultiTool ⇒ Check for MultiTool updates
Controllo account utente (UAC) ⇒ User Account Control (UAC)
Controllo delle protezioni… ⇒ Checking protections…
Controllo dello stato dei driver… ⇒ Checking drivers…
Controllo driver ⇒ Driver check
Controllo file di sistema (SFC) ⇒ System file check (SFC)
Controllo i dispositivi con problemi… ⇒ Checking devices with problems…
Copio ⇒ Copying
Core / thread ⇒ Cores / threads
CORREGGI ⇒ FIX
Correggo ⇒ Fixing
Corretto ⇒ Fixed
Crea un file .json nella cartella Profili (vedi gli esempi inclusi). ⇒ Create a .json file in the Profiles folder (see the included examples).
Creata ⇒ Created
Creato ⇒ Created
Creo il punto di ripristino… ⇒ Creating the restore point…
Creo l'etichetta… ⇒ Creating the label…
Creo un punto di ripristino… ⇒ Creating a restore point…
Cronologia attività disattivata ⇒ Activity history disabled
Da stampare e attaccare al case ⇒ To print and stick on the case
Da verificare ⇒ To check
DATA ⇒ DATE
Data firmware ⇒ Firmware date
datato ⇒ outdated
Dati del negozio ⇒ Shop details
Dati non disponibili ⇒ Data not available
debole ⇒ weak
Defender non attivo: probabilmente c'è un antivirus di terze parti ⇒ Defender not active: a third-party antivirus is probably installed
Desktop remoto ⇒ Remote Desktop
Destinazione non disponibile ⇒ Destination not available
Destinazione non disponibile: collega il disco del backup ⇒ Destination not available: connect the backup drive
Diagnosi della connessione… ⇒ Diagnosing the connection…
Diagonale ⇒ Diagonal
DISATTIVA ⇒ DISABLE
disattiva ⇒ off
Disattiva consigli e curiosità sulla schermata di blocco ⇒ Turns off tips and fun facts on the lock screen
Disattiva nel firmware ⇒ Disabled in firmware
Disattivare i sensori avanzati? ⇒ Disable advanced sensors?
Disattivato ⇒ Disabled
disattivato ⇒ off
disattivo ⇒ off
Dischi… ⇒ Disks…
Disco ⇒ Disk
discreto ⇒ fair
Disinstallare {0} programmi? L'operazione non si può annullare. ⇒ Uninstall {0} apps? This cannot be undone.
Disinstallare MultiTool da questo PC? ⇒ Uninstall MultiTool from this PC?
Disinstallato ⇒ Uninstalled
Disinstallo ⇒ Uninstalling
DISM, SFC e CHKDSK · strumenti di Windows ⇒ DISM, SFC and CHKDSK · Windows tools
DISM + SFC  ·  lenta (20-30 minuti) ⇒ DISM + SFC  ·  slow (20-30 minutes)
DISM /Online /Cleanup-Image /RestoreHealth  ·  10-20 minuti ⇒ DISM /Online /Cleanup-Image /RestoreHealth  ·  10-20 minutes
Dispositivi con problemi ⇒ Devices with problems
Documenti ⇒ Documents
Download… ⇒ Downloading…
Dump di arresto anomalo ⇒ Crash dumps
Elenco esportato. Usa "Importa elenco" sull'altro PC. ⇒ List exported. Use "Import list" on the other PC.
Elenco vuoto ⇒ Empty list
Elimina il più vecchio ⇒ Delete the oldest
Eliminare definitivamente il contenuto di {0} categorie? ⇒ Permanently delete the contents of {0} categories?
Eliminare il punto di ripristino più vecchio? ⇒ Delete the oldest restore point?
Eliminare tutti i log? ⇒ Delete all logs?
Elimino il punto più vecchio… ⇒ Deleting the oldest point…
errore ⇒ error
Errore ⇒ Error
Errore 0x{0} ⇒ Error 0x{0}
Errore: ⇒ Error:
Errori di lettura ⇒ Read errors
Errori trovati ⇒ Errors found
Escludi selezionati ⇒ Exclude selected
Esclusioni ⇒ Exclusions
escluso ⇒ excluded
Escluso dagli aggiornamenti manuali e automatici ⇒ Excluded from manual and automatic updates
Esecuzione automatica da USB ⇒ AutoRun from USB
Esegui prima DISM e poi SFC. Puoi continuare a usare il PC nel frattempo. ⇒ Run DISM first, then SFC. You can keep using the PC meanwhile.
Eseguito ⇒ Done
Eseguo ⇒ Running
ESITO ⇒ RESULT
Esperienze personalizzate disattivate ⇒ Tailored experiences disabled
Esporta configurazione di MultiTool ⇒ Export MultiTool configuration
Esporta inventario hardware ⇒ Export hardware inventory
Esportazione in corso… ⇒ Exporting…
Esportazione non riuscita ⇒ Export failed
Etichetta con codice QR ⇒ QR code label
Etichetta QR del PC ⇒ PC QR label
Facoltativo ⇒ Optional
Famiglia ⇒ Family
Fatto. Puoi continuare a modificare. ⇒ Done. You can keep editing.
File non trovato ⇒ File not found
file riparati ⇒ files repaired
File temporanei di Windows ⇒ Windows temporary files
File temporanei utente ⇒ User temporary files
Film e TV ⇒ Movies & TV
Firewall… ⇒ Firewall…
Firme antivirus ⇒ Antivirus signatures
Frequenza base ⇒ Base clock
Gestione attività ⇒ Task Manager
Gestione dispositivi ⇒ Device Manager
Giochi e app promozionali, reinstallabili dallo Store ⇒ Games and promotional apps, reinstallable from the Store
Giochi King (Candy Crush…) ⇒ King games (Candy Crush…)
Gruppi di programmi da installare in un colpo solo. ⇒ Groups of apps to install in one go.
guidata ⇒ guided
Hardware, programmi installati, garanzia e firme (HTML stampabile) ⇒ Hardware, installed apps, warranty and signatures (printable HTML)
Hub di Feedback ⇒ Feedback Hub
ID pubblicità disattivato ⇒ Advertising ID disabled
ID troncato ⇒ Truncated ID
Il file non contiene pacchetti winget validi. ⇒ The file contains no valid winget packages.
Il programma modifica impostazioni di Windows e del registro di sistema, installa, aggiorna e rimuove programmi, app e driver, elimina file temporanei e può riavviare il computer. Prima di usarlo esegui un backup dei tuoi dati. Le operazioni vengono avviate solo dopo la tua conferma e, se l'opzione è attiva, dopo la creazione di un punto di ripristino. ⇒ The program changes Windows and registry settings, installs, updates and removes apps and drivers, deletes temporary files and may restart the computer. Back up your data before using it. Operations start only after your confirmation and, if the option is enabled, after a restore point has been created.
Il sistema non espone lo stato dei dischi ⇒ The system does not expose disk health
Il tema verrà applicato al prossimo avvio ⇒ The theme will be applied at the next start
Immagini ⇒ Pictures
Importa configurazione di MultiTool ⇒ Import MultiTool configuration
Impostazioni Windows Update ⇒ Windows Update settings
In "Aggiorna programmi" seleziona un programma e premi "Escludi selezionati". ⇒ In "Update apps" select an app and press "Exclude selected".
In coda ⇒ Queued
In corso… ⇒ In progress…
Indirizzo visto da internet ⇒ Address seen from the internet
Informazioni e note legali ⇒ About and legal notes
installata ⇒ installed
Installato ⇒ Installed
Installato il ⇒ Installed on
Installazione in corso… ⇒ Installing…
Installazione… ⇒ Installing…
Installo ⇒ Installing
Installo il driver PawnIO… ⇒ Installing the PawnIO driver…
Installo il profilo ⇒ Installing profile
Installo LibreHardwareMonitor… ⇒ Installing LibreHardwareMonitor…
Interrogo winget, attendi qualche secondo… ⇒ Querying winget, wait a few seconds…
Invia a Microsoft solo i dati diagnostici indispensabili ⇒ Sends only essential diagnostic data to Microsoft
Ioni di litio ⇒ Lithium-ion
IP pubblico ⇒ Public IP
irraggiungibile ⇒ unreachable
L'attività automatica aggiornerà solo i programmi ⇒ The automatic task will update apps only
L'attività automatica eseguirà la manutenzione completa ⇒ The automatic task will run the full maintenance
L'ultimo backup ha più di 7 giorni: vai nella sezione Backup ⇒ The last backup is more than 7 days old: go to the Backup section
L'uso del programma è gratuito, anche in ambito professionale. Non è consentito vendere, ridistribuire versioni modificate o presentare il programma come proprio senza l'autorizzazione scritta dell'autore. ⇒ The program is free to use, including professionally. Selling it, redistributing modified versions or presenting it as your own is not allowed without the author's written permission.
La connessione verrà interrotta per qualche secondo e servirà un riavvio. Procedere? ⇒ The connection will drop for a few seconds and a restart will be needed. Proceed?
La destinazione è sullo stesso disco di Windows: se il disco si guasta perdi anche il backup. Usarla comunque? ⇒ The destination is on the Windows disk: if the disk fails you lose the backup too. Use it anyway?
La ricerca mostra solo file e app del PC (riavvio di Esplora risorse) ⇒ Search shows only files and apps on the PC (restarts Explorer)
Le app non usano il tuo ID per gli annunci personalizzati ⇒ Apps don't use your ID for personalised ads
Leggo le schede di rete… ⇒ Reading network adapters…
lento ⇒ slow
Lettura dei programmi all'avvio… ⇒ Reading startup apps…
Lettura dei programmi installati… ⇒ Reading installed apps…
Lettura dei punti di ripristino… ⇒ Reading restore points…
Lettura dei sensori… ⇒ Reading sensors…
Lettura del file… ⇒ Reading file…
Lettura della cartella Installers… ⇒ Reading the Installers folder…
Lettura della cronologia… ⇒ Reading history…
Lettura delle impostazioni… ⇒ Reading settings…
Licenza ⇒ License
Log completo salvato in Dati\Logs ⇒ Full log saved in Dati\Logs
Mai eseguito ⇒ Never run
Manutenzione completa ⇒ Full maintenance
Manutenzione: ⇒ Maintenance:
Memoria RAM ⇒ RAM
Memoria RAM · velocità ⇒ RAM · speed
Memoria usata ⇒ Memory used
Memoria video ⇒ Video memory
Memoria… ⇒ Memory…
Microsoft 365 (Office) app promozionale ⇒ Microsoft 365 (Office) promotional app
Minidump e crash dump delle app ⇒ Minidumps and app crash dumps
Misurato ⇒ Measured
Misuro ⇒ Measuring
Misuro il download (circa 12 secondi)… ⇒ Measuring download (about 12 seconds)…
Misuro l'upload… ⇒ Measuring upload…
Misuro le risposte… ⇒ Measuring response times…
MODALITÀ ⇒ MODE
Modello ⇒ Model
Modulo ⇒ Module
molto spazio ⇒ lots of space
Monitor… ⇒ Monitors…
Musica ⇒ Music
MultiTool - Aggiornamento automatico ⇒ MultiTool - Automatic update
MultiTool - Attenzione ⇒ MultiTool - Warning
MultiTool - Manutenzione completata ⇒ MultiTool - Maintenance completed
MultiTool è fornito «così com'è», senza garanzie di alcun tipo, esplicite o implicite, comprese quelle di funzionamento senza errori, di idoneità a uno scopo particolare e di compatibilità con uno specifico computer. ⇒ MultiTool is provided "as is", without warranties of any kind, express or implied, including error-free operation, fitness for a particular purpose and compatibility with a specific computer.
MultiTool è stato disinstallato. ⇒ MultiTool has been uninstalled.
MultiTool non include software di terze parti. Gli strumenti facoltativi (ad esempio LibreHardwareMonitor, licenza MPL-2.0, e il driver PawnIO) vengono scaricati dai canali ufficiali tramite winget solo dopo la tua conferma e sono regolati dalle rispettive licenze. I programmi installati con winget o dalle cartelle Installers e Profili sono soggetti alle licenze dei loro autori, che accetti al momento dell'installazione. ⇒ MultiTool does not include third-party software. Optional tools (for example LibreHardwareMonitor, MPL-2.0 license, and the PawnIO driver) are downloaded from official channels via winget only after your confirmation and are governed by their own licenses. Apps installed with winget or from the Installers and Profiles folders are subject to their authors' licenses, which you accept at installation.
MultiTool non raccoglie, non registra e non invia all'autore alcun dato personale o informazione sul computer. Inventario hardware, cronologia, log, rapporti e impostazioni restano esclusivamente sul PC, nella cartella Dati. ⇒ MultiTool does not collect, record or send the author any personal data or information about the computer. Hardware inventory, history, logs, reports and settings stay only on the PC, in the Dati folder.
MultiTool resta attivo qui. Doppio clic per riaprirlo. ⇒ MultiTool keeps running here. Double-click to reopen it.
Necessario per BitLocker e Windows 11 ⇒ Required for BitLocker and Windows 11
Nei limiti massimi consentiti dalla legge, l'autore non è responsabile di danni diretti o indiretti, perdita di dati, malfunzionamenti, interruzioni di attività o mancati guadagni derivanti dall'uso o dall'impossibilità di usare il programma. Restano salvi i casi di dolo o colpa grave (art. 1229 c.c.) e i diritti che la legge riconosce ai consumatori e che non possono essere esclusi. ⇒ To the maximum extent permitted by law, the author is not liable for direct or indirect damage, data loss, malfunctions, business interruption or lost profits arising from the use of or inability to use the program. Cases of wilful misconduct or gross negligence (art. 1229 of the Italian Civil Code) and consumer rights that cannot be excluded by law remain unaffected.
Nella cartella non ci sono driver (.inf) ⇒ There are no drivers (.inf) in the folder
Nessun aggiornamento di sistema in attesa. ⇒ No pending system updates.
Nessun aggiornamento disponibile ⇒ No updates available
Nessun dato nelle ultime 48 ore ⇒ No data in the last 48 hours
Nessun dato: attiva "Registra temperature e ventole" in Impostazioni o tieni aperta la sezione Hardware ⇒ No data: enable "Log temperatures and fans" in Settings or keep the Hardware section open
Nessun dispositivo con problemi ⇒ No devices with problems
Nessun driver da segnalare ⇒ No driver issues
Nessun errore ⇒ No errors
Nessun installer trovato ⇒ No installers found
Nessun log presente. ⇒ No logs yet.
Nessun problema ⇒ No problems
nessun problema ⇒ no problems
Nessun problema e nessun driver di terze parti rilevato. ⇒ No problems and no third-party drivers found.
Nessun profilo ⇒ No profiles
Nessun programma ⇒ No apps
Nessun programma all'avvio ⇒ No startup apps
Nessun punto di ripristino ⇒ No restore points
Nessun risultato ⇒ No results
Nessuna cartella ⇒ No folders
Nessuna connessione a internet ⇒ No internet connection
Nessuna esclusione ⇒ No exclusions
Nessuna operazione registrata ⇒ No recorded operations
Nessuna rete connessa ⇒ No network connected
Nessuna richiesta di feedback ⇒ No feedback requests
nessuna risposta ⇒ no response
Nessuno ⇒ None
nessuno ⇒ none
Niente app promosse e suggerimenti in Start ⇒ No promoted apps and suggestions in Start
Niente da pulire ⇒ Nothing to clean
Niente pubblicità nella schermata di blocco ⇒ No ads on the lock screen
Niente risultati Bing nella ricerca di Start ⇒ No Bing results in Start search
Niente suggerimenti basati sui tuoi dati diagnostici ⇒ No suggestions based on your diagnostic data
Nome PC ⇒ PC name
non applicato ⇒ not applied
non attiva ⇒ not active
non connesso ⇒ not connected
non firmato ⇒ unsigned
non funziona ⇒ not working
Non ho trovato programmi disinstallabili. ⇒ No uninstallable apps found.
Non pianificato ⇒ Not scheduled
Non più disponibile ⇒ No longer available
Non risolti ⇒ Not resolved
non scelta (vai in Backup) ⇒ not chosen (go to Backup)
non supportato ⇒ not supported
Non trovato ⇒ Not found
Notizie (Microsoft News) ⇒ News (Microsoft News)
Numero di serie ⇒ Serial number
Obsoleto e vulnerabile ⇒ Obsolete and vulnerable
Operazione completata ⇒ Operation completed
Operazione completata. ⇒ Done.
Operazione in corso… ⇒ Operation in progress…
Orario non valido: usa il formato HH:MM ⇒ Invalid time: use the HH:MM format
Ore di accensione ⇒ Power-on hours
Ottimizzazione recapito ⇒ Delivery Optimization
ottimo ⇒ excellent
Pacchetti di aggiornamento già installati ⇒ Already installed update packages
Per funzionare il programma si collega a servizi esterni, che hanno proprie informative: GitHub (aggiornamenti di MultiTool), Microsoft (winget, Microsoft Store, Windows Update, Catalogo Microsoft Update), Cloudflare e ipify (test di velocità e IP pubblico, solo quando li avvii), cdnjs e jsDelivr (grafici e codici QR nei rapporti HTML). ⇒ To work, the program connects to external services with their own privacy policies: GitHub (MultiTool updates), Microsoft (winget, Microsoft Store, Windows Update, Microsoft Update Catalog), Cloudflare and ipify (speed test and public IP, only when you start them), cdnjs and jsDelivr (charts and QR codes in HTML reports).
Per leggere temperature dei core, ventole e consumi serve un componente che accede ai sensori della scheda madre. ⇒ Reading core temperatures, fans and power draw requires a component that accesses the motherboard sensors.
permessa ⇒ allowed
PRECEDENTE ⇒ PREVIOUS
Premi CREA PUNTO: verrà attivata anche la protezione sistema. ⇒ Press CREATE POINT: system protection will be enabled too.
Prepara il PC per il cliente: scegli i passaggi e premi AVVIA. Dati del negozio in Impostazioni. ⇒ Prepare the PC for the customer: choose the steps and press START. Shop details are in Settings.
Preparazione consegna ⇒ Delivery prep
Preparo gli aggiornamenti selezionati… ⇒ Preparing the selected updates…
Preparo le sezioni… ⇒ Preparing sections…
presente ⇒ present
problema ⇒ problem
problemi non risolti ⇒ unresolved problems
Processore ⇒ Processor
Processore · compressione ⇒ Processor · compression
Processore · crittografia AES ⇒ Processor · AES encryption
Processore… ⇒ Processor…
Produttore ⇒ Manufacturer
Produttore (codice) ⇒ Manufacturer (code)
Programmi aggiornati: ⇒ Apps updated:
Programmi che non verranno mai aggiornati. ⇒ Apps that will never be updated.
Programmi e funzionalità ⇒ Programs and Features
pronto ⇒ ready
Protezione in tempo reale ⇒ Real-time protection
Protezione sistema disattivata o nessun punto disponibile: premi CREA PUNTO per attivarla. ⇒ System protection off or no points available: press CREATE POINT to enable it.
Protocollo SMBv1 ⇒ SMBv1 protocol
Pulisco ⇒ Cleaning
Pulizia disco ⇒ Disk cleanup
Pulizia: ⇒ Cleanup:
Punti di ripristino ⇒ Restore points
Punto di ripristino ⇒ Restore point
Punto di ripristino creato ⇒ Restore point created
Punto di ripristino non creato (Protezione sistema disattivata?) ⇒ Restore point not created (System Protection off?)
Qualcosa è andato storto ⇒ Something went wrong
Qualità del segnale ⇒ Signal quality
Questa sezione ha bisogno di internet. Collegati e premi F5 o Ricarica. ⇒ This section needs the internet. Connect and press F5 or Reload.
Qui troverai aggiornamenti, installazioni e pulizie eseguite. ⇒ Updates, installs and cleanups will appear here.
Raccolgo le informazioni… ⇒ Collecting information…
Rapporto di consegna ⇒ Delivery report
Reinstalla dallo Store ⇒ Reinstall from the Store
Reinstallata ⇒ Reinstalled
Reinstallo i driver dal backup… ⇒ Reinstalling drivers from the backup…
Report di errore di Windows ⇒ Windows error reports
Rete ⇒ Network
Rete e audio… ⇒ Network and audio…
Revisione ⇒ Revision
Riavvia il PC ⇒ Restart the PC
Riavviare il computer adesso? Salva prima il lavoro aperto. ⇒ Restart the computer now? Save your open work first.
Riavvio richiesto ⇒ Restart required
Riavvio… ⇒ Restarting…
Ricarica ⇒ Reload
Ricerca aggiornamenti di Windows… ⇒ Searching for Windows updates…
Ricerca Bing ⇒ Bing Search
Ricerca di nuovo ⇒ Search again
Rimossa ⇒ Removed
Rimosso ⇒ Removed
Rimuovi app preinstallate inutili ⇒ Remove useless preinstalled apps
Rimuovo ⇒ Removing
Ripara connessione ⇒ Repair connection
Riparato ⇒ Repaired
Riparazione ⇒ Repair
Riparazione di sistema ⇒ System repair
Ripristina driver da backup ⇒ Restore drivers from backup
Ripristinato ⇒ Restored
Ripristino ⇒ Restoring
Ripristino driver da backup ⇒ Driver restore from backup
Ripristino immagine di Windows (DISM) ⇒ Windows image repair (DISM)
Risoluzione ⇒ Resolution
Risoluzione nomi (DNS) ⇒ Name resolution (DNS)
Saltato ⇒ Skipped
Salute ⇒ Health
Scansione… ⇒ Scanning…
Scegli destinazione ⇒ Choose destination
Scegli dove salvare il backup (disco esterno, chiavetta o cartella di rete) ⇒ Choose where to save the backup (external drive, USB stick or network folder)
Scegli i passaggi e premi AVVIA: verranno eseguiti uno dopo l'altro, alla fine trovi il rapporto. ⇒ Choose the steps and press START: they run one after another, with a report at the end.
Scegli la cartella di backup dei driver (Dati\DriverBackup\data) ⇒ Choose the driver backup folder (Dati\DriverBackup\date)
Scegli prima la destinazione (disco esterno o cartella di rete) con il pulsante in alto. ⇒ First choose the destination (external drive or network folder) with the button at the top.
Scegli prima la destinazione nella sezione Backup ⇒ First choose the destination in the Backup section
Scheda madre ⇒ Motherboard
Scheda madre e firmware ⇒ Motherboard and firmware
Scheda madre e firmware… ⇒ Motherboard and firmware…
Scheda video ⇒ Graphics card
Scheda video… ⇒ Graphics card…
Scrivi un nome, ad esempio "vlc", "firefox" o "7zip", e premi Invio. ⇒ Type a name, e.g. "vlc", "firefox" or "7zip", and press Enter.
Segnalazioni errori ⇒ Error reports
Seleziona prima i programmi da escludere ⇒ Select the apps to exclude first
Seleziona un solo punto di ripristino ⇒ Select a single restore point
Sensori avanzati attivati ⇒ Advanced sensors enabled
Sensori avanzati: attivi ⇒ Advanced sensors: on
Seriale scheda ⇒ Board serial
Server Cloudflare più vicino ⇒ Nearest Cloudflare server
Si attiva dal firmware UEFI ⇒ Enabled from the UEFI firmware
Sicurezza ⇒ Security
Sicurezza di Windows ⇒ Windows Security
silenziosa ⇒ silent
Sistema ⇒ System
Sistema operativo ⇒ Operating system
Sistema… ⇒ System…
Slot occupati ⇒ Slots used
Software di terze parti e marchi ⇒ Third-party software and trademarks
Solitaire Collection ⇒ Solitaire Collection
STATO ⇒ STATUS
Stato ⇒ Status
Storico sensori ⇒ Sensor history
Suggerimenti ⇒ Tips
Svuota definitivamente il cestino ⇒ Permanently empty the Recycle Bin
Svuotare la cronologia? ⇒ Clear history?
Telemetria al minimo ⇒ Minimum telemetry
Telemetria minima, niente pubblicità e suggerimenti ⇒ Minimum telemetry, no ads and suggestions
Temperatura ⇒ Temperature
Temporanei e cache degli aggiornamenti ⇒ Temporary files and update cache
Temporanei, cache di Windows Update, report errori e dump ⇒ Temporary files, Windows Update cache, error reports and dumps
Test di Windows (WinSAT): circa 1-3 minuti in tutto. Chiudi gli altri programmi per risultati affidabili. ⇒ Windows tests (WinSAT): about 1-3 minutes in total. Close other apps for reliable results.
TEST VELOCITÀ ⇒ SPEED TEST
Test velocità ⇒ Speed test
TEST VELOCITÀ misura download e upload; RIPARA CONNESSIONE azzera la configurazione di rete di Windows. ⇒ SPEED TEST measures download and upload; REPAIR CONNECTION resets the Windows network configuration.
Test velocità: Cloudflare ⇒ Speed test: Cloudflare
TIPO ⇒ TYPE
Tipo ⇒ Type
Totale ⇒ Total
Tutte le sezioni sono pronte ⇒ All sections ready
Tutti gli aggiornamenti winget e Microsoft Store, escluse le esclusioni ⇒ All winget and Microsoft Store updates, except excluded ones
Tutto aggiornato ⇒ All up to date
Tutto ok ⇒ All good
UEFI  ·  Secure Boot attivo ⇒ UEFI  ·  Secure Boot on
UEFI  ·  Secure Boot disattivo ⇒ UEFI  ·  Secure Boot off
Ultima scansione rapida ⇒ Last quick scan
Ultimo aggiornamento di Windows ⇒ Last Windows update
Un'operazione è in corso: chiudendo ora potresti lasciare un'installazione a metà. Chiudere comunque? ⇒ An operation is in progress: closing now could leave an installation half-done. Close anyway?
Usura ⇒ Wear
Va lasciato disattivato ⇒ Should stay disabled
VALORE ⇒ VALUE
VARIAZIONE ⇒ CHANGE
VELOCITÀ ⇒ SPEED
Velocità download ⇒ Download speed
Velocità upload ⇒ Upload speed
Ventola ⇒ Fan
Verrà ricreata automaticamente ⇒ Will be recreated automatically
Video ⇒ Videos
Virtualizzazione ⇒ Virtualization
Windows è aggiornato ⇒ Windows is up to date
Windows espone solo alcuni sensori (zone termiche, dischi, carico). Per temperature dei core, ventole e consumi premi "Attiva sensori avanzati". ⇒ Windows exposes only a few sensors (thermal zones, disks, load). For core temperatures, fans and power draw press "Enable advanced sensors".
Windows non chiede più valutazioni e opinioni ⇒ Windows stops asking for ratings and opinions
Windows non registra né invia le attività svolte ⇒ Windows does not record or send your activities
Windows parte già leggero. ⇒ Windows already starts light.
Windows Update: ⇒ Windows Update:
Windows, Microsoft Store, Microsoft Defender e winget sono marchi di Microsoft Corporation. Intel, NVIDIA, AMD e gli altri nomi di prodotti e aziende citati sono marchi dei rispettivi titolari. MultiTool è un progetto indipendente, non affiliato né approvato da questi soggetti. ⇒ Windows, Microsoft Store, Microsoft Defender and winget are trademarks of Microsoft Corporation. Intel, NVIDIA, AMD and other product and company names mentioned are trademarks of their respective owners. MultiTool is an independent project, not affiliated with or endorsed by them.
winget e Microsoft Store ⇒ winget and Microsoft Store
winget non ha trovato aggiornamenti disponibili. ⇒ winget found no available updates.
winget non trovato: installa "Programma di installazione app" dal Microsoft Store ⇒ winget not found: install "App Installer" from the Microsoft Store
WinSAT · strumento di Windows ⇒ WinSAT · Windows tool
Zona termica ⇒ Thermal zone
Integro ⇒ Healthy
Guasto ⇒ Failed
Sconosciuto ⇒ Unknown
Attenzione ⇒ Warning
Buona ⇒ Good
Usurata ⇒ Worn
Da sostituire ⇒ Replace
Portatile ⇒ Laptop
Piombo ⇒ Lead-acid
Nichel-cadmio ⇒ Nickel-cadmium
Nichel-metallo idruro ⇒ Nickel-metal hydride
Litio-polimero ⇒ Lithium-polymer
Presente ⇒ Present
Assente ⇒ Absent
Attiva ⇒ On
Disattivata ⇒ Off
Non rilevata ⇒ Not detected
Antivirus di terze parti? ⇒ Third-party antivirus?
Prima di iniziare ⇒ Before you start
Leggi le condizioni d'uso qui sotto. MultiTool modifica impostazioni di sistema, installa e rimuove programmi: per usarlo devi accettarle. ⇒ Read the terms of use below. MultiTool changes system settings, installs and removes apps: you must accept them to use it.
Accetto ⇒ I accept
Non accetto ed esco ⇒ I don't accept, exit
Privacy ⇒ Privacy
Filtra l'elenco… ⇒ Filter the list…
Esporta CSV ⇒ Export CSV
Cerca una sezione o un comando… ⇒ Search for a section or command…
Invio per aprire  ·  Esc per chiudere  ·  F5 ricarica  ·  Ctrl+H Home ⇒ Enter to open  ·  Esc to close  ·  F5 reload  ·  Ctrl+H Home
Esporta configurazione ⇒ Export configuration
Importa configurazione ⇒ Import configuration
Esegui la manutenzione completa (anche Windows Update e pulizia) ⇒ Run the full maintenance (also Windows Update and cleanup)
Apri MultiTool ⇒ Open MultiTool
Esci ⇒ Exit
Antivirus Microsoft Defender disattivato ⇒ Microsoft Defender antivirus disabled
Creazione non riuscita: la protezione sistema potrebbe essere disattivata ⇒ Creation failed: System Protection may be disabled
Destinazione del backup non disponibile: collega il disco o sceglila di nuovo ⇒ Backup destination not available: connect the drive or choose it again
il file non è una configurazione di MultiTool ⇒ the file is not a MultiTool configuration
il file scaricato contiene errori ⇒ the downloaded file contains errors
il file scaricato non corrisponde alla versione annunciata ⇒ the downloaded file does not match the announced version
Questo software ⇒ This software
{0} aggiornamenti disponibili ⇒ {0} updates available
{0} aggiornamenti disponibili. Clicca per vederli. ⇒ {0} updates available. Click to see them.
{0} aggiornamenti disponibili. I facoltativi non sono selezionati. ⇒ {0} updates available. Optional ones are not selected.
{0} aggiornati ⇒ {0} updated
{0} aggiornati, {1} errori ⇒ {0} updated, {1} errors
{0} componenti rilevati  ·  i valori si possono selezionare e copiare ⇒ {0} components found  ·  values can be selected and copied
{0} core  ·  {1} thread ⇒ {0} cores  ·  {1} threads
{0} di {1} completati ⇒ {0} of {1} completed
{0} di {1} installati ⇒ {0} of {1} installed
{0} di {1} ⇒ {0} of {1}
{0} dispositivi con problemi: apri la sezione Driver ⇒ {0} devices with problems: open the Drivers section
{0} driver di terze parti  ·  {1} dispositivi con problemi  ·  {2} non firmati  ·  {3} oltre 5 anni ⇒ {0} third-party drivers  ·  {1} devices with problems  ·  {2} unsigned  ·  {3} older than 5 years
{0} elementi elaborati ⇒ {0} items processed
{0} elementi non mostrati per un errore ⇒ {0} items not shown due to an error
{0} elementi. ⇒ {0} items.
{0} file copiati ⇒ {0} files copied
{0} impostazioni applicate ⇒ {0} settings applied
{0} installati ⇒ {0} installed
{0} installer nella cartella. Per gli .exe silenziosi crea un file nome.exe.args con i parametri. ⇒ {0} installers in the folder. For silent .exe installs create a name.exe.args file with the parameters.
{0} liberi di {1} ⇒ {0} free of {1}
{0} non corretti ⇒ {0} uncorrected
{0} ore ⇒ {0} hours
{0} pacchetti nell'elenco importato. ⇒ {0} packages in the imported list.
{0} pollici ⇒ {0} inches
{0} programmi aggiornati ⇒ {0} apps updated
{0} programmi all'avvio, {1} attivi. Seleziona e scegli ATTIVA o DISATTIVA. ⇒ {0} startup apps, {1} enabled. Select and choose ENABLE or DISABLE.
{0} programmi e app installati. ⇒ {0} programs and apps installed.
{0} programmi esclusi dagli aggiornamenti ⇒ {0} apps excluded from updates
{0} punti di ripristino. Per tornare indietro selezionane UNO e premi RIPRISTINA (il PC si riavvia). ⇒ {0} restore points. To go back select ONE and press RESTORE (the PC restarts).
{0} risultati per "{1}". ⇒ {0} results for "{1}".
{0} app rimosse ⇒ {0} apps removed
{0} rimosse ⇒ {0} removed
{0} errori ⇒ {0} errors
{0} giorni ⇒ {0} days
{0} giorni fa ⇒ {0} days ago
{0} pacchetti ⇒ {0} packages
{0} problemi ⇒ {0} problems
{0} file ⇒ {0} files
{0}  ·  acceso da {1} ⇒ {0}  ·  up for {1}
{0}  ·  app Microsoft Store ⇒ {0}  ·  Microsoft Store app
{0}  ·  del {1} ⇒ {0}  ·  from {1}
{0}  ·  esclusi quelli delle ultime 24 ore ⇒ {0}  ·  except those from the last 24 hours
{0}  ·  reinstallabile dal Microsoft Store ⇒ {0}  ·  reinstallable from the Microsoft Store
{0} del {1} ⇒ {0} of {1}
{0}  ·  versione {1} ⇒ {0}  ·  version {1}
{0} × {1} a {2} Hz ⇒ {0} × {1} at {2} Hz
{0} °C (max {1} °C) ⇒ {0} °C (max {1} °C)
{0}  ·  {1}  ·  MAC {2}  ·  driver {3} ⇒ {0}  ·  {1}  ·  MAC {2}  ·  driver {3}
© {0} {1}. Tutti i diritti riservati. ⇒ © {0} {1}. All rights reserved.
Aggiornamento non riuscito: {0} ⇒ Update failed: {0}
Aggiornare MultiTool alla versione {0}? Il programma verrà riavviato. ⇒ Update MultiTool to version {0}? The program will restart.
Aggiornate il {0} ⇒ Updated on {0}
Aggiornato da {0} ⇒ Updated from {0}
Aggiorno MultiTool alla versione {0}… ⇒ Updating MultiTool to version {0}…
Backup automatico ogni giorno alle {0} ⇒ Automatic backup every day at {0}
Backup completato con {0} errori ⇒ Backup completed with {0} errors
Backup completato: {0} file nuovi o modificati ⇒ Backup completed: {0} new or changed files
Backup driver non riuscito: {0} ⇒ Driver backup failed: {0}
Backup in {0} ⇒ Backup in {0}
Batteria: capacità al {0}% ⇒ Battery: capacity at {0}%
Calcolo: {0}… ⇒ Measuring: {0}…
Carica {0}% ⇒ Charge {0}%
Cerco "{0}" nel catalogo… ⇒ Searching "{0}" in the catalog…
chkdsk {0} /scan  ·  sola lettura ⇒ chkdsk {0} /scan  ·  read-only
Codice {0} ⇒ Code {0}
Codice errore {0}  ·  {1} ⇒ Error code {0}  ·  {1}
Conservare i dati (impostazioni, cronologia, rapporti, installer e profili) in {0}\MultiTool? ⇒ Keep the data (settings, history, reports, installers and profiles) in {0}\MultiTool?
Crittografia disco {0} ⇒ Disk encryption {0}
da {0} ⇒ from {0}
Destinazione: {0}  ·  ultimo backup: {1} ⇒ Destination: {0}  ·  last backup: {1}
Destinazione: {0}\MultiTool-Backup\{1}  ·  copia solo i file nuovi o modificati, non cancella nulla ⇒ Destination: {0}\MultiTool-Backup\{1}  ·  copies only new or changed files, never deletes anything
Disco {0} ⇒ Disk {0}
Disco {0} · lettura casuale ⇒ Disk {0} · random read
Disco {0} · lettura sequenziale ⇒ Disk {0} · sequential read
Disco {0} · scrittura sequenziale ⇒ Disk {0} · sequential write
Disco {0}: {1} °C ⇒ Disk {0}: {1} °C
Disco {0}: solo {1} liberi ⇒ Disk {0}: only {1} free
Disco {0}: stato {1} ⇒ Disk {0}: status {1}
Disco {0}: usura {1}% ⇒ Disk {0}: wear {1}%
Download {0} Mbit/s  ·  upload {1} Mbit/s ⇒ Download {0} Mbit/s  ·  upload {1} Mbit/s
Download {0}% ⇒ Download {0}%
Driver reinstallati dal backup ({0} pacchetti) ⇒ Drivers reinstalled from the backup ({0} packages)
È disponibile MultiTool {0}: vai in Impostazioni per aggiornare ⇒ MultiTool {0} is available: go to Settings to update
Errore pianificazione: {0} ⇒ Scheduling error: {0}
Errore robocopy {0} ⇒ Robocopy error {0}
Errore sensori: {0} ⇒ Sensor error: {0}
Errore: {0} ⇒ Error: {0}
Errore {0} ⇒ Error {0}
Esegui {0} {1}… ⇒ Running {0} {1}…
Eseguo {0} {1}… ⇒ Running {0} {1}…
Esito {0} ⇒ Result {0}
Esportato: {0} ⇒ Exported: {0}
Firewall · profilo {0} ⇒ Firewall · {0} profile
Firme del {0} ⇒ Signatures from {0}
fonte: {0}  ·  aggiornamento ogni 2 s ⇒ source: {0}  ·  refresh every 2 s
Importazione non riuscita: {0} ⇒ Import failed: {0}
In corso {0}% ⇒ In progress {0}%
In esecuzione da {0} (versione portatile) ⇒ Running from {0} (portable version)
Installa profilo: {0} ⇒ Install profile: {0}
Installato in {0}  ·  dati in {1} ⇒ Installed in {0}  ·  data in {1}
Installazione non riuscita: {0} ⇒ Installation failed: {0}
Installo {0} aggiornamenti… ⇒ Installing {0} updates…
Installo {0}… ⇒ Installing {0}…
Liberati {0} ⇒ Freed {0}
locale: {0} ⇒ local: {0}
MultiTool - Manutenzione: {0} passaggi da verificare ⇒ MultiTool - Maintenance: {0} steps to check
MultiTool {0}  ·  Ctrl+K per cercare ⇒ MultiTool {0}  ·  Ctrl+K to search
Pianificazione backup non riuscita: {0} ⇒ Backup scheduling failed: {0}
Prossima esecuzione: {0} ⇒ Next run: {0}
Pulisco: {0}… ⇒ Cleaning: {0}…
Punteggio sicurezza: {0}/100  ·  {1} controlli superati su {2}. Seleziona i problemi e premi CORREGGI. ⇒ Security score: {0}/100  ·  {1} of {2} checks passed. Select the problems and press FIX.
Punto n. {0} ⇒ Point no. {0}
Rimuovi app: {0} ⇒ Remove app: {0}
Rimuovo {0}… ⇒ Removing {0}…
Ripristino a: {0} ⇒ Restore to: {0}
Ripristino driver: codice {0} ⇒ Driver restore: code {0}
Scarico {0} aggiornamenti… ⇒ Downloading {0} updates…
Scarico {0}… ⇒ Downloading {0}…
Sensori avanzati non disponibili: {0} ⇒ Advanced sensors not available: {0}
Spazio liberato: {0} ⇒ Space freed: {0}
Spazio recuperabile: {0} ⇒ Reclaimable space: {0}
Stai usando l'account amministratore {0}: avvio automatico e file temporanei riguardano quell'account, non {1} ⇒ You are using the administrator account {0}: startup apps and temporary files refer to that account, not {1}
Trovati {0} aggiornamenti. Controlla l'elenco, poi scegli se procedere. ⇒ Found {0} updates. Review the list, then choose whether to proceed.
Ultime {0} operazioni. ⇒ Last {0} operations.
Ultimo test: {0} ⇒ Last test: {0}
usura {0}% ⇒ wear {0}%
Versione {0} ⇒ Version {0}
Versione installata: {0}  ·  controllo in corso… ⇒ Installed version: {0}  ·  checking…
Versione installata: {0}  ·  controllo non riuscito: {1} ⇒ Installed version: {0}  ·  check failed: {1}
Versione installata: {0}  ·  disponibile la {1} ⇒ Installed version: {0}  ·  {1} available
Versione installata: {0}  ·  è la più recente ⇒ Installed version: {0}  ·  up to date
Versione installata: {0}  ·  nessun indirizzo di aggiornamento impostato ⇒ Installed version: {0}  ·  no update address set
Versione {0}  ·  rilasciata il {1}  ·  creato da {2} ⇒ Version {0}  ·  released on {1}  ·  created by {2}
Versione {0}  ·  creato da {1} ⇒ Version {0}  ·  created by {1}
MultiTool {0}  ·  {1}  ·  creato da {2}  ·  © {3} ⇒ MultiTool {0}  ·  {1}  ·  created by {2}  ·  © {3}
Wi-Fi: {0} ⇒ Wi-Fi: {0}
winget: {0} ⇒ winget: {0}
Aggiorno {0}… ⇒ Updating {0}…
Disinstallo {0}… ⇒ Uninstalling {0}…
Copio {0}… ⇒ Copying {0}…
Misuro {0}… ⇒ Measuring {0}…
Correggo {0}… ⇒ Fixing {0}…
Applico {0}… ⇒ Applying {0}…
Ripristino {0}… ⇒ Restoring {0}…
Installo il profilo {0}… ⇒ Installing profile {0}…
Installo con SDIO {0}… ⇒ Installing {0}…
Disattivo {0}… ⇒ Disabling {0}…
Attivo {0}… ⇒ Enabling {0}…
Pulisco {0}… ⇒ Cleaning {0}…
Eseguo {0}… ⇒ Running {0}…
Scarico e installo… ⇒ Downloading and installing…
{0} › {1} ⇒ {0} › {1}
{0} con errori ⇒ {0} with errors
{0} completati ⇒ {0} completed
{0} / {1} selezionati ⇒ {0} / {1} selected
~ completati ⇒  completed
~ con errori ⇒  with errors
~ annullati ⇒  cancelled
~  ·  dati delle ⇒   ·  data from
~ selezionati ⇒  selected
~Programmi aggiornati: ⇒ Apps updated:
~Manutenzione: ⇒ Maintenance:
~Pulizia: ⇒ Cleanup:
~ mai ⇒  never
Per leggere temperature dei core, ventole e consumi serve un componente che accede ai sensori della scheda madre.\n\nVerranno installati tramite winget:\n- LibreHardwareMonitor (open source)\n- PawnIO, il driver firmato che usa per leggere i sensori\n\nProcedere? ⇒ Reading core temperatures, fans and power draw requires a component that accesses the motherboard sensors.\n\nThe following will be installed via winget:\n- LibreHardwareMonitor (open source)\n- PawnIO, the signed driver it uses to read the sensors\n\nProceed?
Sul disco {0} restano solo {1} liberi: aggiornamenti e installazioni potrebbero non riuscire. Conviene prima fare una Pulizia disco.\n\nContinuare comunque? ⇒ Only {1} free on {0}. Updates and installations may fail: run a Disk cleanup first.\n\nContinue anyway?
MultiTool è installato in {0}, con collegamenti nel menu Start e sul desktop.\n\nAprire ora la versione installata? ⇒ MultiTool is installed in {0}, with shortcuts in the Start menu and on the desktop.\n\nOpen the installed version now?
Il PC verrà riportato allo stato del punto selezionato e si RIAVVIERÀ SUBITO. I tuoi file personali non vengono toccati, ma programmi e driver installati dopo verranno rimossi. Salva il lavoro aperto. Procedere? ⇒ The PC will be returned to the selected point and will RESTART IMMEDIATELY. Your personal files are not touched, but apps and drivers installed afterwards will be removed. Save your open work. Proceed?
MultiTool è già aperto (controlla anche l'area di notifica). ⇒ MultiTool is already open (check the notification area too).
dati delle {0} ⇒ data from {0}
Servizi ⇒ Services
Processi ⇒ Processes
File grandi ⇒ Large files
Eventi di sistema ⇒ System events
Leggo i servizi… ⇒ Reading services…
Lettura dei servizi… ⇒ Reading services…
automatico ⇒ automatic
manuale ⇒ manual
in esecuzione ⇒ running
fermo ⇒ stopped
{0} servizi di programmi non Microsoft. Impostarli su MANUALE alleggerisce l'avvio: partono solo quando servono. ⇒ {0} non-Microsoft app services. Setting them to MANUAL lightens startup: they start only when needed.
Impostato su manuale ⇒ Set to manual
Impostato su automatico ⇒ Set to automatic
Imposto ⇒ Setting
IMPOSTA MANUALE ⇒ SET TO MANUAL
IMPOSTA AUTOMATICO ⇒ SET TO AUTOMATIC
I servizi selezionati partiranno solo quando servono. Se un programma smette di funzionare, rimettilo su AUTOMATICO. Procedere? ⇒ The selected services will start only when needed. If an app stops working, set it back to AUTOMATIC. Proceed?
Servizi di Windows ⇒ Windows services
Nessun servizio di terze parti ⇒ No third-party services
Misuro l'uso di CPU e memoria… ⇒ Measuring CPU and memory usage…
sistema ⇒ system
CPU alta ⇒ high CPU
RAM alta ⇒ high RAM
Gli 80 processi che usano più memoria. Quelli di sistema non si possono terminare. Le modifiche non salvate nei programmi terminati vanno perse. ⇒ The 80 processes using the most memory. System ones cannot be ended. Unsaved changes in ended apps are lost.
Terminato ⇒ Ended
Termino ⇒ Ending
MEMORIA ⇒ MEMORY
TERMINA ⇒ END
Terminare {0} processi? Le modifiche non salvate in quei programmi andranno perse. ⇒ End {0} processes? Unsaved changes in those apps will be lost.
Cerco i file più grandi in {0}… (può richiedere qualche minuto) ⇒ Looking for the largest files in {0}… (may take a few minutes)
Analizzati {0} file… ⇒ {0} files scanned…
non usato da 1 anno ⇒ unused for 1 year
{0} file oltre 100 MB su {1} analizzati in {2}. Quelli eliminati vanno nel Cestino. ⇒ {0} files over 100 MB out of {1} scanned in {2}. Deleted ones go to the Recycle Bin.
Nel Cestino ⇒ In the Recycle Bin
Sposto nel Cestino ⇒ Moving to Recycle Bin
Ricerca dei file più grandi… ⇒ Looking for the largest files…
DIMENSIONE ⇒ SIZE
MODIFICATO ⇒ MODIFIED
SPOSTA NEL CESTINO ⇒ MOVE TO RECYCLE BIN
Spostare {0} file nel Cestino? Potrai recuperarli finché non svuoti il Cestino. ⇒ Move {0} files to the Recycle Bin? You can recover them until you empty the Recycle Bin.
Apri percorso ⇒ Open location
Seleziona prima un file ⇒ Select a file first
Cerca in tutto il disco ⇒ Search the whole disk
Nessun file oltre 100 MB ⇒ No files over 100 MB
Leggo il registro eventi di sistema… ⇒ Reading the system event log…
Leggo gli arresti anomali dei programmi… ⇒ Reading app crashes…
schermata blu ⇒ blue screen
spegnimento anomalo ⇒ unexpected shutdown
critico ⇒ critical
programma ⇒ app
{0} volte ⇒ {0} times
Arresto anomalo: {0} ⇒ Crash: {0}
Modulo: {0} ⇒ Module: {0}
Ultimi 7 giorni: {0} errori di sistema ⇒ Last 7 days: {0} system errors
{0} schermate blu ⇒ {0} blue screens
{0} spegnimenti anomali ⇒ {0} unexpected shutdowns
{0} arresti di programmi ⇒ {0} app crashes
Lettura del registro eventi… ⇒ Reading the event log…
QUANTE VOLTE ⇒ HOW MANY TIMES
ULTIMA ⇒ LAST
Visualizzatore eventi ⇒ Event Viewer
Affidabilità ⇒ Reliability
Nessun errore negli ultimi 7 giorni ⇒ No errors in the last 7 days
Windows non ha registrato errori critici, schermate blu o arresti anomali. ⇒ Windows logged no critical errors, blue screens or crashes.
Segui il tema di Windows ⇒ Follow the Windows theme
Avvia con Windows (nell'area di notifica) ⇒ Start with Windows (in the notification area)
Zoom dell'interfaccia: Ctrl + e Ctrl − per ingrandire o ridurre, Ctrl 0 per tornare al normale. ⇒ Interface zoom: Ctrl + and Ctrl − to zoom in or out, Ctrl 0 to reset.
MultiTool partirà con Windows nell'area di notifica ⇒ MultiTool will start with Windows in the notification area
Avvio con Windows disattivato ⇒ Start with Windows turned off
Avvio con Windows non impostato: {0} ⇒ Start with Windows not set: {0}
Rapporto batteria ⇒ Battery report
Questo PC non ha una batteria ⇒ This PC has no battery
Creo il rapporto batteria… ⇒ Creating the battery report…
Rapporto batteria non riuscito ⇒ Battery report failed
Gestione disco ⇒ Disk Management
Monitoraggio risorse ⇒ Resource Monitor
Configurazione di sistema ⇒ System Configuration
Pannello di controllo ⇒ Control Panel
Pulizia disco di Windows ⇒ Windows Disk Cleanup
Utilità di pianificazione ⇒ Task Scheduler
Monitoraggio affidabilità ⇒ Reliability Monitor
Manutenzione: non eseguita da oltre 30 giorni ⇒ Maintenance: not run for over 30 days
Browser aperto: chiudilo e riprova ⇒ Browser open: close it and try again
Attendi la fine dell'operazione in corso prima di riavviare ⇒ Wait for the current operation to finish before restarting
Nome ⇒ Name
Dettaglio ⇒ Detail
Esito ⇒ Result
Elemento ⇒ Item
Prima ⇒ Before
Dopo ⇒ After
Generato da MultiTool ⇒ Generated by MultiTool
{0} non ha risposto entro {1} secondi ⇒ {0} did not respond within {1} seconds
Già installato ⇒ Already installed
Già aggiornato ⇒ Already up to date
Serve prima un riavvio ⇒ Restart required first
Programma aperto: chiudilo e riprova ⇒ App is open: close it and try again
Un'altra installazione è in corso ⇒ Another installation is in progress
File in uso: chiudi il programma e riprova ⇒ File in use: close the app and try again
Manca un componente richiesto ⇒ A required component is missing
Disco pieno ⇒ Disk full
Memoria insufficiente ⇒ Not enough memory
Connessione a internet assente ⇒ No internet connection
Annullato dall'utente ⇒ Cancelled by the user
Già presente una versione più recente ⇒ A newer version is already installed
Bloccato dai criteri aziendali ⇒ Blocked by company policy
File scaricato non valido (hash diverso) ⇒ Downloaded file is invalid (hash mismatch)
Nessun installer adatto a questo PC ⇒ No suitable installer for this PC
Download non riuscito ⇒ Download failed
Download degli aggiornamenti non riuscito ⇒ Update download failed
Nuova versione di Windows ⇒ New Windows version
Preferiti dei browser ⇒ Browser bookmarks
PC acceso da {0} giorni senza riavvio: riavvialo (usa Riavvia, non Arresta) ⇒ PC running for {0} days without a restart: restart it (use Restart, not Shut down)
Ancora installato (disinstallazione annullata?) ⇒ Still installed (uninstall cancelled?)
Non eseguito ⇒ Not run
Inventario hardware ⇒ Hardware inventory
Collega l'alimentatore: i test di Windows non funzionano a batteria ⇒ Plug in the charger: Windows tests do not run on battery
Avvisa prima di aprire programmi e file sconosciuti ⇒ Warns before opening unknown apps and files
Isolamento core (integrità della memoria) ⇒ Core isolation (memory integrity)
Protegge il kernel da driver e codice malevolo ⇒ Protects the kernel from malicious drivers and code
si attiva da Sicurezza di Windows ⇒ turn it on from Windows Security
RIPRISTINA ⇒ RESTORE
modificato ⇒ changed
Nessuna modifica da ripristinare ⇒ Nothing to restore
{0} servizi di programmi non Microsoft. Impostarli su MANUALE alleggerisce l'avvio: partono solo quando servono. RIPRISTINA li riporta com'erano. ⇒ {0} non-Microsoft app services. Setting them to MANUAL lightens startup: they start only when needed. RESTORE puts them back as they were.
Cache degli shader (DirectX, NVIDIA, AMD) ⇒ Shader cache (DirectX, NVIDIA, AMD)
Verrà ricreata dai giochi al primo avvio ⇒ Games will rebuild it on first launch
Log di Windows vecchi ⇒ Old Windows logs
Log di installazione e diagnostica più vecchi di 14 giorni ⇒ Setup and diagnostic logs older than 14 days
Ultimo avvio di Windows: {0} secondi ⇒ Last Windows startup: {0} seconds
Copia ⇒ Copy
Inventario copiato negli appunti ⇒ Inventory copied to the clipboard
Appunti non disponibili, riprova ⇒ Clipboard unavailable, try again
Novità di questa versione ⇒ What's new in this version
MultiTool aggiornato alla versione {0}. Le novità sono in Ctrl+K › Novità ⇒ MultiTool updated to version {0}. See what's new in Ctrl+K › What's new
Windows Update al lavoro: riprova più tardi ⇒ Windows Update is busy: try again later
File in uso: liberato poco, riprova dopo un riavvio ⇒ Files in use: little freed, try again after a restart
Download più vecchi di 90 giorni ⇒ Downloads older than 90 days
Elimina DEFINITIVAMENTE i file in {0} non modificati da 3 mesi ⇒ PERMANENTLY deletes files in {0} not modified for 3 months
Punti di ripristino vecchi ⇒ Old restore points
Tiene solo il più recente ⇒ Keeps only the most recent one
Sospeso: troppi file modificati insieme (possibile virus) ⇒ Suspended: too many files changed at once (possible malware)
Copilot disattivato ⇒ Copilot turned off
Nasconde e disattiva Copilot di Windows ⇒ Hides and turns off Windows Copilot
Recall disattivato ⇒ Recall turned off
Windows non salva istantanee dello schermo (PC Copilot+) ⇒ Windows does not save screen snapshots (Copilot+ PCs)
Niente pubblicità in Esplora file e Start ⇒ No ads in File Explorer and Start
Disattiva notifiche promozionali e consigli nel menu Start ⇒ Turns off promotional notifications and Start menu recommendations
Risveglia il PC e rimettilo in sospensione al termine ⇒ Wake the PC and put it back to sleep when done
Se all'ora prevista il PC è spento, a batteria o su una connessione a consumo, l'aggiornamento viene recuperato al primo accesso utile. ⇒ If the PC is off, on battery or on a metered connection at the scheduled time, the update runs at the next suitable sign-in.
Il PC verrà risvegliato per l'aggiornamento e poi rimesso in sospensione ⇒ The PC will be woken for the update and then put back to sleep
Risveglio automatico disattivato ⇒ Automatic wake turned off
MultiTool è già aperto da un altro utente su questo PC. Chiudilo prima di avviarlo qui. ⇒ MultiTool is already open for another user on this PC. Close it before starting it here.
Indirizzo non valido: deve iniziare con https:// ⇒ Invalid address: it must start with https://
MultiTool scaricherà ed eseguirà come amministratore gli aggiornamenti da:\n{0}\n\nUsa solo un indirizzo di cui ti fidi. Continuare? ⇒ MultiTool will download and run updates as administrator from:\n{0}\n\nOnly use an address you trust. Continue?
la nuova versione non è ancora pubblicata, riprovo tra poco ⇒ the new version is not published yet, retrying shortly
impronta SHA256 non corrispondente: aggiornamento scartato ⇒ SHA256 fingerprint mismatch: update discarded
non avvisa mai ⇒ never notifies
Versione installata: {0}  ·  connessione a consumo: controllo rimandato ⇒ Installed version: {0}  ·  metered connection: check postponed
Sei su una connessione a consumo: il test scarica circa 200 MB. Procedere? ⇒ You are on a metered connection: the test downloads about 200 MB. Proceed?
Sembra che tu stia lavorando da remoto (Desktop remoto, AnyDesk, TeamViewer o RustDesk): riparare la rete ti scollegherà dal PC. Procedere comunque? ⇒ You seem to be working remotely (Remote Desktop, AnyDesk, TeamViewer or RustDesk): repairing the network will disconnect you from the PC. Proceed anyway?
Sei collegato tramite Desktop remoto: disattivarlo impedirà le prossime connessioni remote. Procedere? ⇒ You are connected via Remote Desktop: turning it off will block future remote connections. Proceed?
essenziale ⇒ essential
Imposta automatico ⇒ Set to automatic
Licenza di Windows ⇒ Windows license
Non attivato ⇒ Not activated
Periodo di tolleranza ⇒ Grace period
Tolleranza scaduta ⇒ Grace period expired
Non attivato (notifiche) ⇒ Not activated (notifications)
Edizione ⇒ Edition
Canale ⇒ Channel
Codice parziale ⇒ Partial key
Codice OEM nel firmware ⇒ OEM key in firmware
Compatibilità Windows 11 ⇒ Windows 11 compatibility
da verificare ⇒ to be checked
NON compatibile ⇒ NOT compatible
Non compatibile ⇒ Not compatible
Probabilmente compatibile ⇒ Probably compatible
Compatibile ⇒ Compatible
Windows 11 già installato ⇒ Windows 11 already installed
UEFI (Secure Boot) ⇒ UEFI (Secure Boot)
RAM almeno 4 GB ⇒ RAM at least 4 GB
Disco almeno 64 GB ⇒ Disk at least 64 GB
Rallenta l'avvio di Windows ⇒ Slows down Windows startup
Rilevato da Windows ⇒ Detected by Windows
driver ⇒ driver
servizio ⇒ service
Restano {0} residui: premi Residui per eliminarli ⇒ {0} leftovers remain: press Leftovers to remove them
Residui ⇒ Leftovers
versione saltata ⇒ version skipped
Versione {0} saltata ⇒ Version {0} skipped
SALTA VERSIONE ⇒ SKIP VERSION
Controllo i programmi già installati… ⇒ Checking installed apps…
installato ⇒ installed
Spunta i programmi da installare e premi INSTALLA: vengono scaricati dai siti ufficiali tramite winget. ⇒ Tick the apps to install and press INSTALL: they are downloaded from official sources via winget.
Browser ⇒ Browsers
Ufficio ⇒ Office
Multimedia ⇒ Media
Comunicazione ⇒ Communication
Utilità ⇒ Utilities
Assistenza remota ⇒ Remote support
Componenti ⇒ Components
Giochi ⇒ Games
Residuo di {0} ⇒ Leftover of {0}
cartella ⇒ folder
registro ⇒ registry
Cartelle e chiavi di registro rimaste dopo le disinstallazioni. Le cartelle vanno nel Cestino, le chiavi vengono salvate in Dati\Residui prima di eliminarle. ⇒ Folders and registry keys left after uninstalls. Folders go to the Recycle Bin, keys are saved in Dati\Residui before being deleted.
Eliminato ⇒ Deleted
Elimino ⇒ Deleting
Cerco i dispositivi nella rete locale… ⇒ Looking for devices on the local network…
Nessuna rete locale connessa ⇒ No local network connected
Leggo i nomi dei dispositivi… ⇒ Reading device names…
questo PC ⇒ this PC
router ⇒ router
non risponde al ping ⇒ does not answer ping
{0} dispositivi trovati in {1}. ⇒ {0} devices found in {1}.
Calcolo lo spazio in {0}… ⇒ Calculating space in {0}…
{0} in totale. Seleziona una cartella e premi ENTRA. ⇒ {0} in total. Select a folder and press Open.
Pacchetti consigliati ⇒ Recommended apps
Controllo dei programmi installati… ⇒ Checking installed apps…
CATEGORIA ⇒ CATEGORY
Crea profilo dai selezionati ⇒ Create profile from selection
Residui delle disinstallazioni ⇒ Uninstall leftovers
Lettura dei residui… ⇒ Reading leftovers…
ELIMINA ⇒ DELETE
Eliminare {0} residui? Le cartelle vanno nel Cestino, le chiavi di registro vengono prima salvate in Dati\Residui. ⇒ Delete {0} leftovers? Folders go to the Recycle Bin, registry keys are saved first in Dati\Residui.
Torna a Disinstalla ⇒ Back to Uninstall
Apri cartella ⇒ Open folder
Seleziona prima una cartella ⇒ Select a folder first
Nessun residuo ⇒ No leftovers
Dopo una disinstallazione MultiTool cerca cartelle e chiavi rimaste e le elenca qui. ⇒ After an uninstall MultiTool looks for leftover folders and keys and lists them here.
Dispositivi in rete ⇒ Network devices
Ricerca dei dispositivi… ⇒ Searching for devices…
INDIRIZZO IP ⇒ IP ADDRESS
RISPOSTA ⇒ RESPONSE
Torna a Rete ⇒ Back to Network
Nessun dispositivo trovato ⇒ No devices found
Spazio disco ⇒ Disk space
Calcolo dello spazio occupato… ⇒ Calculating used space…
PROPORZIONE ⇒ SHARE
Entra ⇒ Open
Livello superiore ⇒ Up one level
Sei già nella cartella principale del disco ⇒ You are already at the root of the disk
Cartella vuota ⇒ Empty folder
Scheda intervento ⇒ Job sheet
Wi-Fi salvata: {0} ⇒ Saved Wi-Fi: {0}
Password della rete salvata su questo PC ⇒ Password of the network saved on this PC
senza password ⇒ no password
Rapporto sullo stato del PC ⇒ PC health report
Test della memoria RAM (al riavvio) ⇒ RAM memory test (at restart)
Stress test del processore ⇒ CPU stress test
DNS: Cloudflare (1.1.1.1) ⇒ DNS: Cloudflare (1.1.1.1)
DNS: automatico (dal router) ⇒ DNS: automatic (from the router)
Piano energetico: prestazioni elevate ⇒ Power plan: high performance
Piano energetico: bilanciato ⇒ Power plan: balanced
Piano energetico: risparmio energia ⇒ Power plan: power saver
Cambio i DNS… ⇒ Changing DNS…
DNS impostati: {0} ⇒ DNS set: {0}
DNS automatici ripristinati ⇒ Automatic DNS restored
DNS non modificati: {0} ⇒ DNS not changed: {0}
Piano energetico: {0} ⇒ Power plan: {0}
prestazioni elevate ⇒ high performance
bilanciato ⇒ balanced
risparmio energia ⇒ power saver
Piano non disponibile su questo PC (i PC con standby moderno hanno solo il piano bilanciato) ⇒ Plan not available on this PC (Modern Standby PCs only have the balanced plan)
Seleziona prima i programmi da mettere nel profilo ⇒ Select the apps for the profile first
Nome del nuovo profilo (es. "Ufficio base"): ⇒ Name of the new profile (e.g. "Basic office"):
Profilo creato: {0} ⇒ Profile created: {0}
Preparo la scheda intervento… ⇒ Preparing the job sheet…
Preparo il rapporto sullo stato del PC… ⇒ Preparing the PC health report…
Stress test CPU ⇒ CPU stress test
Stress test interrotto ⇒ Stress test stopped
Il processore lavorerà al 100% per 5 minuti mentre MultiTool registra le temperature. Chiudi gli altri programmi. Avviare? ⇒ The processor will run at 100% for 5 minutes while MultiTool records temperatures. Close other apps. Start?
Interrompi stress test ⇒ Stop stress test
Stress test finito, ma non ho letto temperature: attiva i sensori avanzati ⇒ Stress test finished, but no temperatures were read: turn on advanced sensors
Stress test finito: {0} °C, temperatura CRITICA (pulizia ventole o pasta termica) ⇒ Stress test finished: {0} °C, CRITICAL temperature (clean the fans or replace thermal paste)
Stress test finito: {0} °C, temperatura alta ⇒ Stress test finished: {0} °C, high temperature
Stress test finito: {0} °C massimi, raffreddamento a posto ⇒ Stress test finished: {0} °C max, cooling is fine
Stress test in corso: {0} rimanenti ⇒ Stress test running: {0} left
massima {0} °C ⇒ max {0} °C
Rapporto salute ⇒ Health report
Test della memoria RAM ⇒ RAM memory test
Nessun errore rilevato ⇒ No errors found
Rilevati errori: la RAM potrebbe essere difettosa ⇒ Errors found: the RAM may be faulty
RAM difettosa ⇒ faulty RAM
esito ⇒ result
Test della memoria: nessun errore ⇒ Memory test: no errors
Test della memoria: rilevati ERRORI nella RAM ⇒ Memory test: ERRORS found in RAM
Accesso come {0}: avvio, privacy, pulizia e backup vengono applicati all'utente {1} ⇒ Signed in as {0}: startup, privacy, cleanup and backup are applied to user {1}
Richiede conferme: installalo da Impostazioni › Windows Update ⇒ Needs confirmation: install it from Settings › Windows Update
da Impostazioni ⇒ from Settings
Il servizio Windows Update è disattivato ⇒ The Windows Update service is disabled
Windows Update non raggiunge i server: controlla la connessione ⇒ Windows Update cannot reach its servers: check the connection
Operazione interrotta: Windows si sta spegnendo o riavviando ⇒ Operation stopped: Windows is shutting down or restarting
Windows Update è già al lavoro: riprova tra qualche minuto ⇒ Windows Update is already busy: try again in a few minutes
Il servizio Windows Update si è fermato: riprova ⇒ The Windows Update service stopped: try again
Accesso negato a Windows Update ⇒ Access denied to Windows Update
Windows Update: errore {0} ⇒ Windows Update: error {0}
Già installata un'altra versione ⇒ Another version is already installed
Pacchetto non leggibile o danneggiato ⇒ Package unreadable or damaged
Bloccato dai criteri di sistema ⇒ Blocked by system policy
Errore grave dell'installer (dettagli in Dati\Logs) ⇒ Fatal installer error (details in Dati\Logs)
{0} aggiornati, {1} errori, {2} annullati ⇒ {0} updated, {1} errors, {2} cancelled
Formato 90 × 50 mm, da stampare su carta adesiva. ⇒ 90 × 50 mm, print on adhesive paper.
MultiTool - Backup sospeso ⇒ MultiTool - Backup suspended
Troppi file modificati insieme in: {0}. Potrebbe essere un virus: controlla prima di continuare. ⇒ Too many files changed at once in: {0}. It could be malware: check before continuing.
non rimovibile ⇒ not removable
pacchetto driver ⇒ driver package
Seleziona almeno un elemento ⇒ Select at least one item
L'aggiornamento automatico di MultiTool è in corso: riprova tra qualche minuto ⇒ MultiTool's automatic update is running: try again in a few minutes
File di origine non trovati: serve internet o un'immagine di Windows ⇒ Source files not found: internet or a Windows image is needed
Download dei file non riuscito: controlla la connessione ⇒ File download failed: check the connection
Bloccato dai criteri: DISM non può usare Windows Update ⇒ Blocked by policy: DISM cannot use Windows Update
Manca un aggiornamento di base: esegui prima Windows Update ⇒ A base update is missing: run Windows Update first
Cliente ⇒ Customer
Telefono / email ⇒ Phone / email
Computer ⇒ Computer
Problema segnalato ⇒ Reported problem
Lavoro svolto ⇒ Work done
Ricambi / materiale ⇒ Parts / materials
Ore di lavoro ⇒ Labour hours
Importo ⇒ Amount
Note ⇒ Notes
i campi sono modificabili: fai clic e scrivi, poi stampa o salva come PDF ⇒ fields are editable: click and type, then print or save as PDF
Firma del tecnico ⇒ Technician signature
Firma del cliente ⇒ Customer signature
Stampa o salva PDF ⇒ Print or save as PDF
Stato del PC ⇒ PC health
Punteggio di salute: {0} ⇒ Health score: {0}
{0} controlli superati, {1} da tenere d'occhio, {2} problemi ⇒ {0} checks passed, {1} to keep an eye on, {2} problems
Problema ⇒ Problem
Dischi ⇒ Disks
Aggiornamenti ⇒ Updates
Controllo account utente ⇒ User Account Control
Crittografia del disco ⇒ Disk encryption
Riavvio in sospeso ⇒ Pending restart
Acceso senza riavvio da ⇒ Running without restart for
Schermate blu (30 giorni) ⇒ Blue screens (30 days)
Salute della batteria ⇒ Battery health
Spazio libero {0} ⇒ Free space {0}
{0} liberi ({1}) ⇒ {0} free ({1})
{0} attivo ⇒ {0} active
Microsoft Defender disattivato ⇒ Microsoft Defender turned off
non rilevato ⇒ not detected
sì, riavvia per completare gli aggiornamenti ⇒ yes, restart to finish updates
no ⇒ no
{0} giorni fa ({1}) ⇒ {0} days ago ({1})
La destinazione è dentro una cartella da salvare ({0}): il backup copierebbe sé stesso all'infinito. Scegli un'altra cartella. ⇒ The destination is inside a folder being backed up ({0}): the backup would copy itself endlessly. Choose another folder.
Preparo lo storico dei sensori… ⇒ Preparing the sensor history…
file mancante ⇒ missing file
non modificato da 1 anno ⇒ not modified for 1 year
File non valido: {0} ⇒ Invalid file: {0}
a rischio ⇒ at risk
n.d. ⇒ n/a
Compatibilità Windows 11… ⇒ Windows 11 compatibility…
Licenza di Windows… ⇒ Windows license…
mai ⇒ never
parametri: {0} ⇒ arguments: {0}
5-15 minuti ⇒ 5-15 minutes
10-20 minuti ⇒ 10-20 minutes
DISM {0} ⇒ DISM {0}
SFC {0} ⇒ SFC {0}
Temperatura GPU ⇒ GPU temperature
Ventola GPU ⇒ GPU fan
Carico GPU ⇒ GPU load
Frequenza GPU ⇒ GPU clock
Consumo GPU ⇒ GPU power
Assistenza ⇒ Get Help
capacità {0}% rispetto al nuovo ⇒ capacity {0}% of new
Le attività pianificate vengono registrate per l'account amministratore {0}, non per {1}: partiranno solo quando {2} ha effettuato l'accesso al PC. ⇒ Scheduled tasks are registered for the administrator account {0}, not for {1}: they will only run while {2} is signed in to the PC.
Stai usando l'account amministratore {0}: i file finiranno nel suo Cestino, non in quello di {1}. Per recuperarli dovrai accedere con {2}. Continuare? ⇒ You are using the administrator account {0}: files will go to its Recycle Bin, not to {1}'s. To recover them you will need to sign in as {2}. Continue?
MultiTool resta attivo qui. Doppio clic per riaprirlo, tasto destro › Esci per chiuderlo. ⇒ MultiTool keeps running here. Double-click to reopen it, right-click › Exit to close it.
la {0} è in preparazione su GitHub, riprovo tra poco ⇒ {0} is being prepared on GitHub, retrying shortly
'@
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
if (-not ('MtTr' -as [type])) {
    $refs = @([Windows.MessageBox].Assembly.Location, [Windows.DependencyObject].Assembly.Location, [Windows.UIElement].Assembly.Location,
              [System.Xaml.XamlSchemaContext].Assembly.Location, [System.ComponentModel.INotifyPropertyChanged].Assembly.Location)
    Add-Type -TypeDefinition $MtCs -ReferencedAssemblies $refs
}
[MtTr]::Load($TrTable)
[MtTr]::On = ((Get-Settings).Lang -eq 'en')

function Invoke-AutoSleep($S) {
    if (-not $S.AutoWake -or $CliMode -or $sync.Reboot) { return }
    try {
        $l = New-Object NativeIdle.Idle+LII; $l.cbSize = 8
        [void][NativeIdle.Idle]::GetLastInputInfo([ref]$l)
        $idleMin = ([Environment]::TickCount - $l.dwTime) / 60000
        $woke = $false
        try { $w = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } -MaxEvents 1 -ErrorAction Stop; $woke = $w.TimeCreated -gt $AutoStart.AddMinutes(-20) } catch {}
        if ($woke -and $idleMin -ge 15) { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) }
    } catch {}
}
$AutoLogon = $Auto -and $Logon
# ============================================================
#  MODALITÀ AUTOMATICA (attività pianificata)
# ============================================================
if ($Auto -or $Backup) {
    $HeadMutex = New-Object Threading.Mutex($false, $(if ($Auto) { 'Local\MultiTool2026.Auto' } else { 'Local\MultiTool2026.Backup' }))
    try { if (-not $HeadMutex.WaitOne(0)) { exit } } catch [Threading.AbandonedMutexException] {}
}
if ($Auto) {
    $sync = @{}
    $S = Get-Settings
    if (-not $CliMode) {
        if ($AutoLogon) {
            $dow = [int][DayOfWeek]$S.AutoDay; $now = Get-Date
            $prev = $now.Date.AddDays(-((7 + [int]$now.DayOfWeek - $dow) % 7)) + [TimeSpan]::Parse($S.AutoTime)
            if ($prev -gt $now) { $prev = $prev.AddDays(-7) }
            if (-not $S.LastAutoRun -or [datetime]$S.LastAutoRun -ge $prev) { exit }
        }
        if (Test-OnBattery) { Add-History 'Automatico' 'Rimandato' 'PC a batteria: riprovo al prossimo accesso' 'skip'; exit }
        if (Test-Metered) { Add-History 'Automatico' 'Rimandato' 'Connessione a consumo: riprovo al prossimo accesso' 'skip'; exit }
        $S | Add-Member -NotePropertyName LastAutoRun -NotePropertyValue (Get-Date).ToString('s') -Force; Save-Json 'settings.json' $S
    }
    $idle0 = $null
    try { Add-Type -Name Idle -Namespace NativeIdle -MemberDefinition '[StructLayout(LayoutKind.Sequential)] public struct LII { public uint cbSize; public uint dwTime; } [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LII p);' } catch {}
    $WorkMx = New-Object Threading.Mutex($false, 'Global\MultiTool2026.Work')
    $gotWork = $false; try { $gotWork = $WorkMx.WaitOne(0) } catch [Threading.AbandonedMutexException] { $gotWork = $true }
    if (-not $gotWork) { Add-History 'Automatico' 'Rimandato' 'MultiTool sta già lavorando: riprovo al prossimo accesso' 'skip'; exit }
    $script:rpDone = -not $S.Restore
    function Ensure-RestorePoint { if (-not $script:rpDone) { $script:rpDone = $true; [void](New-RestorePoint 'MultiTool - Aggiornamento automatico') } }
    $AutoStart = Get-Date
    $steps = switch ($CliMode) { 'clean' { @('clean') } 'full' { @('upd', 'wu', 'clean', 'drv') } 'upd' { $null } default { if ($S.AutoFull) { @('upd', 'wu', 'clean', 'drv') } else { $null } } }
    if ($steps) {
        $area = 'Manutenzione automatica'
        $res = foreach ($k in $steps) {
            $it = [pscustomobject]@{ Key = $k; Name = $k; Sub = ''; Status = ''; StatusKind = 'none' }
            if ($k -in 'upd', 'wu') { Ensure-RestorePoint }
            try { Invoke-MaintStep $it } catch { $it.StatusKind = 'err'; $it.Status = $_.Exception.Message }
            Add-History $area $(switch ($k) { 'upd' { 'Aggiorna programmi' } 'wu' { 'Windows Update' } 'clean' { 'Pulizia disco' } 'drv' { 'Controllo driver' } }) $it.Status $it.StatusKind
            $it
        }
        $bad = @($res | Where-Object { $_.StatusKind -eq 'err' }).Count
        $msg = ($res | ForEach-Object { $_.Sub } | Where-Object { $_ }) -join ' · '
        if ($sync.Reboot) { $msg += ' - riavvio consigliato' }
        Show-Toast $(if ($bad) { "MultiTool - Manutenzione: $bad passaggi da verificare" } else { 'MultiTool - Manutenzione completata' }) $msg
        Invoke-AutoSleep $S
        exit
    }
    $excl = Read-Exclusions
    Start-StoreScan
    $ok = 0; $err = 0
    try {
        $r = Invoke-Hidden (Get-WingetPath) 'upgrade --include-unknown --accept-source-agreements --disable-interactivity' 300
        foreach ($t in @(ConvertFrom-WingetTable $r.Out -FirstOnly | Sort-Object { $_.Cols[1] -eq 'Microsoft.AppInstaller' })) {
            $c = $t.Cols
            if ($c.Count -lt 4 -or $excl -contains $c[1] -or $c[1] -match '…$' -or (Test-SkippedVer $c)) { continue }
            $src = if ($c.Count -ge 5) { $c[4] } else { '' }
            Ensure-RestorePoint
            $x = Invoke-Winget 'upgrade' $c[1] $src
            $k, $txt = Get-WingetResult $x.Code 'Aggiornato'
            Add-History 'Automatico' $c[0] $txt $k
            if ($k -eq 'ok') { $ok++ } else { $err++ }
        }
        $msg = if ($ok + $err) { "$ok programmi aggiornati" + $(if ($err) { ", $err con errori" } else { '' }) } else { 'Nessun aggiornamento disponibile' }
    } catch { $msg = "Errore: $($_.Exception.Message)" }
    if ($sync.Reboot) { $msg += ' - riavvio consigliato' }
    if ($ok + $err -or $CliMode -or $msg -like 'Errore*') { Show-Toast 'MultiTool - Aggiornamento automatico' $msg }
    Invoke-AutoSleep $S
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
    $sus = @()
    foreach ($f in Get-BackupFolders | Where-Object { $_.Def -and $_.Path -and (Test-Path $_.Path) }) {
        $r = Invoke-BackupEntry $f $root
        if ($r.Suspect) { $sus += $f.Name } elseif ($r.Code -lt 8) { $n += [Math]::Max(0, $r.Copied) } else { $err++ }
    }
    $S2 = Get-Settings; $S2 | Add-Member -NotePropertyName LastBackup -NotePropertyValue (Get-Date).ToString('s') -Force; Save-Json 'settings.json' $S2
    Add-History 'Backup automatico' $root $(if ($sus) { "Sospeso: $($sus -join ', ')" } elseif ($err) { "$err errori" } else { "$n file copiati" }) $(if ($err -or $sus) { 'err' } else { 'ok' })
    if ($sus) { Show-Toast 'MultiTool - Backup sospeso' "Troppi file modificati insieme in: $($sus -join ', '). Potrebbe essere un virus: controlla prima di continuare." }
    else { Show-Toast 'MultiTool - Backup' $(if ($err) { "Backup completato con $err errori" } else { "Backup completato: $n file nuovi o modificati" }) }
    exit
}

# ============================================================
#  DISINSTALLAZIONE
# ============================================================
if ($Uninstall) {
    Add-Type -AssemblyName PresentationFramework
    if ([MtTr]::Msg('Disinstallare MultiTool da questo PC?', 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { exit }
    $keepData = [MtTr]::Msg("Conservare i dati (impostazioni, cronologia, rapporti, installer e profili) in $env:ProgramData\MultiTool?", 'MultiTool', 'YesNo', 'Question') -eq 'Yes'
    Get-ScheduledTask -TaskName 'MultiTool*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName 'MultiTool*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    foreach ($d in [Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('CommonDesktopDirectory')) { Remove-Item (Join-Path $d 'MultiTool.lnk') -Force -ErrorAction SilentlyContinue }
    Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MultiTool' -Recurse -Force -ErrorAction SilentlyContinue
    $target = if ($Installed) { $Root } else { Join-Path $env:ProgramFiles 'MultiTool' }
    Remove-Item 'HKCU:\Software\Classes\AppUserModelId\Erodyne.MultiTool' -Recurse -Force -ErrorAction SilentlyContinue
    $cmd = "timeout /t 3 /nobreak >nul & rmdir /s /q `"$target`"" + $(if (-not $keepData) { " & rmdir /s /q `"$env:ProgramData\MultiTool`"" } else { '' })
    Start-Process cmd.exe -ArgumentList "/c $cmd" -WindowStyle Hidden
    [void][MtTr]::Msg('MultiTool è stato disinstallato.', 'MultiTool', 'OK', 'Information')
    exit
}

# --- Nasconde la console ---
Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
'@
[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)
Add-Type -Name Power -Namespace NativePow -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'

# --- Identità propria sulla barra delle applicazioni (altrimenti Windows mostra l'icona di PowerShell) ---
Add-Type -Name Shell -Namespace NativeApp -MemberDefinition @'
[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@
[void][NativeApp.Shell]::SetCurrentProcessExplicitAppUserModelID('Erodyne.MultiTool')

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# --- Istanza unica ---
$Mutex = New-Object Threading.Mutex($false, 'Local\MultiTool2026')
$ShowEvt = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\MultiTool2026.Show')
$got = $false
try { $got = $Mutex.WaitOne($(if ($Restart) { 20000 } else { 0 })) } catch [Threading.AbandonedMutexException] { $got = $true }
if (-not $got) {
    # un'altra istanza: le chiedo di mostrarsi; se invece si sta chiudendo (riavvio dopo un aggiornamento) aspetto e prendo il suo posto
    [void]$ShowEvt.Set()
    try { $got = $Mutex.WaitOne(12000) } catch [Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { exit }
    [void]$ShowEvt.Reset()
}
$WorkMx = New-Object Threading.Mutex($false, 'Global\MultiTool2026.Work')
$GMutex = $null
try {
    $GMutex = New-Object Threading.Mutex($false, 'Global\MultiTool2026.Any')
    $g2 = $false
    try { $g2 = $GMutex.WaitOne($(if ($Restart) { 20000 } else { 12000 })) } catch [Threading.AbandonedMutexException] { $g2 = $true }
    if (-not $g2) { [void][MtTr]::Msg('MultiTool è già aperto da un altro utente su questo PC. Chiudilo prima di avviarlo qui.', 'MultiTool', 'OK', 'Information'); exit }
} catch {}
$Settings = Get-Settings
$EffTheme = [string]$Settings.Theme
if ($EffTheme -eq 'auto') {
    $EffTheme = 'dark'
    try { if ((Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme -ErrorAction Stop) -eq 1) { $EffTheme = 'light' } } catch {}
}

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
    if ($EffTheme -ne 'light') { return $Text }
    [regex]::Replace($Text, '#[0-9A-Fa-f]{6}(?![0-9A-Fa-f])', { param($m) $k = $m.Value.ToUpper(); if ($ThemeMap.ContainsKey($k)) { $ThemeMap[$k] } else { $m.Value } })
}



# ============================================================
#  Informazioni e note legali
# ============================================================
$Legal = @(
    @{ T = 'Condizioni d''uso ed esclusione di garanzia'; B = @(
        'MultiTool è fornito «così com''è», senza garanzie di alcun tipo, esplicite o implicite, comprese quelle di funzionamento senza errori, di idoneità a uno scopo particolare e di compatibilità con uno specifico computer.'
        'Il programma modifica impostazioni di Windows e del registro di sistema, installa, aggiorna e rimuove programmi, app e driver, elimina file temporanei e può riavviare il computer. Prima di usarlo esegui un backup dei tuoi dati. Le operazioni vengono avviate solo dopo la tua conferma e, se l''opzione è attiva, dopo la creazione di un punto di ripristino.'
        'Nei limiti massimi consentiti dalla legge, l''autore non è responsabile di danni diretti o indiretti, perdita di dati, malfunzionamenti, interruzioni di attività o mancati guadagni derivanti dall''uso o dall''impossibilità di usare il programma. Restano salvi i casi di dolo o colpa grave (art. 1229 c.c.) e i diritti che la legge riconosce ai consumatori e che non possono essere esclusi.'
        'Chi usa MultiTool su computer di terzi (ad esempio clienti) è responsabile di avere il loro consenso e di informarli delle operazioni eseguite.') }
    @{ T = 'Privacy'; B = @(
        'MultiTool non raccoglie, non registra e non invia all''autore alcun dato personale o informazione sul computer. Inventario hardware, cronologia, log, rapporti e impostazioni restano esclusivamente sul PC, nella cartella Dati.'
        'Per funzionare il programma si collega a servizi esterni, che hanno proprie informative: GitHub (aggiornamenti di MultiTool), Microsoft (winget, Microsoft Store, Windows Update, Catalogo Microsoft Update), Cloudflare e ipify (test di velocità e IP pubblico, solo quando li avvii), cdnjs e jsDelivr (grafici e codici QR nei rapporti HTML).') }
    @{ T = 'Software di terze parti e marchi'; B = @(
        'MultiTool non include software di terze parti. Gli strumenti facoltativi (ad esempio LibreHardwareMonitor, licenza MPL-2.0, e il driver PawnIO) vengono scaricati dai canali ufficiali tramite winget solo dopo la tua conferma e sono regolati dalle rispettive licenze. I programmi installati con winget o dalle cartelle Installers e Profili sono soggetti alle licenze dei loro autori, che accetti al momento dell''installazione.'
        'Windows, Microsoft Store, Microsoft Defender e winget sono marchi di Microsoft Corporation. Intel, NVIDIA, AMD e gli altri nomi di prodotti e aziende citati sono marchi dei rispettivi titolari. MultiTool è un progetto indipendente, non affiliato né approvato da questi soggetti.') }
    @{ T = 'Licenza'; B = @(
        "© $((Get-Date).Year) $AppAuthor. Tutti i diritti riservati."
        'L''uso del programma è gratuito, anche in ambito professionale. Non è consentito vendere, ridistribuire versioni modificate o presentare il programma come proprio senza l''autorizzazione scritta dell''autore.') }
)
function Get-AppDate {
    $p = $AppVersion -split '\.'
    try { return [datetime]::new([int]$p[0], [int]$p[1], [int]$p[2]) } catch { return $null }
}

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
          <RowDefinition Height="Auto"/>
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

        <!-- Piè di pagina -->
        <Border Grid.Row="2" Grid.ColumnSpan="2" BorderBrush="#1C2130" BorderThickness="0,1,0,0" Padding="22,6,22,8">
          <Grid>
            <TextBlock x:Name="FootBar" Foreground="#5C6278" FontSize="11.5" VerticalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="FootGit" Style="{StaticResource LinkBtn}" Content="GitHub" FontSize="11.5" Padding="8,2"/>
              <Button x:Name="FootAbout" Style="{StaticResource LinkBtn}" Content="Informazioni e note legali" FontSize="11.5" Padding="8,2" Foreground="#A78BFA"/>
            </StackPanel>
          </Grid>
        </Border>

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
            <RadioButton x:Name="NavPacks"     Style="{StaticResource Nav}" Tag="&#xE7B8;" Content="Pacchetti consigliati"/>
            <RadioButton x:Name="NavProfiles"  Style="{StaticResource Nav}" Tag="&#xE8F1;" Content="Profili"/>
            <RadioButton x:Name="NavUninstall" Style="{StaticResource Nav}" Tag="&#xE74D;" Content="Disinstalla"/>
            <RadioButton x:Name="NavBackup"    Style="{StaticResource Nav}" Tag="&#xE753;" Content="Backup"/>
            <TextBlock Text="SISTEMA" Style="{StaticResource NavSection}"/>
            <RadioButton x:Name="NavHw"        Style="{StaticResource Nav}" Tag="&#xE7F8;" Content="Hardware"/>
            <RadioButton x:Name="NavWU"        Style="{StaticResource Nav}" Tag="&#xE777;" Content="Windows Update"/>
            <RadioButton x:Name="NavDrivers"   Style="{StaticResource Nav}" Tag="&#xE950;" Content="Driver"/>
            <RadioButton x:Name="NavStartup"   Style="{StaticResource Nav}" Tag="&#xE7E8;" Content="Avvio automatico"/>
            <RadioButton x:Name="NavServices"  Style="{StaticResource Nav}" Tag="&#xE912;" Content="Servizi"/>
            <RadioButton x:Name="NavProcesses" Style="{StaticResource Nav}" Tag="&#xE9D9;" Content="Processi"/>
            <RadioButton x:Name="NavCleanup"   Style="{StaticResource Nav}" Tag="&#xE894;" Content="Pulizia disco"/>
            <RadioButton x:Name="NavBigFiles"  Style="{StaticResource Nav}" Tag="&#xE8B7;" Content="File grandi"/>
            <RadioButton x:Name="NavSpace"     Style="{StaticResource Nav}" Tag="&#xEDA2;" Content="Spazio disco"/>
            <RadioButton x:Name="NavRepair"    Style="{StaticResource Nav}" Tag="&#xE90F;" Content="Riparazione"/>
            <RadioButton x:Name="NavEvents"    Style="{StaticResource Nav}" Tag="&#xE7BA;" Content="Eventi di sistema"/>
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
              <TextBlock x:Name="HLast" FontSize="12.5" Foreground="#6B7290" Margin="0,6,0,0" TextWrapping="Wrap"/>
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

            <Grid x:Name="LFilterBox" Grid.Row="1" Margin="0,14,0,0" Visibility="Collapsed" HorizontalAlignment="Left" Width="340">
              <TextBox x:Name="LFilter" Style="{StaticResource Input}" FontSize="13"/>
              <TextBlock x:Name="LFilterHint" Text="Filtra l'elenco…" Foreground="#5C6278" FontSize="13" Margin="14,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
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
                <Button x:Name="LCsv" Style="{StaticResource LinkBtn}" Content="Esporta CSV" Visibility="Collapsed" Margin="0,0,4,0"/>
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
                <Button x:Name="HwBat" Style="{StaticResource LinkBtn}" Content="Rapporto batteria"/>
                <Button x:Name="HwHealth" Style="{StaticResource LinkBtn}" Content="Rapporto salute"/>
                <Button x:Name="HwStress" Style="{StaticResource LinkBtn}" Content="Stress test CPU"/>
                <Button x:Name="HwAdv" Style="{StaticResource LinkBtn}" Content="Attiva sensori avanzati"/>
                <Button x:Name="HwCopy" Style="{StaticResource LinkBtn}" Content="Copia"/>
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

          <!-- ===================== INFORMAZIONI ===================== -->
          <ScrollViewer x:Name="ViewAbout" Grid.Row="1" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="0,10,0,10" MaxWidth="900" HorizontalAlignment="Left">
              <StackPanel Orientation="Horizontal">
                <Image x:Name="AboutLogo" Width="72" Height="72"/>
                <StackPanel Margin="18,0,0,0" VerticalAlignment="Center">
                  <TextBlock Text="MultiTool" FontSize="32" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
                  <TextBlock x:Name="AboutVer" Foreground="#9AA0B8" FontSize="14"/>
                </StackPanel>
              </StackPanel>
              <Border x:Name="AboutAcceptBox" Style="{StaticResource Card}" Margin="0,20,0,0" BorderBrush="#7C5CFF" Visibility="Collapsed">
                <StackPanel>
                  <TextBlock Text="Prima di iniziare" FontSize="18" FontWeight="SemiBold"/>
                  <TextBlock Text="Leggi le condizioni d'uso qui sotto. MultiTool modifica impostazioni di sistema, installa e rimuove programmi: per usarlo devi accettarle." Foreground="#9AA0B8" TextWrapping="Wrap" Margin="0,6,0,14"/>
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="AboutAccept" Style="{StaticResource AccentBtn}" Content="Accetto" MinWidth="140" Margin="0,0,10,0"/>
                    <Button x:Name="AboutDecline" Style="{StaticResource GhostBtn}" Content="Non accetto ed esco" MinWidth="160"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              <StackPanel x:Name="AboutBody" Margin="0,10,0,0"/>
            </StackPanel>
          </ScrollViewer>

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
                    <CheckBox x:Name="SetAutoFull" Style="{StaticResource Switch}" Margin="0,12,0,0" FontSize="14" Content="Esegui la manutenzione completa (anche Windows Update e pulizia)"/>
                    <CheckBox x:Name="SetAutoWake" Style="{StaticResource Switch}" Margin="0,12,0,0" FontSize="14" Content="Risveglia il PC e rimettilo in sospensione al termine"/>
                    <TextBlock Text="Se all'ora prevista il PC è spento, a batteria o su una connessione a consumo, l'aggiornamento viene recuperato al primo accesso utile." Foreground="#6B7290" FontSize="12" Margin="50,6,0,0" TextWrapping="Wrap"/>
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
                      <Button x:Name="SetCfgExp" Style="{StaticResource GhostBtn}" Content="Esporta configurazione" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                      <Button x:Name="SetCfgImp" Style="{StaticResource GhostBtn}" Content="Importa configurazione" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="ASPETTO E AVVIO" Style="{StaticResource CardLabel}"/>
                    <CheckBox x:Name="SetAutoTheme" Style="{StaticResource Switch}" Margin="0,16,0,0" FontSize="14" Content="Segui il tema di Windows"/>
                    <CheckBox x:Name="SetLight" Style="{StaticResource Switch}" Margin="0,14,0,0" FontSize="14" Content="Tema chiaro (riavvia MultiTool)"/>
                    <CheckBox x:Name="SetStartup" Style="{StaticResource Switch}" Margin="0,14,0,0" FontSize="14" Content="Avvia con Windows (nell'area di notifica)"/>
                    <CheckBox x:Name="SetTray" Style="{StaticResource Switch}" Margin="0,14,0,0" FontSize="14" Content="Riduci nell'area di notifica"/>
                    <CheckBox x:Name="SetPrefetch" Style="{StaticResource Switch}" Margin="0,14,0,0" FontSize="14" Content="Prepara tutte le sezioni all'avvio"/>
                    <TextBlock Text="Con l'icona nell'area di notifica MultiTool controlla gli aggiornamenti ogni 6 ore e ti avvisa." Foreground="#6B7290" FontSize="12" Margin="50,6,0,0" TextWrapping="Wrap"/>
                    <TextBlock Text="Zoom dell'interfaccia: Ctrl + e Ctrl − per ingrandire o ridurre, Ctrl 0 per tornare al normale." Foreground="#6B7290" FontSize="12" Margin="50,6,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="AGGIORNAMENTI DI MULTITOOL" Style="{StaticResource CardLabel}"/>
                    <TextBlock x:Name="SetUpdInfo" Foreground="#9AA0B8" FontSize="13" Margin="0,12,0,10" TextWrapping="Wrap"/>
                    <CheckBox x:Name="SetSelfUpd" Style="{StaticResource Switch}" Margin="0,0,0,12" FontSize="14" Content="Aggiorna MultiTool automaticamente"/>
                    <TextBox x:Name="SetUpdUrl" Style="{StaticResource Input}" FontSize="12"/>
                    <TextBlock Text="Lascia vuoto per usare GitHub (Erodyne/MultiTool), oppure indica un'altra cartella online con version.txt e MultiTool.ps1." Foreground="#6B7290" FontSize="11" Margin="2,6,0,10" TextWrapping="Wrap"/>
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
                      <Button x:Name="SetAbout" Style="{StaticResource GhostBtn}" Content="Informazioni e note legali" Padding="16,8" FontSize="13" Margin="0,0,8,8"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
              </UniformGrid>
            </StackPanel>
          </ScrollViewer>

          <!-- Ricerca rapida (Ctrl+K) -->
          <Grid x:Name="Palette" Grid.RowSpan="2" Visibility="Collapsed" Background="#B30B0D12">
            <Border Width="560" VerticalAlignment="Top" Margin="0,60,0,0" Background="#12151D" BorderBrush="#343B55" BorderThickness="1" CornerRadius="16" Padding="14">
              <StackPanel>
                <Grid>
                  <TextBox x:Name="PalText" Style="{StaticResource Input}" FontSize="15"/>
                  <TextBlock x:Name="PalHint" Text="Cerca una sezione o un comando…" Foreground="#5C6278" FontSize="15" Margin="14,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
                <ListBox x:Name="PalList" Background="Transparent" BorderThickness="0" MaxHeight="360" Margin="0,10,0,0" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                  <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                      <Setter Property="Cursor" Value="Hand"/>
                      <Setter Property="Template">
                        <Setter.Value>
                          <ControlTemplate TargetType="ListBoxItem">
                            <Border x:Name="b" CornerRadius="8" Padding="12,8" Background="Transparent">
                              <TextBlock Text="{Binding N}" Foreground="#E8EAF2" FontSize="14"/>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#141823"/></Trigger>
                              <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#1B1F2E"/></Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Setter.Value>
                      </Setter>
                    </Style>
                  </ListBox.ItemContainerStyle>
                </ListBox>
                <TextBlock Text="Invio per aprire  ·  Esc per chiudere  ·  F5 ricarica  ·  Ctrl+H Home" Foreground="#5C6278" FontSize="11.5" Margin="4,8,0,0"/>
              </StackPanel>
            </Border>
          </Grid>

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
$TrEn['Pacchetti consigliati'] = 'Recommended apps'
$TrEn['Spazio disco'] = 'Disk space'
$TrEn['Rapporto salute'] = 'Health report'
$TrEn['Stress test CPU'] = 'CPU stress test'
$TrEn['Risveglia il PC e rimettilo in sospensione al termine'] = 'Wake the PC and put it back to sleep when done'
$TrEn['Se all''ora prevista il PC è spento, a batteria o su una connessione a consumo, l''aggiornamento viene recuperato al primo accesso utile.'] = 'If the PC is off, on battery or on a metered connection at the scheduled time, the update runs at the next suitable sign-in.'
$TrEn['Copia'] = 'Copy'
$TrEn['Servizi'] = 'Services'
$TrEn['Processi'] = 'Processes'
$TrEn['File grandi'] = 'Large files'
$TrEn['Eventi di sistema'] = 'System events'
$TrEn['Segui il tema di Windows'] = 'Follow the Windows theme'
$TrEn['Avvia con Windows (nell''area di notifica)'] = 'Start with Windows (in the notification area)'
$TrEn['Zoom dell''interfaccia: Ctrl + e Ctrl − per ingrandire o ridurre, Ctrl 0 per tornare al normale.'] = 'Interface zoom: Ctrl + and Ctrl − to zoom in or out, Ctrl 0 to reset.'
$TrEn['Rapporto batteria'] = 'Battery report'
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
$TrEn['Lascia vuoto per usare GitHub (Erodyne/MultiTool), oppure indica un''altra cartella online con version.txt e MultiTool.ps1.'] = 'Leave empty to use GitHub (Erodyne/MultiTool), or enter another online folder with version.txt and MultiTool.ps1.'
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
$TrEn['Aggiorna MultiTool automaticamente'] = 'Update MultiTool automatically'
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
function T([string]$t) { if ($Settings.Lang -ne 'en' -or -not $t) { return $t }; if ($TrEn.ContainsKey($t)) { return $TrEn[$t] }; [MtTr]::T($t) }
function Apply-Lang([string]$Text) {
    if ($Settings.Lang -ne 'en') { return $Text }
    [regex]::Replace($Text, '(Text|Content|ToolTip)="([^"{][^"]*)"', { param($m) $v = [Net.WebUtility]::HtmlDecode($m.Groups[2].Value); $n = T $v; if ($n -ne $v) { "$($m.Groups[1].Value)=`"$([Security.SecurityElement]::Escape($n))`"" } else { $m.Value } })
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

if ($Settings.Lang -eq 'en') {
    $tbDesc = [ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.TextBlock]::TextProperty, [Windows.Controls.TextBlock])
    $tbFix = [EventHandler]{ param($s, $e) $t = [MtTr]::T($s.Text); if ($t -ne $s.Text) { $s.Text = $t } }
    foreach ($el in $ui.Values) { if ($el -is [Windows.Controls.TextBlock]) { $tbDesc.AddValueChanged($el, $tbFix) } }
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
    $base = @{ sync = $sync; DataDir = $DataDir; InstDir = $InstDir; ProfDir = $ProfDir; area = 'MultiTool'; Root = $Root }
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
function Toast([string]$t) {
    $t = T $t
    if ($State.Q.Contains($t)) { return }
    while ($State.Q.Count -ge 5) { $State.Q.RemoveAt(0) }
    [void]$State.Q.Add($t)
}

# ============================================================
#  Codice delle analisi e delle azioni (eseguito in background)
# ============================================================
$ScanUpdates = @'
$excl = Read-Exclusions
$skv = Read-Json 'skipped.json' $null
$sync.Status = 'Avvio la scansione del Microsoft Store…'
Start-StoreScan
$sync.Status = 'Interrogo winget, attendi qualche secondo…'
$r = Invoke-Hidden (Get-WingetPath) 'upgrade --include-unknown --accept-source-agreements --disable-interactivity' 300
foreach ($t in ConvertFrom-WingetTable $r.Out -FirstOnly) {
    $c = $t.Cols
    if ($c.Count -lt 4) { continue }
    $src = if ($c.Count -ge 5) { $c[4] } else { '' }
    $ex  = $excl -contains $c[1]
    $sv  = $skv -and $skv.($c[1]) -and $skv.($c[1]) -eq $c[3]
    $cut = $c[1] -match '…$'
    $rows.Add((New-Row @{ RawName = $c[0]; Sub = $c[1]; Key = $c[1]; C1 = $c[2]; C2 = $c[3]; Arrow = $true; Data = $src
        Tag = $(if ($ex) { 'escluso' } elseif ($sv) { 'versione saltata' } else { $src }); TagKind = $(if ($ex -or $sv) { 'warn' } else { 'none' }); Selected = (-not $ex -and -not $cut -and -not $sv)
        Checkable = (-not $cut); Status = $(if ($cut) { 'ID troncato' } else { '' }); StatusKind = $(if ($cut) { 'skip' } else { 'none' }) }))
}
$n = $rows.Count
$sync.ScanInfo = if ($n) { "Trovati $n aggiornamenti. Controlla l'elenco, poi scegli se procedere." } else { $null }
'@

$ActUpdates = @'
if ($op -eq 'skipver') {
    $sk = @{}; $j = Read-Json 'skipped.json' $null
    if ($j) { foreach ($p in $j.PSObject.Properties) { $sk[$p.Name] = $p.Value } }
    foreach ($it in $items) { $sk[$it.Key] = [string]$it.C2; $it.Tag = 'versione saltata'; $it.TagKind = 'warn'; Set-It $it 'skip' "Versione $($it.C2) saltata"; $sync.Done++ }
    Save-Json 'skipped.json' $sk
} else {
    Invoke-Each $items {
        param($it)
        $r = Invoke-Winget 'upgrade' $it.Key ([string]$it.Data) $it
        $k, $t = Get-WingetResult $r.Code 'Aggiornato'
        Set-It $it $k $t
    } 'Aggiorno'
}
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
$res = Search-WU $sr "IsInstalled=0 and IsHidden=0 and Type='Software'"
foreach ($u in $res.Updates) {
    $kb  = (@($u.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
    $cat = @($u.Categories) | Select-Object -First 1 | ForEach-Object { $_.Name }
    $upg = @($u.Categories | Where-Object { $_.Name -eq 'Upgrades' }).Count -gt 0
    $ui0 = [bool]$u.InstallationBehavior.CanRequestUserInput
    $tag = if ($upg) { 'Nuova versione di Windows' } elseif ($ui0) { 'da Impostazioni' } elseif ($u.MsrcSeverity) { $u.MsrcSeverity } elseif ($u.BrowseOnly) { 'Facoltativo' } else { 'Consigliato' }
    $kind = if ($u.MsrcSeverity -eq 'Critical') { 'err' } elseif ($u.BrowseOnly) { 'none' } else { 'info' }
    $rows.Add((New-Row @{ Name = $u.Title; Sub = ((@($kb, $cat) | Where-Object { $_ }) -join '  ·  '); Key = $u.Identity.UpdateID
        C1 = (Format-Size ([double]$u.MaxDownloadSize)); Tag = $tag; TagKind = $kind; Selected = (-not $u.BrowseOnly -and -not $upg -and -not $ui0); Checkable = (-not $ui0) }))
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
    if (Test-Abort) { return }
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
    $rows.Add((New-Row @{ RawName = $f.Name; Sub = ($det -join '  ·  '); Key = $f.FullName; C1 = $f.Extension.TrimStart('.').ToUpper()
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
$r = Invoke-Hidden (Get-WingetPath) ("search `"$query`" --accept-source-agreements --disable-interactivity") 120
foreach ($t in ConvertFrom-WingetTable $r.Out) {
    $c = $t.Cols
    $src = if ($c.Count -ge 4) { $c[-1] } else { '' }
    $cut = $c[1] -match '…$'
    $rows.Add((New-Row @{ RawName = $c[0]; Sub = $c[1]; Key = $c[1]; C1 = $c[2]; C2 = $(if ($c.Count -ge 5) { $c[3] } else { '' }); Tag = $src; Data = $src
        Checkable = (-not $cut); Status = $(if ($cut) { 'ID troncato' } else { '' }); StatusKind = $(if ($cut) { 'skip' } else { 'none' }) }))
}
$sync.ScanInfo = if ($rows.Count) { "$($rows.Count) risultati per `"$query`"." } else { $null }
'@

$ScanProfiles = @'
foreach ($f in Get-ChildItem $ProfDir -Filter *.json -ErrorAction SilentlyContinue) {
    try { $p = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch {
        $rows.Add((New-Row @{ Name = $f.BaseName; Sub = "File non valido: $($_.Exception.Message)"; Key = $f.FullName; Checkable = $false; Tag = 'errore'; TagKind = 'err' })) | Out-Null; continue
    }
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
        "$((Get-UserCtx).Hive)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
$seen = @{}
$list = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.UninstallString -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName -and $_.ReleaseType -notmatch 'Update|Hotfix' -and $_.DisplayName -ne 'MultiTool' } |
        Sort-Object DisplayName
foreach ($e in $list) {
    if (Test-Abort) { return }
    $k = "$($e.DisplayName)|$($e.DisplayVersion)"
    if ($seen[$k]) { continue }; $seen[$k] = 1
    $msi = ($e.WindowsInstaller -eq 1) -and ($e.PSChildName -match '^\{.+\}$')
    $drvPkg = $e.DisplayName -match '^Windows Driver Package|^Pacchetto driver di Windows'
    $tag = if ($e.NoRemove -eq 1) { 'non rimovibile' } elseif ($drvPkg) { 'pacchetto driver' } elseif ($msi) { 'MSI' } elseif ($e.QuietUninstallString) { 'silenziosa' } else { 'guidata' }
    $rows.Add((New-Row @{ RawName = $e.DisplayName; Sub = [string]$e.Publisher; Key = $e.PSChildName; C1 = [string]$e.DisplayVersion; Checkable = ($e.NoRemove -ne 1)
        TagKind = $(if ($drvPkg) { 'warn' } else { 'none' })
        C2 = $(if ($e.EstimatedSize) { Format-Size ([double]$e.EstimatedSize * 1KB) } else { '' }); Tag = $tag
        Data = @{ Msi = $msi; Quiet = [string]$e.QuietUninstallString; Cmd = [string]$e.UninstallString; Reg = [string]$e.PSPath; Name = [string]$e.DisplayName; Pub = [string]$e.Publisher; Loc = [string]$e.InstallLocation } }))
}
foreach ($a in Get-UserAppx | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -eq 'Store' } | Sort-Object Name) {
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
        Remove-UserAppx ([pscustomobject]@{ PackageFullName = $d.Appx })
        Set-It $it 'ok' 'Disinstallato'; return
    }
    if ($d.Msi) {
        $a = "/x $($it.Key)" + $(if ($silent) { ' /qn /norestart' } else { '' })
        $code = Run-Wait 'msiexec.exe' $a $env:SystemRoot 'Normal'
    } else {
        $cmd = [Environment]::ExpandEnvironmentVariables($(if ($silent -and $d.Quiet) { $d.Quiet } else { $d.Cmd }))
        $f, $a = Split-CommandLine $cmd
        if ($f -match 'msiexec') { $a = $a -replace '(?i)(^|\s)/I(?=\s*\{)', '$1/X'; if ($silent) { $a += ' /qn /norestart' } }
        $dir = $env:SystemRoot
        try { $dir = Split-Path $f -ErrorAction Stop } catch {}
        $code = Run-Wait $f $a $dir 'Normal'
        $it.Status = 'Attendo il disinstallatore…'
        Wait-Uninstallers $t0
    }
    Set-ExitResult $it $code 'Disinstallato'
    if ($it.StatusKind -eq 'ok' -and $d.Reg) { Start-Sleep -Seconds 2; if (Test-Path -LiteralPath $d.Reg) { Set-It $it 'err' 'Ancora installato (disinstallazione annullata?)' } }
    if ($it.StatusKind -eq 'ok' -and $d.Name) { $nl = 0; try { $nl = Add-Leftovers $d } catch {}; if ($nl) { $it.Sub = "Restano $nl residui: premi Residui per eliminarli" } }
} 'Disinstallo'
'@

$ScanStartup = @'
$base = 'Software\Microsoft\Windows\CurrentVersion'
$defs = @(
    @{ Scope = 'Utente';           Reg = "$((Get-UserCtx).Hive)\$base\Run";  Appr = "$((Get-UserCtx).Hive)\$base\Explorer\StartupApproved\Run" }
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
        $cmdl = [Environment]::ExpandEnvironmentVariables([string]$key.GetValue($n))
        $exe0 = (Split-CommandLine $cmdl)[0]
        $miss = $exe0 -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $exe0)
        $rows.Add((New-Row @{ RawName = $n; Sub = $cmdl; C1 = $d.Scope; Key = $n; Data = @{ Appr = $d.Appr; Name = $n }
            Tag = $(if ($miss) { 'file mancante' } elseif ($en) { 'attivo' } else { 'disattivato' }); TagKind = $(if ($miss) { 'err' } elseif ($en) { 'ok' } else { 'warn' }) }))
    }
}
$folders = @(
    @{ Scope = 'Cartella utente'; Dir = (Get-UserCtx).Startup;                       Appr = "$((Get-UserCtx).Hive)\$base\Explorer\StartupApproved\StartupFolder" }
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
try {
    $slow = @{}
    foreach ($ev in Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 101, 102, 103; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 300 -ErrorAction Stop) {
        $dd = @{}; foreach ($x in ([xml]$ev.ToXml()).Event.EventData.Data) { $dd[[string]$x.Name] = [string]$x.'#text' }
        $nm = if ($dd.FriendlyName) { $dd.FriendlyName } else { $dd.Name }
        $ms = 0; [void][int]::TryParse($dd.DegradationTime, [ref]$ms)
        if ($nm -and (-not $slow[$nm] -or $slow[$nm].Ms -lt $ms)) { $slow[$nm] = @{ Ms = $ms; Kind = $ev.Id } }
    }
    foreach ($k in @($slow.Keys | Sort-Object { $slow[$_].Ms } -Descending | Select-Object -First 10)) {
        $kind = switch ($slow[$k].Kind) { 101 { 'programma' } 102 { 'driver' } default { 'servizio' } }
        $rows.Add((New-Row @{ Name = $k; Sub = "Rallenta l'avvio di Windows  ·  $kind"; C1 = 'Rilevato da Windows'; C2 = "+$([math]::Round($slow[$k].Ms / 1000, 1)) s"
            Tag = 'lento'; TagKind = 'err'; Checkable = $false; Glyph = [string][char]0xE916 })) | Out-Null
    }
} catch {}
$boot = ''
try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
    $ms = (([xml]$ev.ToXml()).Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
    if ($ms) { $boot = "  ·  Ultimo avvio di Windows: $([math]::Round([double]$ms / 1000)) secondi" }
} catch {}
$sync.ScanInfo = "$($rows.Count) programmi all'avvio, $on attivi. Seleziona e scegli ATTIVA o DISATTIVA.$boot"
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
    if (Test-Abort) { return }
    $size = Get-TargetSize $t
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
    if ($r.Busy) { Set-It $it 'skip' $r.Why }
    elseif ($r.Why) { Set-It $it 'ok' ("Liberati " + (Format-Size $r.Freed)); $it.Sub = $r.Why }
    else { Set-It $it 'ok' ("Liberati " + (Format-Size $r.Freed)) }
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
            if ($r.Code -eq 0) { Set-It $it 'ok' 'Completato' }
            else {
                $hx = '0x{0:X8}' -f $r.Code
                Set-It $it 'err' $(switch ($hx) { '0x800F081F' { 'File di origine non trovati: serve internet o un''immagine di Windows' } '0x800F0906' { 'Download dei file non riuscito: controlla la connessione' } '0x800F0907' { 'Bloccato dai criteri: DISM non può usare Windows Update' } '0x800F0831' { 'Manca un aggiornamento di base: esegui prima Windows Update' } default { "Errore $hx" } })
            }
        }
        'sfc' {
            $t0 = Get-Date
            $r = Invoke-Live "$env:SystemRoot\System32\sfc.exe" '/scannow' ([Text.Encoding]::Unicode) $cb
            switch (Get-SfcResult $t0) { 'bad' { Set-It $it 'err' 'Non risolti' } 'fixed' { Set-It $it 'ok' 'Riparato' } default { Set-It $it 'ok' 'Nessun problema' } }
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
    $pk = @(Get-UserAppx $b.N)
    if (-not $pk.Count) { continue }
    $rows.Add((New-Row @{ Name = "Rimuovi app: $($b.T)"; Sub = "$($pk[0].Name)  ·  reinstallabile dal Microsoft Store"; Key = $b.N; Data = @{ Kind = 'appx'; T = $b.T }
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
            foreach ($p in @(Get-UserAppx $it.Key)) { Remove-UserAppx $p }
            Set-It $it 'ok' 'Rimossa'
        } else {
            $pk = Get-AppxPackage -AllUsers -Name $it.Key -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pk -and $pk.InstallLocation -and (Test-Path "$($pk.InstallLocation)\AppXManifest.xml")) {
                Add-AppxPackage -DisableDevelopmentMode -Register "$($pk.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
                Set-It $it 'ok' 'Reinstallata'
            } else {
                Start-Process ("ms-windows-store://search/?query=" + [uri]::EscapeDataString(([string]$it.Data.T -replace '\s*\(.*$', '')))
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
                $r = Invoke-Hidden $smi '--query-gpu=name,temperature.gpu,fan.speed,utilization.gpu,clocks.gr,power.draw --format=csv,noheader,nounits' 15
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
            foreach ($b in Get-BloatApps) { foreach ($p in @(Get-UserAppx $b.N)) { $it.Sub = "Rimuovo $($b.T)…"; try { Remove-UserAppx $p; $n++ } catch {} } }
            $it.Sub = "$n app rimosse"; Set-It $it 'ok' "$n rimosse"
        }
        'privacy' { foreach ($t in Get-PrivacyTweaks) { Set-Tweak $t $true }; $it.Sub = "$(@(Get-PrivacyTweaks).Count) impostazioni applicate"; Set-It $it 'ok' 'Applicate' }
        'report' { $f = New-DeliveryReport; Open-Shell $f; $it.Sub = $f; Set-It $it 'ok' 'Creato' }
        'label' { $f = New-PcLabel; Open-Shell $f; $it.Sub = $f; Set-It $it 'ok' 'Creata' }
        default { Invoke-MaintStep $it }
    }
} 'Eseguo'
'@

$ScanBackup = @'
$dest = (Get-Settings).BackupDest
foreach ($f in Get-BackupFolders) {
    if (-not $f.Path -or -not (Test-Path $f.Path)) { continue }
    $sync.Status = "Calcolo: $($f.Name)…"
    $sz = Get-BackupEntrySize $f
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
    $f = Get-BackupFolders | Where-Object { $_.Id -eq $it.Key } | Select-Object -First 1
    $r = Invoke-BackupEntry $f $root
    $it.C2 = Format-Size (Get-DirSize @(Join-Path $root $f.Name))
    if ($r.Suspect) { Set-It $it 'err' 'Sospeso: troppi file modificati insieme (possibile virus)' }
    elseif ($r.Code -lt 8) { Set-It $it 'ok' $(if ($r.Copied -ge 0) { "$($r.Copied) file copiati" } else { 'Completato' }) } else { Set-It $it 'err' "Errore robocopy $($r.Code)" }
} 'Copio'
$sync.LastBackup = (Get-Date).ToString('s')
$sync.BackupSel = @($items | ForEach-Object { $_.Key })
$sync.Extra = "Backup in $root"
'@

$ScanNetwork = @'
$sync.Status = 'Leggo le schede di rete…'
foreach ($n in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') {
    $ip = (Get-NetIPAddress -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    $rows.Add((New-Row @{ Name = $n.Name; Sub = $n.InterfaceDescription; C1 = $ip; C2 = $n.LinkSpeed; Tag = 'connessa'; TagKind = 'ok'; Checkable = $false; Glyph = [string][char]0xE774 }))
}
$wl = (Invoke-Hidden "$env:SystemRoot\System32\netsh.exe" 'wlan show interfaces' 30).Out
$ssid = [regex]::Match($wl, '(?m)^\s*SSID\s*:\s*(.+)$').Groups[1].Value.Trim()
if ($ssid) {
    $sig = [regex]::Match($wl, '(?m)^\s*(Signal|Segnale)\s*:\s*(\d+)%').Groups[2].Value
    $rows.Add((New-Row @{ Name = "Wi-Fi: $ssid"; Sub = 'Qualità del segnale'; C1 = "$sig%"; Tag = $(if ([int]$sig -ge 70) { 'ottimo' } elseif ([int]$sig -ge 45) { 'discreto' } else { 'debole' }); TagKind = $(if ([int]$sig -ge 70) { 'ok' } elseif ([int]$sig -ge 45) { 'warn' } else { 'err' }); Checkable = $false; Glyph = [string][char]0xE701 }))
}
try {
    $pl = (Invoke-Hidden "$env:SystemRoot\System32\netsh.exe" 'wlan show profiles' 30).Out
    $wp = @([regex]::Matches($pl, '(?m)^\s+[^:\r\n]*(?:Profile|Profilo)[^:\r\n]*:\s*(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 30)
    foreach ($w in $wp) {
        $k = [regex]::Match((Invoke-Hidden "$env:SystemRoot\System32\netsh.exe" "wlan show profile name=`"$w`" key=clear" 15).Out, '(?m)^\s*(?:Key Content|Contenuto chiave)\s*:\s*(.+?)\s*$').Groups[1].Value
        $rows.Add((New-Row @{ Name = "Wi-Fi salvata: $w"; Sub = 'Password della rete salvata su questo PC'; C1 = $(if ($k) { $k } else { 'senza password' }); Checkable = $false; Glyph = [string][char]0xE701 })) | Out-Null
    }
} catch {}
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
        try { [void](Invoke-Hidden "$env:SystemRoot\System32\$($c[0])" $c[1] 120) } catch {}
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
$tpav = @(Get-SecProducts 'AntiVirusProduct')
if ($tpav.Count) { Chk 'Antivirus' ([string]$tpav[0].displayName) 'attivo' 'ok' '' }
else { try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Chk 'Protezione in tempo reale' 'Microsoft Defender' $(if ($mp.RealTimeProtectionEnabled) { 'attiva' } else { 'disattiva' }) $(if ($mp.RealTimeProtectionEnabled) { 'ok' } else { 'err' }) 'rtp'
    Chk 'Firme antivirus' "Aggiornate il $($mp.AntivirusSignatureLastUpdated.ToString('dd/MM/yyyy'))" "$($mp.AntivirusSignatureAge) giorni" $(if ($mp.AntivirusSignatureAge -le 3) { 'ok' } else { 'warn' }) 'sig'
    $qa = if ($mp.QuickScanAge -lt 1000) { "$($mp.QuickScanAge) giorni fa" } else { 'mai' }
    Chk 'Ultima scansione rapida' 'Defender' $qa $(if ($mp.QuickScanAge -le 7) { 'ok' } else { 'warn' }) 'scan'
} catch { Chk 'Antivirus' 'Defender non attivo: probabilmente c''è un antivirus di terze parti' 'n.d.' 'warn' '' } }
$sync.Status = 'Firewall…'
$tpfw = @(Get-SecProducts 'FirewallProduct')
if ($tpfw.Count) { Chk 'Firewall' ([string]$tpfw[0].displayName) 'attivo' 'ok' '' }
else {
    foreach ($f in Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
        Chk "Firewall · profilo $($f.Name)" 'Windows Defender Firewall' $(if ($f.Enabled) { 'attivo' } else { 'disattivo' }) $(if ($f.Enabled) { 'ok' } else { 'err' }) 'fw'
    }
}
$ss = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -ErrorAction SilentlyContinue).SmartScreenEnabled
$ssp = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -ErrorAction SilentlyContinue).EnableSmartScreen
$ssOff = ($ss -eq 'Off') -or ($ssp -eq 0)
Chk 'SmartScreen' 'Avvisa prima di aprire programmi e file sconosciuti' $(if ($ssOff) { 'disattivo' } else { 'attivo' }) $(if ($ssOff) { 'warn' } else { 'ok' }) 'smartscreen'
try {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
    $hvci = @($dg.SecurityServicesRunning) -contains 2
    Chk 'Isolamento core (integrità della memoria)' 'Protegge il kernel da driver e codice malevolo  ·  si attiva da Sicurezza di Windows' $(if ($hvci) { 'attivo' } else { 'disattivo' }) $(if ($hvci) { 'ok' } else { 'warn' }) ''
} catch {}
$pol = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
$lua = $pol.EnableLUA; $never = ($lua -ne 0) -and ($pol.ConsentPromptBehaviorAdmin -eq 0)
Chk 'Controllo account utente (UAC)' 'Chiede conferma prima delle modifiche di sistema' $(if ($lua -eq 0) { 'disattivo' } elseif ($never) { 'non avvisa mai' } else { 'attivo' }) $(if ($lua -eq 0) { 'err' } elseif ($never) { 'warn' } else { 'ok' }) 'uac'
$sbv = 'n.d.'; $sbk = 'warn'
try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { $sbv = 'attivo'; $sbk = 'ok' } else { $sbv = 'disattivo' } } catch { $sbv = 'non supportato' }
Chk 'Secure Boot' 'Si attiva dal firmware UEFI' $sbv $sbk ''
try { $t = Get-Tpm -ErrorAction Stop; Chk 'Chip di sicurezza TPM' 'Necessario per BitLocker e Windows 11' $(if ($t.TpmReady) { 'pronto' } elseif ($t.TpmPresent) { 'presente' } else { 'assente' }) $(if ($t.TpmReady) { 'ok' } else { 'warn' }) '' } catch {}
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    Chk "Crittografia disco $env:SystemDrive" 'BitLocker / crittografia dispositivo' $(if ($bl.ProtectionStatus -eq 'On') { 'attiva' } else { 'non attiva' }) $(if ($bl.ProtectionStatus -eq 'On') { 'ok' } else { 'warn' }) ''
} catch {}
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
        'uac'     {
            $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            if ((Get-ItemProperty $k).EnableLUA -eq 0) { Set-ItemProperty $k -Name EnableLUA -Value 1 -Type DWord; $sync.Reboot = $true }
            Set-ItemProperty $k -Name ConsentPromptBehaviorAdmin -Value 5 -Type DWord; Set-ItemProperty $k -Name PromptOnSecureDesktop -Value 1 -Type DWord
        }
        'admin'   { Get-LocalUser | Where-Object { $_.SID -like '*-500' } | Disable-LocalUser -ErrorAction Stop }
        'smb1'    { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null; $sync.Reboot = $true }
        'rdp'     { Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1 -Type DWord }
        'smartscreen' {
            Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -Value 'Warn' -Type String
            Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -ErrorAction SilentlyContinue
        }
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
if (@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Where-Object { $_.BatteryStatus -eq 1 }).Count) { throw 'Collega l''alimentatore: i test di Windows non funzionano a batteria' }
$res = @{}
$prev = Read-Json 'bench.json' $null
if ($prev) { foreach ($p in $prev.PSObject.Properties) { $res[$p.Name] = $p.Value } }
Invoke-Each $items {
    param($it)
    $r = Invoke-Hidden "$env:SystemRoot\System32\winsat.exe" ([string]$it.Data) 600
    $m = [regex]::Matches($r.Out, '([\d\.,]+)\s*MB/s')
    if (-not $m.Count) { Set-It $it 'err' 'Nessun risultato'; return }
    $v = ConvertTo-Num $m[$m.Count - 1].Groups[1].Value
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


$ScanServices = @'
$sync.Status = 'Leggo i servizi…'
$changed = @{}; $j = Read-Json 'services-backup.json' $null
if ($j) { foreach ($p in $j.PSObject.Properties) { $changed[$p.Name] = 1 } }
$win = "$env:SystemRoot\".ToLower()
foreach ($sv in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Sort-Object DisplayName) {
    $path = [Environment]::ExpandEnvironmentVariables([string]$sv.PathName) -replace '^\\SystemRoot\\', "$env:SystemRoot\"
    $exe = if ($path -match '^"([^"]+)"') { $Matches[1] } else { ($path -split ' -| /')[0].Trim() }
    if (-not $exe -or $exe.ToLower().StartsWith($win)) { continue }
    $co = ''
    try { $co = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).CompanyName } catch {}
    if ($co -match '^Microsoft') { continue }
    if (Test-Abort) { return }
    $mode = switch ($sv.StartMode) { 'Auto' { 'automatico' } 'Manual' { 'manuale' } 'Disabled' { 'disattivato' } default { [string]$sv.StartMode } }
    $ess = "$($sv.DisplayName) $co $exe" -match 'antivirus|anti-virus|security|defender|eset|kaspersky|bitdefender|norton|avast|avg|sophos|malwarebytes|trend micro|mcafee|audio|realtek|waves|dolby|nahimic|bluetooth|synaptics|elan|touchpad|precision|intel.*(management|graphics|dynamic|thunderbolt|rapid|optane)|nvidia display|amd (external|crash|user)|wlan|wi-?fi|killer|vpn|openvpn|wireguard|backup|veeam|printer|spooler|tpm|biometric|fingerprint|vmware|virtualbox|hyper-v|docker'
    $rows.Add((New-Row @{ RawName = $sv.DisplayName; Sub = "$(if ($co) { "$co  ·  " })$exe"; Key = $sv.Name; C1 = $mode
        C2 = $(if ($sv.State -eq 'Running') { 'in esecuzione' } else { 'fermo' }); Checkable = (-not $ess -or [bool]$changed[$sv.Name])
        Tag = $(if ($changed[$sv.Name]) { 'modificato' } elseif ($ess) { 'essenziale' } else { $mode })
        TagKind = $(if ($changed[$sv.Name]) { 'warn' } else { switch ($sv.StartMode) { 'Auto' { 'info' } 'Disabled' { 'warn' } default { 'none' } } }) })) | Out-Null
}
$sync.ScanInfo = "$($rows.Count) servizi di programmi non Microsoft. Impostarli su MANUALE alleggerisce l'avvio: partono solo quando servono. RIPRISTINA li riporta com'erano."
'@

$ActServices = @'
$bk = @{}; $j = Read-Json 'services-backup.json' $null
if ($j) { foreach ($p in $j.PSObject.Properties) { $bk[$p.Name] = $p.Value } }
Invoke-Each $items {
    param($it)
    $rk = "HKLM:\SYSTEM\CurrentControlSet\Services\$($it.Key)"
    if ($op -in 'manual', 'auto') {
        if (-not $bk.ContainsKey($it.Key)) { $cur = Get-ItemProperty $rk -ErrorAction Stop; $bk[$it.Key] = @{ Start = [int]$cur.Start; Delayed = [int]$cur.DelayedAutostart } }
        Set-Service -Name $it.Key -StartupType $(if ($op -eq 'manual') { 'Manual' } else { 'Automatic' }) -ErrorAction Stop
        $it.C1 = $(if ($op -eq 'manual') { 'manuale' } else { 'automatico' }); $it.Tag = 'modificato'; $it.TagKind = 'warn'
        Set-It $it 'ok' $(if ($op -eq 'manual') { 'Impostato su manuale' } else { 'Impostato su automatico' })
    } else {
        $b = $bk[$it.Key]
        if (-not $b) { Set-It $it 'skip' 'Nessuna modifica da ripristinare'; return }
        Set-ItemProperty $rk -Name Start -Value ([int]$b.Start) -Type DWord -ErrorAction Stop
        if ([int]$b.Delayed) { Set-ItemProperty $rk -Name DelayedAutostart -Value 1 -Type DWord } else { Remove-ItemProperty $rk -Name DelayedAutostart -ErrorAction SilentlyContinue }
        $bk.Remove($it.Key)
        $it.C1 = $(switch ([int]$b.Start) { 2 { 'automatico' } 3 { 'manuale' } 4 { 'disattivato' } default { 'sistema' } }); $it.Tag = $it.C1; $it.TagKind = 'none'
        Set-It $it 'ok' 'Ripristinato'
    }
} $(if ($op -in 'manual', 'auto') { 'Imposto' } else { 'Ripristino' })
Save-Json 'services-backup.json' $bk
'@

$ScanProcesses = @'
$sync.Status = 'Misuro l''uso di CPU e memoria…'
$crit = 'Idle', 'System', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'svchost', 'dwm', 'fontdrvhost', 'Memory Compression', 'MsMpEng', 'SecurityHealthService', 'spoolsv', 'audiodg', 'sihost', 'ctfmon', 'explorer', 'MultiTool', 'winlogon', 'LsaIso', 'SgrmBroker'
$a = @{}; foreach ($p in Get-Process -ErrorAction SilentlyContinue) { try { $a[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch {} }
Start-Sleep -Milliseconds 1000
$cores = [Environment]::ProcessorCount
$list = foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
    $cpu = 0; try { if ($a.ContainsKey($p.Id)) { $cpu = ($p.TotalProcessorTime.TotalMilliseconds - $a[$p.Id]) / 10 / $cores } } catch {}
    [pscustomobject]@{ P = $p; Cpu = [math]::Max(0, $cpu); Ram = $p.WorkingSet64 }
}
foreach ($x in $list | Sort-Object Ram -Descending | Select-Object -First 80) {
    $p = $x.P; $desc = ''; $path = ''
    try { $path = $p.Path; $desc = $p.MainModule.FileVersionInfo.FileDescription } catch {}
    $isCrit = ($crit -contains $p.ProcessName) -or $p.Id -eq $PID -or $p.SessionId -eq 0
    $rows.Add((New-Row @{ Name = $(if ($desc) { "$desc ($($p.ProcessName))" } else { $p.ProcessName }); Sub = $(if ($path) { $path } else { "PID $($p.Id)" })
        Key = [string]$p.Id; C1 = (Format-Size $x.Ram); C2 = ('{0:N1} %' -f $x.Cpu); Checkable = (-not $isCrit)
        Tag = $(if ($isCrit) { 'sistema' } elseif ($x.Cpu -ge 25) { 'CPU alta' } elseif ($x.Ram -ge 1GB) { 'RAM alta' } else { '' })
        TagKind = $(if ($isCrit) { 'none' } else { 'warn' }) })) | Out-Null
}
$sync.ScanInfo = 'Gli 80 processi che usano più memoria. Quelli di sistema non si possono terminare. Le modifiche non salvate nei programmi terminati vanno perse.'
'@

$ActProcesses = @'
Invoke-Each $items { param($it) Stop-Process -Id ([int]$it.Key) -Force -ErrorAction Stop; Set-It $it 'ok' 'Terminato' } 'Termino'
'@

$ScanBigFiles = @'
$root = if ($all) { "$env:SystemDrive\" } else { (Get-UserCtx).Prof }
$skip = "$env:SystemRoot".ToLower()
$sync.Status = "Cerco i file più grandi in $root… (può richiedere qualche minuto)"
$big = New-Object System.Collections.Generic.List[object]
$n = 0; $script:n = 0
$skipDirs = $skip, "$env:SystemDrive\`$recycle.bin", "$env:SystemDrive\system volume information", "$env:SystemDrive\recovery"
$tops = @(Get-ChildItem $root -Force -ErrorAction SilentlyContinue | Where-Object { $skipDirs -notcontains $_.FullName.ToLower() })
$gen = { foreach ($t in $tops) { if (-not $t.PSIsContainer) { $t } elseif (-not ($t.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Get-ChildItem $t.FullName -Recurse -File -Force -ErrorAction SilentlyContinue } } }
& $gen | ForEach-Object {
    $script:n++; if ($script:n % 5000 -eq 0) { $sync.Status = "Analizzati $($script:n) file…"; if (Test-Abort) { throw 'Ricerca interrotta' } }
    if ($_.Length -lt 100MB) { return }
    if (([int64]$_.Attributes -band 0x441000) -or $_.Name -in 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys') { return }
    $big.Add($_)
}
$n = $script:n
foreach ($f in $big | Sort-Object Length -Descending | Select-Object -First 100) {
    $rows.Add((New-Row @{ RawName = $f.Name; Sub = $f.DirectoryName; Key = $f.FullName; C1 = (Format-Size $f.Length); C2 = $f.LastWriteTime.ToString('dd/MM/yyyy')
        Tag = $(if ($f.LastWriteTime -lt (Get-Date).AddYears(-1)) { 'non modificato da 1 anno' } else { '' }); TagKind = 'warn' })) | Out-Null
}
$sync.ScanInfo = "$($rows.Count) file oltre 100 MB su $n analizzati in $root. Quelli eliminati vanno nel Cestino."
'@

$ActBigFiles = @'
Add-Type -AssemblyName Microsoft.VisualBasic
Invoke-Each $items {
    param($it)
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($it.Key, 'OnlyErrorDialogs', 'SendToRecycleBin')
    Set-It $it 'ok' 'Nel Cestino'
} 'Sposto nel Cestino'
'@

$ScanEvents = @'
$since = (Get-Date).AddDays(-7)
$sync.Status = 'Leggo il registro eventi di sistema…'
$nBsod = 0; $nPow = 0; $nApp = 0; $nErr = 0
$sys = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 1000 -ErrorAction SilentlyContinue)
foreach ($g in $sys | Group-Object ProviderName, Id | Sort-Object Count -Descending) {
    if (Test-Abort) { return }
    $e = $g.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
    $msg = (([string]$e.Message) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + '…' }
    $tag = 'errore'; $kind = 'warn'
    if ($e.ProviderName -match 'WER-SystemErrorReporting|BugCheck') { $tag = 'schermata blu'; $kind = 'err'; $nBsod += $g.Count }
    elseif ($e.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $e.Id -eq 41) { $tag = 'spegnimento anomalo'; $kind = 'err'; $nPow += $g.Count }
    elseif ($e.Level -eq 1) { $tag = 'critico'; $kind = 'err' }
    $nErr += $g.Count
    $rows.Add((New-Row @{ Name = "$($e.ProviderName -replace '^Microsoft-Windows-', '') (ID $($e.Id))"; Sub = $msg; C1 = "$($g.Count) volte"
        C2 = $e.TimeCreated.ToString('dd/MM HH:mm'); Tag = $tag; TagKind = $kind; Checkable = $false; Glyph = [string][char]0xE7BA })) | Out-Null
}
try {
    foreach ($e in Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'; StartTime = (Get-Date).AddDays(-60) } -MaxEvents 5 -ErrorAction Stop) {
        if ($e.Id -notin 1101, 1102, 1201, 1202) { continue }
        $okm = $e.Id -in 1101, 1201
        $rows.Add((New-Row @{ Name = 'Test della memoria RAM'; Sub = $(if ($okm) { 'Nessun errore rilevato' } else { 'Rilevati errori: la RAM potrebbe essere difettosa' }); C1 = 'esito'
            C2 = $e.TimeCreated.ToString('dd/MM HH:mm'); Tag = $(if ($okm) { 'ok' } else { 'RAM difettosa' }); TagKind = $(if ($okm) { 'ok' } else { 'err' }); Checkable = $false; Glyph = [string][char]0xE964 })) | Out-Null
    }
} catch {}
$sync.Status = 'Leggo gli arresti anomali dei programmi…'
$apps = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -MaxEvents 300 -ErrorAction SilentlyContinue)
foreach ($g in $apps | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending) {
    $e = $g.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
    $nApp += $g.Count
    $rows.Add((New-Row @{ Name = "Arresto anomalo: $($g.Name)"; Sub = "Modulo: $($e.Properties[3].Value)"; C1 = "$($g.Count) volte"
        C2 = $e.TimeCreated.ToString('dd/MM HH:mm'); Tag = 'programma'; TagKind = 'warn'; Checkable = $false; Glyph = [string][char]0xE7BA })) | Out-Null
}
$sync.ScanInfo = "Ultimi 7 giorni: $nErr errori di sistema  ·  $nBsod schermate blu  ·  $nPow spegnimenti anomali  ·  $nApp arresti di programmi"
'@

$ScanPacks = @'
$sync.Status = 'Controllo i programmi già installati…'
$have = ''
try { $have = (Invoke-Hidden (Get-WingetPath) 'list --accept-source-agreements --disable-interactivity' 180).Out } catch {}
$packs = @(
    @('Browser', 'Google.Chrome', 'Google Chrome'), @('Browser', 'Mozilla.Firefox', 'Mozilla Firefox'), @('Browser', 'Brave.Brave', 'Brave')
    @('Ufficio', 'TheDocumentFoundation.LibreOffice', 'LibreOffice'), @('Ufficio', 'Adobe.Acrobat.Reader.64-bit', 'Adobe Acrobat Reader'), @('Ufficio', 'SumatraPDF.SumatraPDF', 'SumatraPDF')
    @('Ufficio', 'Notepad++.Notepad++', 'Notepad++'), @('Multimedia', 'VideoLAN.VLC', 'VLC'), @('Multimedia', 'Spotify.Spotify', 'Spotify')
    @('Multimedia', 'IrfanSkiljan.IrfanView', 'IrfanView'), @('Multimedia', 'Audacity.Audacity', 'Audacity'), @('Multimedia', 'OBSProject.OBSStudio', 'OBS Studio')
    @('Comunicazione', 'Zoom.Zoom', 'Zoom'), @('Comunicazione', 'Telegram.TelegramDesktop', 'Telegram'), @('Comunicazione', 'Discord.Discord', 'Discord')
    @('Utilità', '7zip.7zip', '7-Zip'), @('Utilità', 'Microsoft.PowerToys', 'PowerToys'), @('Utilità', 'Rufus.Rufus', 'Rufus')
    @('Utilità', 'CrystalDewWorld.CrystalDiskInfo', 'CrystalDiskInfo'), @('Utilità', 'CPUID.CPU-Z', 'CPU-Z'), @('Utilità', 'REALiX.HWiNFO', 'HWiNFO')
    @('Sicurezza', 'Malwarebytes.Malwarebytes', 'Malwarebytes'), @('Sicurezza', 'KeePassXCTeam.KeePassXC', 'KeePassXC'), @('Sicurezza', 'Bitwarden.Bitwarden', 'Bitwarden')
    @('Assistenza remota', 'RustDesk.RustDesk', 'RustDesk'), @('Assistenza remota', 'AnyDesk.AnyDesk', 'AnyDesk'), @('Assistenza remota', 'TeamViewer.TeamViewer', 'TeamViewer')
    @('Componenti', 'Microsoft.VCRedist.2015+.x64', 'Visual C++ 2015-2022 (x64)'), @('Componenti', 'Microsoft.DotNet.DesktopRuntime.8', '.NET Desktop Runtime 8'), @('Componenti', 'Oracle.JavaRuntimeEnvironment', 'Java')
    @('Giochi', 'Valve.Steam', 'Steam'), @('Giochi', 'EpicGames.EpicGamesLauncher', 'Epic Games Launcher')
)
foreach ($p in $packs) {
    $inst = $have -and $have.IndexOf($p[1], [StringComparison]::OrdinalIgnoreCase) -ge 0
    $rows.Add((New-Row @{ Name = $p[2]; Sub = $p[1]; Key = $p[1]; C1 = $p[0]; Data = 'winget'; Tag = $(if ($inst) { 'installato' } else { '' }); TagKind = $(if ($inst) { 'ok' } else { 'none' })
        Selected = $false; Glyph = [string][char]0xE7B8 })) | Out-Null
}
$sync.ScanInfo = 'Spunta i programmi da installare e premi INSTALLA: vengono scaricati dai siti ufficiali tramite winget.'
'@

$ScanLeftovers = @'
foreach ($x in @(Read-Json 'leftovers.json' @()) | Where-Object { $_ }) {
    if (-not (Test-Path -LiteralPath $x.P)) { continue }
    $isDir = $x.T -eq 'dir'
    $rows.Add((New-Row @{ RawName = $x.P; Sub = "Residuo di $($x.App)"; Key = $x.P; Data = $x.T; C1 = $(if ($isDir) { 'cartella' } else { 'registro' })
        C2 = $(if ($isDir) { Format-Size (Get-DirSize @($x.P)) } else { '' }); Selected = $true; Glyph = [string][char]$(if ($isDir) { 0xE8B7 } else { 0xE74C }) })) | Out-Null
}
$sync.ScanInfo = 'Cartelle e chiavi di registro rimaste dopo le disinstallazioni. Le cartelle vanno nel Cestino, le chiavi vengono salvate in Dati\Residui prima di eliminarle.'
'@

$ActLeftovers = @'
Add-Type -AssemblyName Microsoft.VisualBasic
$bk = Join-Path $DataDir 'Residui'; New-Item -ItemType Directory $bk -Force | Out-Null
Invoke-Each $items {
    param($it)
    if ($it.Data -eq 'dir') { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($it.Key, 'OnlyErrorDialogs', 'SendToRecycleBin') }
    else {
        $native = $it.Key -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU' -replace '^Registry::HKEY_USERS', 'HKU'
        $f = Join-Path $bk (($it.Key -replace '[^\w]+', '_') + '.reg')
        [void](Invoke-Hidden "$env:SystemRoot\System32\reg.exe" "export `"$native`" `"$f`" /y" 30)
        Remove-Item -LiteralPath $it.Key -Recurse -Force -ErrorAction Stop
    }
    Set-It $it 'ok' 'Eliminato'
} 'Elimino'
$left = @(@(Read-Json 'leftovers.json' @()) | Where-Object { $_ -and (Test-Path -LiteralPath $_.P) })
Save-Json 'leftovers.json' $left
'@

$ScanLan = @'
$sync.Status = 'Cerco i dispositivi nella rete locale…'
$cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
if (-not $cfg) { throw 'Nessuna rete locale connessa' }
$myIp = @($cfg.IPv4Address)[0].IPAddress; $gw = @($cfg.IPv4DefaultGateway)[0].NextHop
$base = ($myIp -split '\.')[0..2] -join '.'
$pings = @{}
foreach ($i in 1..254) { $a = "$base.$i"; try { $pings[$a] = (New-Object Net.NetworkInformation.Ping).SendPingAsync($a, 900) } catch {} }
try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($pings.Values), 4000) } catch {}
if (Test-Abort) { return }
$found = @{}
foreach ($a in $pings.Keys) { $t = $pings[$a]; if ($t.Status -eq 'RanToCompletion' -and $t.Result.Status -eq 'Success') { $found[$a] = @{ Ms = $t.Result.RoundtripTime; Mac = '' } } }
foreach ($n in Get-NetNeighbor -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
    if ($n.IPAddress -notlike "$base.*" -or $n.LinkLayerAddress -match '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF)$' -or -not $n.LinkLayerAddress -or [string]$n.State -eq 'Unreachable') { continue }
    if (-not $found[$n.IPAddress]) { $found[$n.IPAddress] = @{ Ms = $null; Mac = '' } }
    $found[$n.IPAddress].Mac = $n.LinkLayerAddress
}
$found[$myIp] = @{ Ms = 0; Mac = (($cfg.NetAdapter.MacAddress) -replace ':', '-') }
$sync.Status = 'Leggo i nomi dei dispositivi…'
$names = @{}
foreach ($a in $found.Keys) { try { $names[$a] = [Net.Dns]::GetHostEntryAsync($a) } catch {} }
try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($names.Values), 4000) } catch {}
foreach ($a in $found.Keys | Sort-Object { [int](($_ -split '\.')[3]) }) {
    $hn = ''; $t = $names[$a]; if ($t -and $t.Status -eq 'RanToCompletion') { $hn = $t.Result.HostName }
    $tag = if ($a -eq $myIp) { 'questo PC' } elseif ($a -eq $gw) { 'router' } else { '' }
    $rows.Add((New-Row @{ Name = $(if ($hn -and $hn -ne $a) { $hn } else { $a }); Sub = $(if ($found[$a].Mac) { "MAC $($found[$a].Mac)" } else { '' }); C1 = $a
        C2 = $(if ($null -ne $found[$a].Ms) { "$($found[$a].Ms) ms" } else { 'non risponde al ping' }); Tag = $tag; TagKind = $(if ($tag) { 'info' } else { 'none' })
        Checkable = $false; Glyph = [string][char]$(if ($tag -eq 'router') { 0xE968 } elseif ($tag) { 0xE7F8 } else { 0xE839 }) })) | Out-Null
}
$sync.ScanInfo = "$($rows.Count) dispositivi trovati in $base.0/24."
'@

$ScanSpace = @'
$root = if ($path) { $path } else { "$env:SystemDrive\" }
$sync.Status = "Calcolo lo spazio in $root…"
$list = New-Object System.Collections.ArrayList
foreach ($x in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
    if (Test-Abort) { return }
    $sync.Status = "Calcolo: $($x.Name)…"
    $sz = if ($x.PSIsContainer) { if ($x.Attributes -band [IO.FileAttributes]::ReparsePoint) { 0 } else { (Get-ChildItem -LiteralPath $x.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { -not ([int64]$_.Attributes -band 0x441000) } | Measure-Object Length -Sum).Sum } } else { $x.Length }
    [void]$list.Add([pscustomobject]@{ I = $x; S = [double]$sz })
}
$tot = [double]($list | Measure-Object S -Sum).Sum
foreach ($e in $list | Sort-Object S -Descending | Select-Object -First 60) {
    $pct = if ($tot) { $e.S / $tot } else { 0 }
    $bar = ([string][char]0x2588 * [int][math]::Round($pct * 14)).PadRight(14, [char]0x2591)
    $rows.Add((New-Row @{ RawName = $e.I.Name; Sub = $e.I.FullName; Key = $e.I.FullName; Data = [bool]$e.I.PSIsContainer; C1 = (Format-Size $e.S); C2 = $bar
        Tag = ('{0:N0}%' -f ($pct * 100)); Glyph = [string][char]$(if ($e.I.PSIsContainer) { 0xE8B7 } else { 0xE7C3 }) })) | Out-Null
}
$sync.ScanInfo = "$root  ·  $(Format-Size $tot) in totale. Seleziona una cartella e premi ENTRA."
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
    $up = (Get-Date) - (Get-RealBootTime)
    $info.Uptime = $(if ([MtTr]::On) { '{0}d {1}h {2}m' } else { '{0}g {1}h {2}m' }) -f $up.Days, $up.Hours, $up.Minutes
    $info.Disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        @{ Name = $_.DeviceID; Label = [string]$_.VolumeName; Size = [double]$_.Size; Free = [double]$_.FreeSpace } })
} catch {}
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $info.DefOk  = [bool]$mp.RealTimeProtectionEnabled
    $info.Def    = if ($info.DefOk) { 'Attiva' } else { 'Disattivata' }
    $info.DefSig = 'Firme del ' + $mp.AntivirusSignatureLastUpdated.ToString('dd/MM/yyyy')
} catch { $info.DefOk = $null; $info.Def = 'Non rilevata'; $info.DefSig = 'Antivirus di terze parti?' }
$tpav = @(Get-SecProducts 'AntiVirusProduct')
if ($tpav.Count) { $info.DefOk = $true; $info.Def = 'Attiva'; $info.DefSig = [string]$tpav[0].displayName }
$info.UpDays = Get-RealUptimeDays
try {
    $info.PD = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
        $rc = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        @{ Name = [string]$_.FriendlyName; Media = [string]$_.MediaType; Bus = [string]$_.BusType; Health = [string]$_.HealthStatus; Size = [double]$_.Size
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
    updates = @{ Nav = 'NavUpdates'; Online = $true; Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' }, @{ T = 'Microsoft Store'; U = 'https://apps.microsoft.com' });  Title = 'Aggiorna programmi'; Glyph = (G 0xE895); Arrow = $true
        Sub = 'Analisi di winget e Microsoft Store…'; H = 'INSTALLATA', 'NUOVA', 'ORIGINE', 'STATO'
        Scan = $ScanUpdates; Action = $ActUpdates; Go = 'PROCEDI'; Go2 = 'SALTA VERSIONE'; Go2Op = 'skipver'; Restore = $true
        X1 = @{ Text = 'Escludi selezionati'; Click = { Add-Exclusions } }
        X2 = @{ Text = 'Ricerca di nuovo'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE73E); Title = 'Tutto aggiornato'; Text = 'winget non ha trovato aggiornamenti disponibili.' } }

    wu = @{ Nav = 'NavWU'; Online = $true; Credits = @(@{ T = 'Windows Update · Microsoft'; U = 'https://support.microsoft.com/windows' });  Title = 'Windows Update'; Glyph = (G 0xE777)
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

    catalog = @{ Nav = 'NavCatalog'; Online = $true; Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' }, @{ T = 'Repository comunitario winget-pkgs'; U = 'https://github.com/microsoft/winget-pkgs' });  Title = 'Catalogo winget'; Glyph = (G 0xE896); Search = $true
        Sub = 'Cerca tra migliaia di programmi e installali senza scaricare nulla a mano.'; H = 'VERSIONE', 'CORRISPONDENZA', 'ORIGINE', 'STATO'
        Scan = $ScanCatalog; Action = $ActWingetInstall; Go = 'INSTALLA'; Restore = $true
        X1 = @{ Text = 'Crea profilo dai selezionati'; Click = { New-ProfileFromSelection } }
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
        X2 = @{ Text = 'Residui'; Click = { Open-Mode 'leftovers' } }
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
        Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' }, @{ T = 'QR: qrcode-generator'; U = 'https://github.com/kazuhikoarase/qrcode-generator' })
        X1 = @{ Text = 'Dati del negozio'; Click = { Stop-AnyScan; $ui.NavSettings.IsChecked = $true; Show-View 'ViewSettings' } }
        X2 = @{ Text = 'Scheda intervento'; Click = { New-JobSheetUi } }
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
        PreCheck = { param($op, $sel)
            if ($op -eq 'speed' -and (Test-Metered) -and [MtTr]::Msg('Sei su una connessione a consumo: il test scarica circa 200 MB. Procedere?', 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return $false }
            if ($op -eq 'repair' -and (Test-RemoteSession) -and [MtTr]::Msg('Sembra che tu stia lavorando da remoto (Desktop remoto, AnyDesk, TeamViewer o RustDesk): riparare la rete ti scollegherà dal PC. Procedere comunque?', 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return $false }
            $true }
        Credits = @(@{ T = 'Test velocità: Cloudflare'; U = 'https://speed.cloudflare.com' }, @{ T = 'IP pubblico: ipify'; U = 'https://www.ipify.org' })
        X1 = @{ Text = 'Ricontrolla'; Click = { Start-Scan } }
        X2 = @{ Text = 'Dispositivi in rete'; Click = { Open-Mode 'lan' } }
        Empty = @{ Glyph = (G 0xE774); Title = 'Nessuna rete connessa'; Text = 'Collega un cavo o una rete Wi-Fi.' } }

    security = @{ Nav = 'NavSecurity'; Title = 'Sicurezza'; Glyph = (G 0xEA18); AfterDone = 'rescan'
        PreCheck = { param($op, $sel)
            if (@($sel | Where-Object { [string]$_.Data -eq 'rdp' }).Count -and [Windows.Forms.SystemInformation]::TerminalServerSession -and
                [MtTr]::Msg('Sei collegato tramite Desktop remoto: disattivarlo impedirà le prossime connessioni remote. Procedere?', 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return $false }
            $true }
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

    services = @{ Nav = 'NavServices'; Title = 'Servizi'; Glyph = (G 0xE912); AfterDone = 'review'
        Sub = 'Lettura dei servizi…'; H = 'AVVIO', 'STATO', '', 'ESITO'; Scan = $ScanServices; Action = $ActServices; Restore = $true
        Go = 'IMPOSTA MANUALE'; GoOp = 'manual'; Go2 = 'RIPRISTINA'; Go2Op = 'restore'
        ConfirmOp = @{ manual = 'I servizi selezionati partiranno solo quando servono. Se un programma smette di funzionare, rimettilo su AUTOMATICO. Procedere?' }
        X1 = @{ Text = 'Imposta automatico'; Click = { if ($sync.Phase -eq 'review') { Start-Action 'auto' } } }
        X2 = @{ Text = 'Servizi di Windows'; Click = { Start-Process services.msc } }
        Empty = @{ Glyph = (G 0xE912); Title = 'Nessun servizio di terze parti'; Text = '' } }

    processes = @{ Nav = 'NavProcesses'; Title = 'Processi'; Glyph = (G 0xE9D9); AfterDone = 'rescan'
        Sub = 'Misuro l''uso di CPU e memoria…'; H = 'MEMORIA', 'CPU', '', 'ESITO'; Scan = $ScanProcesses; Action = $ActProcesses; Go = 'TERMINA'
        Confirm = 'Terminare {0} processi? Le modifiche non salvate in quei programmi andranno perse.'
        X1 = @{ Text = 'Gestione attività'; Click = { Start-Process taskmgr.exe } }
        X2 = @{ Text = 'Aggiorna'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE9D9); Title = ''; Text = '' } }

    bigfiles = @{ Nav = 'NavBigFiles'; Title = 'File grandi'; Glyph = (G 0xE8B7); AfterDone = 'review'
        Sub = 'Ricerca dei file più grandi…'; H = 'DIMENSIONE', 'MODIFICATO', '', 'ESITO'; Scan = $ScanBigFiles; Action = $ActBigFiles; Go = 'SPOSTA NEL CESTINO'
        Confirm = 'Spostare {0} file nel Cestino? Potrai recuperarli finché non svuoti il Cestino.'
        PreCheck = { param($op, $sel) if ((Get-UserCtx).Other) { [MtTr]::Msg("Stai usando l'account amministratore $env:USERNAME: i file finiranno nel suo Cestino, non in quello di $((Get-UserCtx).Name). Per recuperarli dovrai accedere con $env:USERNAME. Continuare?", 'MultiTool', 'YesNo', 'Warning') -eq 'Yes' } else { $true } }
        X1 = @{ Text = 'Apri percorso'; Click = { $s = @($Items | Where-Object Selected | Select-Object -First 1); if ($s) { Start-Process explorer.exe "/select,`"$($s[0].Key)`"" } else { Toast 'Seleziona prima un file' } } }
        X2 = @{ Text = 'Cerca in tutto il disco'; Click = { $State.Vars = @{ all = $true }; Start-Scan } }
        Empty = @{ Glyph = (G 0xE8B7); Title = 'Nessun file oltre 100 MB'; Text = '' } }

    events = @{ Nav = 'NavEvents'; Title = 'Eventi di sistema'; Glyph = (G 0xE7BA); Checks = $false
        Sub = 'Lettura del registro eventi…'; H = 'QUANTE VOLTE', 'ULTIMA', 'TIPO', ''; Scan = $ScanEvents
        X1 = @{ Text = 'Visualizzatore eventi'; Click = { Start-Process eventvwr.msc } }
        X2 = @{ Text = 'Affidabilità'; Click = { Start-Process perfmon.exe '/rel' } }
        Empty = @{ Glyph = (G 0xE73E); Title = 'Nessun errore negli ultimi 7 giorni'; Text = 'Windows non ha registrato errori critici, schermate blu o arresti anomali.' } }

    packs = @{ Nav = 'NavPacks'; Online = $true; Title = 'Pacchetti consigliati'; Glyph = (G 0xE7B8); Credits = @(@{ T = 'winget · Microsoft'; U = 'https://github.com/microsoft/winget-cli' })
        Sub = 'Controllo dei programmi installati…'; H = 'CATEGORIA', '', '', 'STATO'; Scan = $ScanPacks; Action = $ActWingetInstall; Go = 'INSTALLA'; Restore = $true
        X1 = @{ Text = 'Crea profilo dai selezionati'; Click = { New-ProfileFromSelection } }
        X2 = @{ Text = 'Ricarica'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE7B8); Title = ''; Text = '' } }

    leftovers = @{ Nav = 'NavUninstall'; Title = 'Residui delle disinstallazioni'; Glyph = (G 0xE74D); AfterDone = 'rescan'
        Sub = 'Lettura dei residui…'; H = 'TIPO', 'DIMENSIONE', '', 'ESITO'; Scan = $ScanLeftovers; Action = $ActLeftovers; Go = 'ELIMINA'
        Confirm = 'Eliminare {0} residui? Le cartelle vanno nel Cestino, le chiavi di registro vengono prima salvate in Dati\Residui.'
        X1 = @{ Text = 'Torna a Disinstalla'; Click = { Open-Mode 'uninstall' } }
        X2 = @{ Text = 'Apri cartella'; Click = { $s = @($Items | Where-Object { $_.Selected -and $_.Data -eq 'dir' } | Select-Object -First 1); if ($s) { Start-Process explorer.exe "`"$($s[0].Key)`"" } else { Toast 'Seleziona prima una cartella' } } }
        Empty = @{ Glyph = (G 0xE73E); Title = 'Nessun residuo'; Text = 'Dopo una disinstallazione MultiTool cerca cartelle e chiavi rimaste e le elenca qui.' } }

    lan = @{ Nav = 'NavNetwork'; Title = 'Dispositivi in rete'; Glyph = (G 0xE839); Checks = $false
        Sub = 'Ricerca dei dispositivi…'; H = 'INDIRIZZO IP', 'RISPOSTA', '', ''; Scan = $ScanLan
        X1 = @{ Text = 'Torna a Rete'; Click = { Open-Mode 'network' } }
        X2 = @{ Text = 'Ricerca di nuovo'; Click = { Start-Scan } }
        Empty = @{ Glyph = (G 0xE839); Title = 'Nessun dispositivo trovato'; Text = '' } }

    space = @{ Nav = 'NavSpace'; Title = 'Spazio disco'; Glyph = (G 0xEDA2); AfterDone = 'review'
        Sub = 'Calcolo dello spazio occupato…'; H = 'DIMENSIONE', 'PROPORZIONE', '%', ''; Scan = $ScanSpace
        X1 = @{ Text = 'Entra'; Click = { $s = @($Items | Where-Object { $_.Selected -and $_.Data -eq $true } | Select-Object -First 1); if ($s) { Open-Mode 'space' @{ path = $s[0].Key } } else { Toast 'Seleziona prima una cartella' } } }
        X2 = @{ Text = 'Livello superiore'; Click = { $cur = if ($State.Vars -and $State.Vars.path) { $State.Vars.path } else { "$env:SystemDrive\" }; $par = Split-Path $cur -Parent; if ($par) { Open-Mode 'space' @{ path = $par } } else { Toast 'Sei già nella cartella principale del disco' } } }
        Empty = @{ Glyph = (G 0xEDA2); Title = 'Cartella vuota'; Text = '' } }

    exclusions = @{ Nav = 'NavSettings'; Title = 'Esclusioni'; Glyph = (G 0xE72E); AfterDone = 'rescan'
        Sub = 'Programmi che non verranno mai aggiornati.'; H = '', '', '', 'STATO'
        Scan = $ScanExclusions; Action = $ActExclusions; Go = 'RIMUOVI ESCLUSIONE'
        Empty = @{ Glyph = (G 0xE72E); Title = 'Nessuna esclusione'; Text = 'In "Aggiorna programmi" seleziona un programma e premi "Escludi selezionati".' } }
}

if ($Settings.Lang -eq 'en') {
    foreach ($m in $Modes.Values) {
        $m.TitleIt = $m.Title
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
    foreach ($n in 'ViewHome', 'ViewList', 'ViewSettings', 'ViewLogs', 'ViewHw', 'ViewAbout') { $ui[$n].Visibility = 'Collapsed' }
    if ($v -ne 'ViewHw' -and -not $State.StressUntil) { $sync.SensOn = $false }
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
    foreach ($c in 'LX1', 'LX2', 'LAll', 'LNone', 'LSilent', 'LSearchBox', 'LCsv') { $ui[$c].IsEnabled = -not $busy }
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
    if ($M.Online -and $sync.Online -eq $false) {
        $Items.Clear(); Reset-Footer; $ui.LGo.Visibility = 'Collapsed'; $ui.LGo2.Visibility = 'Collapsed'
        $sync.Token++; $sync.Phase = 'review'
        Show-Empty @{ Glyph = (G 0xE774); Title = 'Nessuna connessione a internet'; Text = 'Questa sezione ha bisogno di internet. Collegati e premi F5 o Ricarica.' }
        $ui.LSub.Text = 'Nessuna connessione a internet'
        return
    }
    $Items.Clear(); Hide-Empty; Reset-Footer; Reset-Filter; $ui.LReport.Visibility = 'Collapsed'
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
                 'startup', 'services', 'cleanup', 'repair', 'privacy', 'security', 'network', 'events', 'bench', 'restore', 'history'
$PrefetchCode = @'
$realSync = $sync
try { [Threading.Thread]::CurrentThread.Priority = 'BelowNormal' } catch {}
$online = Test-Online
if (-not $online -or (Test-Metered)) { $list = @($list | Where-Object { $_ -notin 'updates', 'wu' }) }
$onBat = $false
try { $onBat = [bool](Get-CimInstance Win32_Battery -ErrorAction Stop | Where-Object { $_.BatteryStatus -eq 1 }) } catch {}
if ($onBat) { $list = @($list | Where-Object { $_ -notin 'cleanup', 'wu', 'events', 'services' }) }
$i = 0
foreach ($m in $list) {
    $i++
    while ($realSync.Phase -eq 'run' -and $realSync.PrefetchGen -eq $pgen) { Start-Sleep -Seconds 2 }
    if ($realSync.PrefetchGen -ne $pgen) { break }
    $realSync.PrefetchStatus = "$i/$($list.Count)"
    $cc = $realSync.Cache[$m]
    if (($cc -and ((Get-Date) - $cc.Time).TotalMinutes -lt 20) -or ($m -eq 'hw' -and $realSync.HwCache)) { continue }
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
$CacheDeps = @{
    updates = 'updates', 'uninstall'; catalog = 'updates', 'uninstall'; import = 'updates', 'uninstall'; profiles = 'updates', 'uninstall'
    installers = 'updates', 'uninstall'; packs = 'updates', 'uninstall'; uninstall = 'uninstall', 'updates', 'startup', 'services'
    wu = 'wu', 'security', 'restore'; cleanup = 'cleanup', 'restore'; full = 'updates', 'uninstall', 'wu', 'cleanup', 'drivers', 'security', 'restore'
    deliver = 'updates', 'uninstall', 'wu', 'cleanup', 'drivers', 'privacy', 'security', 'restore'; privacy = 'privacy', 'uninstall'
    security = 'security'; startup = 'startup'; services = 'services'; backup = 'backup'; restore = 'restore'; bench = 'bench'; repair = 'repair'
}
function Invalidate-Cache([string]$Mode) {
    $list = if ($Mode -and $CacheDeps[$Mode]) { @($CacheDeps[$Mode]) } elseif ($Mode) { @($Mode) } else { [Threading.Monitor]::Enter($sync.Cache.SyncRoot); try { @($sync.Cache.Keys) } finally { [Threading.Monitor]::Exit($sync.Cache.SyncRoot) } }
    foreach ($k in $list + 'history', 'full', 'deliver') { $sync.Cache.Remove($k) }
    if (-not $Mode -or $Mode -in 'full', 'deliver') { $sync.HwCache = $null; $State.HwLoaded = $false }
    Start-Prefetch
}
function Use-Cache([string]$m, $c) {
    $Items.Clear(); Hide-Empty; Reset-Footer; Reset-Filter; $ui.LReport.Visibility = 'Collapsed'
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
        $b.Add_Click({ param($s, $e) Open-Shell $s.Tag })
        [void]$ui.LCredits.Children.Add($b)
    }
    $ui.LCreditsBar.Visibility = Vis (@($M.Credits).Count -gt 0 -and $M.Credits)
    $ck = $M.Checks -ne $false
    $ui.LAll.Visibility = Vis $ck; $ui.LNone.Visibility = Vis $ck
    $ui.LFill.Width = 0; $ui.LReport.Visibility = 'Collapsed'; Reset-Filter
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
    if (-not $noSel -and -not $sel.Count) { Toast $(if ($M.GoFilterMsg) { $M.GoFilterMsg } else { 'Seleziona almeno un elemento' }); return }
    if ($sync.Phase -eq 'run') { return }
    if ($State.Mode -in 'updates', 'wu', 'installers', 'catalog', 'profiles', 'import', 'full', 'deliver', 'packs' -and $op -ne 'skipver') {
        $free = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
        if ($free -lt 5GB -and [MtTr]::Msg("Sul disco $env:SystemDrive restano solo $(Format-Size $free) liberi: aggiornamenti e installazioni potrebbero non riuscire. Conviene prima fare una Pulizia disco.`n`nContinuare comunque?", 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if ($M.PreCheck -and -not (& $M.PreCheck $op $sel)) { return }
    if ($M.ConfirmOp -and $M.ConfirmOp[$op]) {
        if ([MtTr]::Msg($M.ConfirmOp[$op], 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if ($M.Confirm) {
        if ([MtTr]::Msg(($M.Confirm -f $sel.Count), 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    $wk = $false; try { $wk = $WorkMx.WaitOne(0) } catch [Threading.AbandonedMutexException] { $wk = $true }
    if (-not $wk) { Toast 'L''aggiornamento automatico di MultiTool è in corso: riprova tra qualche minuto'; return }
    $State.HoldWork = $true
    foreach ($it in $Items) {
        if ($noSel -or -not $it.Checkable) { continue }
        $it.Editable = $false
        if ($sel -contains $it) { Set-It $it 'wait' 'In coda' } elseif ($it.StatusKind -eq 'none') { Set-It $it 'skip' 'Saltato' }
    }
    $sync.Total = [Math]::Max(1, $sel.Count); $sync.Done = 0; $sync.Cancel = $false; $sync.Extra = ''; $sync.ExtraRows = $null
    $sync.Status = 'Operazione in corso…'; $sync.Phase = 'run'
    $ui.LGo.IsEnabled = $false; $ui.LGo2.IsEnabled = $false
    $ui.LCancel.Content = T 'ANNULLA'; $ui.LCancel.IsEnabled = $true
    Set-Busy $true
    [void][NativePow.Power]::SetThreadExecutionState(0x80000001)
    $restore = [bool]$M.Restore -and [bool]$Settings.Restore -and $op -notin 'web', 'restore', 'enable', 'skipver'
    $code = @'
if ($restore) {
    $sync.Status = 'Creo un punto di ripristino…'
    if (New-RestorePoint "MultiTool - $area") { $sync.Toast = 'Punto di ripristino creato' }
    else { $sync.Toast = 'Punto di ripristino non creato (Protezione sistema disattivata?)' }
}
try {
'@ + "`n" + $M.Action + "`n" + @'
} catch { $sync.Extra = 'Errore: ' + $_.Exception.Message; Write-ErrLog "Azione $area`: $($_.Exception.Message)" }
foreach ($x in @($items)) { if ($x.StatusKind -in 'wait', 'run') { Set-It $x 'skip' 'Non eseguito' } }
$sync.Phase = 'done'
'@
    Start-Bg $code @{ items = $sel; op = $op; silent = [bool]$ui.LSilent.IsChecked; area = $(if ($M.TitleIt) { $M.TitleIt } else { $M.Title }); restore = $restore }
}

function Test-RemoteSession {
    [Windows.Forms.SystemInformation]::TerminalServerSession -or [bool](Get-Process AnyDesk, TeamViewer, rustdesk, RemotePCDesktop, Splashtop* -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId })
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
    $skip = @($coll | Where-Object { $_.StatusKind -eq 'skip' -and $_.Status -in 'Annullato', 'Cancelled' }).Count
    T ("$ok completati" + $(if ($err) { "  ·  $err con errori" } else { '' }) + $(if ($skip) { "  ·  $skip annullati" } else { '' }))
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
        "<TextBlock Grid.Row=`"$i`" Text=`"$(& $E (T $r.L))`" Foreground=`"#9AA0B8`" FontSize=`"13`" Margin=`"0,4,12,4`"/>" +
        "<TextBox Grid.Row=`"$i`" Grid.Column=`"1`" Text=`"$(& $E (T $r.V))`" IsReadOnly=`"True`" BorderThickness=`"0`" Background=`"Transparent`" Foreground=`"#E8EAF2`" FontSize=`"13`" TextWrapping=`"Wrap`" Margin=`"0,4,0,4`" Padding=`"0`"/>"
        $i++
    }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" CornerRadius="18" Background="#12151D" BorderBrush="#1F2434" BorderThickness="1" Padding="22" Margin="6">
  <StackPanel>
    <StackPanel Orientation="Horizontal">
      <Border Width="32" Height="32" CornerRadius="9" Background="#7C5CFF"><TextBlock Text="$(& $E $c.G)" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      <TextBlock Text="$(& $E (T $c.T))" FontSize="17" FontWeight="SemiBold" Foreground="#E8EAF2" Margin="12,0,0,0" VerticalAlignment="Center"/>
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
        "<h2>$(& $E (T $c.T))</h2><table>" + (($c.Rows | ForEach-Object { "<tr><th>$(& $E (T $_.L))</th><td>$(& $E (T $_.V))</td></tr>" }) -join '') + '</table>'
    }
    $html = @"
<!DOCTYPE html><html lang="$(if ([MtTr]::On) { 'en' } else { 'it' })"><head><meta charset="utf-8"><title>$(T 'Inventario hardware') - $env:COMPUTERNAME</title>
<style>body{font-family:Segoe UI,sans-serif;background:#f4f5f9;color:#1b1e27;margin:40px;max-width:1000px}h1{margin:0}h2{font-size:17px;margin:28px 0 8px}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 1px 3px #0001}
th,td{padding:9px 14px;text-align:left;border-bottom:1px solid #eceef4;font-size:14px}th{width:220px;color:#5b6175;font-weight:600}.m{color:#5b6175}</style></head>
<body><h1>$(T 'Inventario hardware')</h1><p class="m">$env:COMPUTERNAME  ·  $(Get-Date -Format 'dd/MM/yyyy HH:mm')  ·  MultiTool $AppVersion</p>$($body -join '')</body></html>
"@
    Set-Content -Path $file -Value $html -Encoding UTF8
    Open-Shell $file
}

# --- Backup / ripristino ---
function Select-BackupDest {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Scegli dove salvare il backup (disco esterno, chiavetta o cartella di rete)'
    if ($Settings.BackupDest -and (Test-Path $Settings.BackupDest)) { $d.SelectedPath = $Settings.BackupDest }
    if ($d.ShowDialog() -eq 'OK') {
        $inside = @(Get-BackupFolders | Where-Object { $_.Path -and -not $_.Multi -and ($d.SelectedPath.TrimEnd('\') + '\').StartsWith($_.Path.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($inside.Count) { [void][MtTr]::Msg("La destinazione è dentro una cartella da salvare ($($inside[0].Name)): il backup copierebbe sé stesso all'infinito. Scegli un'altra cartella.", 'MultiTool', 'OK', 'Warning'); return }
        if ($d.SelectedPath -like "$env:SystemDrive\*" -and [MtTr]::Msg('La destinazione è sullo stesso disco di Windows: se il disco si guasta perdi anche il backup. Usarla comunque?', 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { return }
        $Settings.BackupDest = $d.SelectedPath; Save-Settings
        Update-BackupTask
        if ($State.Mode -eq 'backup') { Start-Scan }
    }
}
$BkTaskName = 'MultiTool - Backup automatico'
function Update-BackupTask {
    try {
        if ($Settings.BackupAuto -and $Settings.BackupDest) {
            $vbs = Join-Path $DataDir 'backup.vbs'
            Write-TaskVbs $vbs @('Set sh = CreateObject("WScript.Shell")', ('sh.Run """' + $PsExe + '"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ScriptPath + '"" -Backup", 0, True'))
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
    if ([MtTr]::Msg('Eliminare il punto di ripristino più vecchio?', 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { return }
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
    Toast 'Preparo lo storico dei sensori…'
    Start-Bg '$r = New-SensorHistory; if ($r.File) { Open-Shell $r.File } else { $sync.Toast = $r.Msg }' @{}
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
        if (Test-Path (Join-Path $Root 'Strumenti')) { New-Item -ItemType Directory (Join-Path $InstTarget 'Strumenti') -Force | Out-Null; Copy-Item (Join-Path $Root 'Strumenti\*') (Join-Path $InstTarget 'Strumenti') -Force }
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
        if ([MtTr]::Msg("MultiTool è installato in $InstTarget, con collegamenti nel menu Start e sul desktop.`n`nAprire ora la versione installata?", 'MultiTool', 'YesNo', 'Information') -eq 'Yes') {
            $State.ForceClose = $true; Release-AppMutex
            Start-Process $exe; $win.Close()
        }
    } catch { Toast "Installazione non riuscita: $($_.Exception.Message)" }
}

# --- Filtro elenco, CSV ---
$ListView = [Windows.Data.CollectionViewSource]::GetDefaultView($Items)
function Reset-Filter { $ui.LFilter.Text = ''; $ListView.Filter = $null; $ui.LFilterBox.Visibility = 'Collapsed'; $ui.LCsv.Visibility = 'Collapsed' }
$ui.LFilter.Add_TextChanged({
    $q = $ui.LFilter.Text.Trim()
    $ui.LFilterHint.Visibility = Vis (-not $q)
    if (-not $q) { $ListView.Filter = $null }
    else { $ListView.Filter = [Predicate[object]]{ param($o) ("$($o.Name) $($o.Sub) $($o.Tag) $($o.C1)").IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 }.GetNewClosure() }
})
function Export-ListCsv {
    $M = $Modes[$State.Mode]
    $d = New-Object Microsoft.Win32.SaveFileDialog; $d.Filter = 'CSV (*.csv)|*.csv'
    $d.FileName = ($M.Title -replace '[^\w]+', '-') + "-$(Get-Date -Format 'yyyyMMdd').csv"
    if (-not $d.ShowDialog($win)) { return }
    $h = @($M.H)
    $Items | ForEach-Object {
        $o = [ordered]@{}; $o[(T 'Nome')] = Protect-Csv $_.Name; $o[(T 'Dettaglio')] = Protect-Csv $_.Sub
        if ($h[0]) { $o[(T $h[0])] = Protect-Csv $_.C1 }; if ($h[1]) { $o[(T $h[1])] = Protect-Csv $_.C2 }; if ($h[2]) { $o[(T $h[2])] = Protect-Csv $_.Tag }
        $o[(T 'Esito')] = Protect-Csv $_.Status
        [pscustomobject]$o
    } | Export-Csv -Path $d.FileName -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Toast "Esportato: $(Split-Path $d.FileName -Leaf)"
}

function New-BatteryReport {
    if (-not (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)) { Toast 'Questo PC non ha una batteria'; return }
    Toast 'Creo il rapporto batteria…'
    Start-Bg @'
$dir = Join-Path $DataDir 'Rapporti'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
$f = Join-Path $dir ("batteria-{0}.html" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
Invoke-Hidden "$env:SystemRoot\System32\powercfg.exe" "/batteryreport /output `"$f`"" | Out-Null
if (Test-Path $f) { Open-Shell $f } else { $sync.Toast = 'Rapporto batteria non riuscito' }
'@ @{}
}

function Set-Dns([string[]]$Servers) {
    Toast 'Cambio i DNS…'
    Start-Bg @'
try {
    foreach ($a in Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up') {
        if ($srv.Count) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $srv -ErrorAction Stop } else { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop }
    }
    Clear-DnsClientCache
    $sync.Toast = if ($srv.Count) { "DNS impostati: $(($srv | Where-Object { $_ -notmatch ':' }) -join ', ')" } else { 'DNS automatici ripristinati' }
    Add-History 'Rete' 'DNS' $(if ($srv.Count) { $srv -join ', ' } else { 'automatici' }) 'ok'
} catch { $sync.Toast = "DNS non modificati: $($_.Exception.Message)" }
'@ @{ srv = @($Servers) }
}
function Set-PowerPlan([string]$Guid, [string]$Name) {
    $r = Invoke-Hidden "$env:SystemRoot\System32\powercfg.exe" "/setactive $Guid" 15
    if ($r.Code -eq 0) { Toast "Piano energetico: $Name"; Add-History 'Sistema' 'Piano energetico' $Name 'ok' }
    else { Toast 'Piano non disponibile su questo PC (i PC con standby moderno hanno solo il piano bilanciato)' }
}
function New-ProfileFromSelection {
    $sel = @($Items | Where-Object { $_.Selected -and $_.Checkable -and $_.Key })
    if (-not $sel.Count) { Toast 'Seleziona prima i programmi da mettere nel profilo'; return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $n = [Microsoft.VisualBasic.Interaction]::InputBox((T 'Nome del nuovo profilo (es. "Ufficio base"):'), 'MultiTool', '')
    if (-not $n.Trim()) { return }
    $f = Join-Path $ProfDir ((($n.Trim() -replace '[^\w\- ]', '') -replace '\s+', '-') + '.json')
    $o = [ordered]@{ name = $n.Trim(); description = "$($sel.Count) programmi  ·  creato il $(Get-Date -Format 'dd/MM/yyyy')"; winget = @($sel | ForEach-Object { $_.Key }); local = @() }
    ConvertTo-Json $o -Depth 4 | Set-Content $f -Encoding UTF8
    Invalidate-Cache 'profiles'
    Toast "Profilo creato: $(Split-Path $f -Leaf)"
}
function New-JobSheetUi { Toast 'Preparo la scheda intervento…'; Start-Bg '$f = New-JobSheet; Open-Shell $f' @{} }
function New-HealthReportUi { Toast 'Preparo il rapporto sullo stato del PC…'; Start-Bg '$f = New-HealthReport; Open-Shell $f' @{} }
function Start-Stress {
    if ($State.StressUntil) { $sync.Stress = $false; $State.StressUntil = $null; $ui.HwStress.Content = T 'Stress test CPU'; Toast 'Stress test interrotto'; return }
    if ($sync.Phase -eq 'run') { Toast 'Attendi la fine dell''operazione in corso'; return }
    if ([MtTr]::Msg('Il processore lavorerà al 100% per 5 minuti mentre MultiTool registra le temperature. Chiudi gli altri programmi. Avviare?', 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { return }
    Open-Hw
    $sync.Stress = $true; $State.StressUntil = (Get-Date).AddMinutes(5); $State.StressMax = 0
    for ($i = 0; $i -lt [Environment]::ProcessorCount; $i++) {
        Start-Bg '$end = [DateTime]::UtcNow.AddMinutes(5); while ($sync.Stress -and [DateTime]::UtcNow -lt $end) { $x = 0.0; for ($j = 1; $j -lt 300000; $j++) { $x += [math]::Sqrt($j) } }' @{}
    }
    $ui.HwStress.Content = T 'Interrompi stress test'
}

# --- Ricerca rapida (Ctrl+K) ---
$PalCmds = New-Object System.Collections.ArrayList
foreach ($n in @($ui.NavPanel.Children)) {
    if ($n -is [Windows.Controls.RadioButton]) {
        $name = $n.Name
        [void]$PalCmds.Add([pscustomobject]@{ N = (T ([string]$n.Content)); A = [scriptblock]::Create("`$ui['$name'].IsChecked = `$true; `$ui['$name'].RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))") })
    }
}
foreach ($c in @(
    @{ Safe = $true; N = 'Storico sensori'; A = { Export-SensorHistory } }
    @{ Safe = $true; N = 'Esporta inventario hardware'; A = { Open-Hw; Export-Hw } }
    @{ N = 'Backup driver'; A = { Start-DriverBackup } }
    @{ N = 'Esporta configurazione di MultiTool'; A = { Export-Config } }
    @{ N = 'Importa configurazione di MultiTool'; A = { Import-Config } }
    @{ N = 'Controlla aggiornamenti di MultiTool'; A = { Start-UpdCheck; Show-View 'ViewSettings' } }
    @{ Safe = $true; N = 'Informazioni e note legali'; A = { Show-About $false } }
    @{ Safe = $true; N = 'Novità di questa versione'; A = { Open-Shell "$AppRepo/releases/tag/v$AppVersion" } }
    @{ Safe = $true; N = 'Apri cartella dati'; A = { Start-Process explorer.exe $DataDir } }
    @{ Safe = $true; N = 'Gestione dispositivi'; A = { Start-Process devmgmt.msc } }
    @{ Safe = $true; N = 'Rapporto batteria'; A = { New-BatteryReport } }
    @{ N = 'Rapporto sullo stato del PC'; A = { New-HealthReportUi } }
    @{ N = 'Scheda intervento'; A = { New-JobSheetUi } }
    @{ N = 'Etichetta QR del PC'; A = { Toast 'Creo l''etichetta…'; Start-Bg '$f = New-PcLabel; Open-Shell $f' @{} } }
    @{ N = 'Test della memoria RAM (al riavvio)'; A = { Start-Process "$env:SystemRoot\System32\mdsched.exe" } }
    @{ N = 'Stress test del processore'; A = { Start-Stress } }
    @{ N = 'Dispositivi in rete'; A = { Open-Mode 'lan' } }
    @{ N = 'Residui delle disinstallazioni'; A = { Open-Mode 'leftovers' } }
    @{ N = 'DNS: Cloudflare (1.1.1.1)'; A = { Set-Dns @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001') } }
    @{ N = 'DNS: Google (8.8.8.8)'; A = { Set-Dns @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844') } }
    @{ N = 'DNS: automatico (dal router)'; A = { Set-Dns @() } }
    @{ N = 'Piano energetico: prestazioni elevate'; A = { Set-PowerPlan '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 'prestazioni elevate' } }
    @{ N = 'Piano energetico: bilanciato'; A = { Set-PowerPlan '381b4222-f694-41f0-9685-ff5bb260df2e' 'bilanciato' } }
    @{ N = 'Piano energetico: risparmio energia'; A = { Set-PowerPlan 'a1841308-3541-4fab-bc81-f71556f20b4a' 'risparmio energia' } }
    @{ Safe = $true; N = 'Gestione disco'; A = { Start-Process diskmgmt.msc } }
    @{ Safe = $true; N = 'Visualizzatore eventi'; A = { Start-Process eventvwr.msc } }
    @{ Safe = $true; N = 'Servizi di Windows'; A = { Start-Process services.msc } }
    @{ Safe = $true; N = 'Monitoraggio risorse'; A = { Start-Process resmon.exe } }
    @{ N = 'Configurazione di sistema'; A = { Start-Process msconfig.exe } }
    @{ Safe = $true; N = 'Pannello di controllo'; A = { Start-Process control.exe } }
    @{ N = 'Pulizia disco di Windows'; A = { Start-Process cleanmgr.exe } }
    @{ Safe = $true; N = 'Utilità di pianificazione'; A = { Start-Process taskschd.msc } }
    @{ Safe = $true; N = 'Gestione attività'; A = { Start-Process taskmgr.exe } }
    @{ Safe = $true; N = 'Monitoraggio affidabilità'; A = { Start-Process perfmon.exe '/rel' } }
    @{ Safe = $true; N = 'Sicurezza di Windows'; A = { Start-Process 'windowsdefender:' } }
    @{ N = 'Riavvia il PC'; A = { $ui.RebootGo.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } }
)) { $c.N = T $c.N; [void]$PalCmds.Add([pscustomobject]$c) }
function Update-Palette {
    $q = $ui.PalText.Text.Trim()
    $ui.PalHint.Visibility = Vis (-not $q)
    $ui.PalList.ItemsSource = @($PalCmds | Where-Object { -not $q -or $_.N.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($ui.PalList.Items.Count) { $ui.PalList.SelectedIndex = 0 }
}
function Open-Palette { $ui.PalText.Text = ''; Update-Palette; $ui.Palette.Visibility = 'Visible'; [void]$ui.PalText.Focus() }
function Close-Palette { $ui.Palette.Visibility = 'Collapsed' }
function Run-Palette { $c = $ui.PalList.SelectedItem; Close-Palette; if ($c) { if ($sync.Phase -eq 'run' -and -not $c.Safe) { Toast 'Attendi la fine dell''operazione in corso'; return }; & $c.A } }
$ui.PalText.Add_TextChanged({ Update-Palette })
$ui.PalText.Add_PreviewKeyDown({
    param($s, $e)
    switch ($e.Key) {
        'Down'   { if ($ui.PalList.SelectedIndex -lt $ui.PalList.Items.Count - 1) { $ui.PalList.SelectedIndex++ }; $ui.PalList.ScrollIntoView($ui.PalList.SelectedItem); $e.Handled = $true }
        'Up'     { if ($ui.PalList.SelectedIndex -gt 0) { $ui.PalList.SelectedIndex-- }; $ui.PalList.ScrollIntoView($ui.PalList.SelectedItem); $e.Handled = $true }
        'Return' { Run-Palette; $e.Handled = $true }
        'Escape' { Close-Palette; $e.Handled = $true }
    }
})
$ui.PalList.Add_MouseLeftButtonUp({ Run-Palette })
$ui.Palette.Add_MouseLeftButtonDown({ param($s, $e) if ($e.OriginalSource -eq $ui.Palette) { Close-Palette } })

# --- Scorciatoie da tastiera ---
function Set-Zoom([double]$z, [switch]$Quiet) {
    $z = [Math]::Round([Math]::Min(1.5, [Math]::Max(0.8, $z)), 1)
    if ($win.Content -is [Windows.FrameworkElement]) { $win.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform($z, $z) }
    if ($Settings.Zoom -ne $z) { $Settings.Zoom = $z; Save-Settings }
    if (-not $Quiet) { Toast "Zoom $([int]($z * 100)) %" }
}
if ($Settings.Zoom -and [double]$Settings.Zoom -ne 1) { Set-Zoom ([double]$Settings.Zoom) -Quiet }
$win.Add_PreviewKeyDown({
    param($s, $e)
    $ctrl = [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control
    if ($ctrl -and $e.Key -eq 'K') { if ($ui.Palette.Visibility -eq 'Visible') { Close-Palette } else { Open-Palette }; $e.Handled = $true; return }
    if ($ctrl -and $e.Key -in 'OemPlus', 'Add') { Set-Zoom ([double]$Settings.Zoom + 0.1); $e.Handled = $true; return }
    if ($ctrl -and $e.Key -in 'OemMinus', 'Subtract') { Set-Zoom ([double]$Settings.Zoom - 0.1); $e.Handled = $true; return }
    if ($ctrl -and $e.Key -in 'D0', 'NumPad0') { Set-Zoom 1.0; $e.Handled = $true; return }
    if ($ui.Palette.Visibility -eq 'Visible') { return }
    if (-not $ui.NavPanel.IsEnabled -and $sync.Phase -ne 'run') { return }
    if ($ctrl -and $e.Key -eq 'H' -and $sync.Phase -ne 'run') { Go-Home; $e.Handled = $true; return }
    if ($ctrl -and $e.Key -eq 'F' -and $ui.ViewList.Visibility -eq 'Visible' -and $Items.Count) {
        if ($Modes[$State.Mode].Search) { [void]$ui.LSearch.Focus() } else { $ui.LFilterBox.Visibility = 'Visible'; [void]$ui.LFilter.Focus() }
        $e.Handled = $true; return
    }
    if ($e.Key -eq 'F5' -and $sync.Phase -ne 'run') {
        if ($ui.ViewList.Visibility -eq 'Visible' -and -not $Modes[$State.Mode].Search) { Start-Scan }
        elseif ($ui.ViewHw.Visibility -eq 'Visible') { Load-Hw; Start-Sensors }
        elseif ($ui.ViewHome.Visibility -eq 'Visible') { Refresh-Info }
        elseif ($ui.ViewLogs.Visibility -eq 'Visible') { Load-Logs }
        $e.Handled = $true; return
    }
    if ($e.Key -eq 'Escape' -and $sync.Phase -ne 'run' -and $ui.ViewList.Visibility -eq 'Visible' -and -not ($e.OriginalSource -is [Windows.Controls.TextBox] -and $e.OriginalSource.Text)) {
        $ui.LCancel.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true
    }
})

# --- Configurazione esportabile ---
function Export-Config {
    $d = New-Object Microsoft.Win32.SaveFileDialog; $d.Filter = 'Configurazione MultiTool (*.zip)|*.zip'; $d.FileName = 'MultiTool-configurazione.zip'
    if (-not $d.ShowDialog($win)) { return }
    $tmp = Join-Path $env:TEMP ('mtcfg-' + [guid]::NewGuid()); New-Item -ItemType Directory "$tmp\Profili" -Force | Out-Null
    $cfg = $Settings | Select-Object * -ExcludeProperty WinL, WinT, WinW, WinH, WinMax, LastBackup, TermsAccepted, BackupDest, UpdateUrl, LastVersion, LastAutoRun
    if ($cfg.ShopLogo -and (Test-Path $cfg.ShopLogo)) { Copy-Item $cfg.ShopLogo (Join-Path $tmp ('logo' + [IO.Path]::GetExtension($cfg.ShopLogo))) }
    ConvertTo-Json $cfg -Depth 5 | Set-Content "$tmp\settings.json" -Encoding UTF8
    foreach ($f in 'exclusions.json') { $src = Join-Path $DataDir $f; if (Test-Path $src) { Copy-Item $src $tmp } }
    Copy-Item "$ProfDir\*.json" "$tmp\Profili" -ErrorAction SilentlyContinue
    if (Test-Path $d.FileName) { Remove-Item $d.FileName -Force }
    Compress-Archive -Path "$tmp\*" -DestinationPath $d.FileName
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Toast 'Configurazione esportata: importala sugli altri PC da Impostazioni'
}
function Import-Config {
    $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Filter = 'Configurazione MultiTool (*.zip)|*.zip'
    if (-not $d.ShowDialog($win)) { return }
    try {
        $tmp = Join-Path $env:TEMP ('mtcfg-' + [guid]::NewGuid())
        Expand-Archive $d.FileName $tmp -Force
        if (-not (Test-Path "$tmp\settings.json")) { throw 'il file non è una configurazione di MultiTool' }
        $new = Get-Content "$tmp\settings.json" -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $new.PSObject.Properties) { if ($p.Name -notin 'WinL', 'WinT', 'WinW', 'WinH', 'WinMax', 'LastBackup', 'TermsAccepted', 'BackupDest', 'ShopLogo', 'UpdateUrl', 'AutoSelfUpdate', 'LastVersion', 'LastAutoRun') { $Settings | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }
        $logo = Get-ChildItem $tmp -Filter 'logo.*' | Select-Object -First 1
        if ($logo) { $dst = Join-Path $DataDir $logo.Name; Copy-Item $logo.FullName $dst -Force; $Settings.ShopLogo = $dst }
        if (Test-Path "$tmp\exclusions.json") {
            $ex = [Collections.ArrayList]@(Read-Exclusions)
            foreach ($x in @(Get-Content "$tmp\exclusions.json" -Raw | ConvertFrom-Json)) { if ($x -and $ex -notcontains $x) { [void]$ex.Add($x) } }
            Save-Json 'exclusions.json' @($ex)
        }
        Copy-Item "$tmp\Profili\*.json" $ProfDir -Force -ErrorAction SilentlyContinue
        Save-Settings
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if ([MtTr]::Msg('Configurazione importata. Riavviare MultiTool per applicarla?', 'MultiTool', 'YesNo', 'Question') -eq 'Yes') { Restart-App }
    } catch { Toast "Importazione non riuscita: $($_.Exception.Message)" }
}

# --- Ultime operazioni e allarmi salute ---
function Update-LastOps {
    $p = Join-Path $DataDir 'history.jsonl'
    $last = @{}
    if (Test-Path $p) {
        foreach ($l in Get-Content $p -Tail 3000 -Encoding UTF8) {
            try { $h = $l | ConvertFrom-Json } catch { continue }
            $a = [string]$h.Area
            $k = if ($a -match 'Windows Update') { 'wu' } elseif ($a -match 'Manutenzione|Maintenance') { 'full' } elseif ($a -match 'Aggiorna|Automatic|Update') { 'upd' }
                 elseif ($a -match 'Pulizia|Cleanup|Clean') { 'clean' } elseif ($a -match 'Backup') { 'bk' } else { $null }
            if ($k) { $last[$k] = [datetime]$h.Time }
        }
    }
    if ($Settings.LastBackup) { $last['bk'] = [datetime]$Settings.LastBackup }
    $State.LastOps = $last
    $f = { param($k, $t) "$t " + $(if ($last[$k]) { $last[$k].ToString('dd/MM HH:mm') } else { 'mai' }) }
    $ui.HLast.Text = ((& $f 'full' 'Manutenzione:'), (& $f 'upd' 'Programmi aggiornati:'), (& $f 'wu' 'Windows Update:'), (& $f 'clean' 'Pulizia:'), (& $f 'bk' 'Backup:')) -join '   ·   '
}
function Test-HealthAlarms($i) {
    $al = @()
    foreach ($d in @($i.PD)) {
        if ($d.Health -and $d.Health -ne 'Healthy') { $al += "Disco $($d.Name): stato $($d.Health)" }
        if ($null -ne $d.Wear -and $d.Wear -ge 80) { $al += "Disco $($d.Name): usura $($d.Wear)%" }
        if ($d.Temp -ge $(if ($d.Bus -eq 'NVMe') { 72 } elseif ($d.Media -eq 'SSD') { 65 } else { 55 })) { $al += "Disco $($d.Name): $($d.Temp) °C" }
    }
    foreach ($d in @($i.Disks)) { if ($d.Size -and $d.Free / $d.Size -lt 0.1) { $al += "Disco $($d.Name): solo $(Format-Size $d.Free) liberi" } }
    if ($i.Bat -and $null -ne $i.Bat.Health -and $i.Bat.Health -lt 50) { $al += "Batteria: capacità al $($i.Bat.Health)%" }
    if ($i.DefOk -eq $false) { $al += 'Antivirus Microsoft Defender disattivato' }
    if ($i.UpDays -ge 7) { $al += "PC acceso da $($i.UpDays) giorni senza riavvio: riavvialo (usa Riavvia, non Arresta)" }
    if ($State.LastOps) {
        $lm = @($State.LastOps['full'], $State.LastOps['upd']) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
        if (-not $lm) { $lm = [datetime]$Settings.FirstRun }
        if ($lm -lt (Get-Date).AddDays(-30)) { $al += 'Manutenzione: non eseguita da oltre 30 giorni' }
    }
    $key = ($al -join '|')
    if ($al.Count -and ($Settings.LastAlarm -ne "$((Get-Date).ToString('yyyyMMdd'))|$key")) {
        $Settings | Add-Member -NotePropertyName LastAlarm -NotePropertyValue "$((Get-Date).ToString('yyyyMMdd'))|$key" -Force; Save-Settings
        Show-Toast 'MultiTool - Attenzione' ($al -join "`n")
        foreach ($a in $al) { Toast $a }
    }
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
<!DOCTYPE html><html lang="$(if ([MtTr]::On) { 'en' } else { 'it' })"><head><meta charset="utf-8"><title>MultiTool - $(& $E (T $M.Title))</title>
<style>body{font-family:Segoe UI,sans-serif;background:#f4f5f9;color:#1b1e27;margin:40px}h1{margin:0;font-size:28px}
.m{color:#5b6175;margin:6px 0 24px}table{width:100%;border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 1px 3px #0001}
th,td{padding:12px 14px;text-align:left;border-bottom:1px solid #eceef4;font-size:14px;vertical-align:top}th{font-size:11px;color:#8a90a6;text-transform:uppercase}
.s{color:#7a8096;font-size:12px;margin-top:2px}.p{padding:3px 10px;border-radius:8px;font-size:12px;font-weight:600;background:#eceef4}
.ok{background:#d7f5ea;color:#047857}.err{background:#fde2e2;color:#b91c1c}.skip{color:#8a90a6}.run,.wait{background:#dce8ff;color:#1d4ed8}</style></head>
<body><h1>$(& $E (T $M.Title))</h1><div class="m">$env:COMPUTERNAME  ·  $(Get-Date -Format 'dd/MM/yyyy HH:mm')  ·  $(& $E (T $Summary))</div>
<table><tr><th>$(T 'Elemento')</th><th>$(T 'Prima')</th><th>$(T 'Dopo')</th><th>$(T 'Esito')</th></tr>$($rowsHtml -join '')</table>
<p class="m" style="margin-top:20px">$(T 'Generato da MultiTool') $AppVersion</p></body></html>
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
    $v = $null
    if ($api) {
        try { $v = ((Invoke-RestMethod $api -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'MultiTool' }).tag_name -replace '^v', '').Trim() } catch {}
    }
    if (-not $v) { $v = (Invoke-WebRequest "$u/version.txt" -UseBasicParsing -TimeoutSec 20).Content.Trim() }
    $sync.NewVersion = if ([version]$v -gt [version]$cur) { $v } else { '' }
    $sync.UpdChecked = $true
} catch { $sync.NewVersion = ''; $sync.UpdChecked = $true; $sync.UpdError = $_.Exception.Message }
'@
function Get-UpdUrl { if ($Settings.UpdateUrl) { $Settings.UpdateUrl.TrimEnd('/') } else { $DefaultUpdateUrl } }
function Start-UpdCheck {
    $sync.UpdChecked = $false; $sync.UpdError = $null
    $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  controllo in corso…"
    $api = if ((Get-UpdUrl) -eq $DefaultUpdateUrl) { 'https://api.github.com/repos/Erodyne/MultiTool/releases/latest' } else { '' }
    Start-Bg $UpdCode @{ url = (Get-UpdUrl); cur = $AppVersion; api = $api }
}
function Install-SelfUpdate {
    try {
        $u = Get-UpdUrl
        if ($u -eq $DefaultUpdateUrl -and $sync.NewVersion) { $u = "https://raw.githubusercontent.com/Erodyne/MultiTool/v$($sync.NewVersion)" }
        $tmp = Join-Path $env:TEMP 'MultiTool-new.ps1'
        Invoke-WebRequest "$u/MultiTool.ps1" -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        $errs = $null; $tok = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tok, [ref]$errs)
        if ($errs.Count) { throw 'il file scaricato contiene errori' }
        $want = if ($sync.NewVersion) { [regex]::Escape($sync.NewVersion) } else { '[\d\.]+' }
        if (-not (Select-String -Path $tmp -Pattern "\`$AppVersion = '$want'" -Quiet)) { throw 'il file scaricato non corrisponde alla versione annunciata' }
        if ((Get-UpdUrl) -eq $DefaultUpdateUrl -and $sync.NewVersion) {
            $hs = $null
            try { $hs = ((Invoke-WebRequest "$AppRepo/releases/download/v$($sync.NewVersion)/MultiTool.ps1.sha256" -UseBasicParsing -TimeoutSec 30).Content -split '\s+')[0].Trim() } catch {}
            if (-not $hs) { $State.SelfUpdRetry = (Get-Date).AddMinutes(3); $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  la $($sync.NewVersion) è in preparazione su GitHub, riprovo tra poco"; throw 'la nuova versione non è ancora pubblicata, riprovo tra poco' }
            if ((Get-FileHash $tmp -Algorithm SHA256).Hash -ne $hs.ToUpper()) { throw 'impronta SHA256 non corrispondente: aggiornamento scartato' }
        }
        foreach ($f in 'MultiTool.ico', 'MultiTool-512.png') {
            $dst = Join-Path $Root $f
            if (-not (Test-Path $dst)) { try { Invoke-WebRequest "$u/$f" -OutFile $dst -UseBasicParsing -TimeoutSec 60 } catch {} }
        }
        New-Item -ItemType Directory (Join-Path $Root 'Strumenti') -Force | Out-Null
        foreach ($f in 'Avvia.vbs', 'Strumenti/qrcode.js', 'Strumenti/chart.umd.min.js', 'Strumenti/LICENZE.txt') {
            $t2 = Join-Path $env:TEMP ('mtupd-' + ($f -replace '[\\/]', '_'))
            try { Invoke-WebRequest "$u/$f" -OutFile $t2 -UseBasicParsing -TimeoutSec 60; Copy-Item $t2 (Join-Path $Root ($f -replace '/', '\')) -Force; Remove-Item $t2 -Force } catch {}
        }
        Copy-Item $ScriptPath (Join-Path $DataDir "backup-MultiTool-$AppVersion.ps1") -Force
        Get-ChildItem $DataDir -Filter 'backup-MultiTool-*.ps1' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
        if ($Installed) { try { Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MultiTool' -Name DisplayVersion -Value $sync.NewVersion -ErrorAction Stop } catch {} }
        Copy-Item $tmp $ScriptPath -Force
        Add-History 'MultiTool' "Aggiornato da $AppVersion" 'Completato' 'ok'
        Restart-App
    } catch { if (-not $State.SelfUpdRetry) { Toast "Aggiornamento non riuscito: $($_.Exception.Message)" } }
}
function Release-AppMutex { try { $Mutex.ReleaseMutex() } catch {}; try { if ($GMutex) { $GMutex.ReleaseMutex() } } catch {} }
function Restart-App {
    $State.ForceClose = $true
    $hid = if (-not $win.IsVisible -and $Settings.Tray) { ' -Hidden' } else { '' }
    Start-Process $PsExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Restart$hid" -WindowStyle Hidden
    Release-AppMutex
    $win.Close()
}

# --- Icona nell'area di notifica ---
$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = if (Test-Path $IcoPath) { New-Object System.Drawing.Icon $IcoPath } else { [System.Drawing.SystemIcons]::Application }
$Tray.Text = 'MultiTool'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add((T 'Apri MultiTool'))
$miUpd  = $menu.Items.Add((T 'Aggiorna programmi'))
$miFull = $menu.Items.Add((T 'Manutenzione completa'))
$miClean = $menu.Items.Add((T 'Pulizia disco'))
$miHw = $menu.Items.Add((T 'Hardware'))
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add((T 'Esci'))
$Tray.ContextMenuStrip = $menu
function Show-Main {
    $win.Show(); if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }; [void]$win.Activate()
    if ($State.DeferPrefetch) { $State.DeferPrefetch = $false; Start-Prefetch }
}
$Tray.Add_DoubleClick({ Show-Main })
$Tray.Add_BalloonTipClicked({ Show-Main; if ($State.BalloonMode -and $sync.Phase -ne 'run') { Open-Mode $State.BalloonMode } })
$miOpen.Add_Click({ Show-Main })
$miUpd.Add_Click({ Show-Main; Open-Mode 'updates' })
$miFull.Add_Click({ Show-Main; Open-Mode 'full' })
$miClean.Add_Click({ Show-Main; if ($sync.Phase -ne 'run') { Open-Mode 'cleanup' } })
$miHw.Add_Click({ Show-Main; if ($sync.Phase -ne 'run') { Open-Hw } })
$miExit.Add_Click({ $State.ForceClose = $true; Show-Main; $win.Close() })
$Tray.Visible = [bool]$Settings.Tray

$CountCode = @'
try {
    $excl = Read-Exclusions
    $r = Invoke-Hidden (Get-WingetPath) 'upgrade --include-unknown --accept-source-agreements --disable-interactivity' 300
    $sync.UpdCount = @(ConvertFrom-WingetTable $r.Out -FirstOnly | Where-Object { $_.Cols.Count -ge 4 -and $excl -notcontains $_.Cols[1] -and $_.Cols[1] -notmatch '…$' -and -not (Test-SkippedVer $_.Cols) }).Count
} catch { $sync.UpdCount = -1 }
'@
function Start-CountCheck { $sync.UpdCount = $null; Start-Bg $CountCode @{} }
$bgTimer = New-Object Windows.Threading.DispatcherTimer
$bgTimer.Interval = [TimeSpan]::FromHours(6)
$sync.Online = $true
$netTimer = New-Object Windows.Threading.DispatcherTimer
$netTimer.Interval = [TimeSpan]::FromSeconds(60)
$netTimer.Add_Tick({ if ($win.IsVisible) { Start-Bg '$sync.Online = Test-Online' @{} } })
$netTimer.Start()
Start-Bg '$sync.Online = Test-Online' @{}
$bgTimer.Add_Tick({ if ($sync.Phase -ne 'run') { if (-not (Test-Metered)) { Start-CountCheck; Start-UpdCheck }; Refresh-Info } })
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
    if ([MtTr]::Msg('Svuotare la cronologia?', 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { return }
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
             NavSecurity = 'security'; NavBench = 'bench'; NavRestore = 'restore'; NavServices = 'services'; NavProcesses = 'processes'
             NavBigFiles = 'bigfiles'; NavEvents = 'events'; NavPacks = 'packs'; NavSpace = 'space' }
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
$ui.HwLabel.Add_Click({ Toast 'Creo l''etichetta…'; Start-Bg '$f = New-PcLabel; Open-Shell $f' @{} })
foreach ($b in 'HwCr1', 'HwCr2', 'HwCr3', 'HwCr4') { $ui[$b].Add_Click({ param($s, $e) Open-Shell $s.Tag }) }
$ui.HwAdv.Add_Click({
    if ($Settings.Lhm) {
        if ([MtTr]::Msg('Disattivare i sensori avanzati?', 'MultiTool', 'YesNo', 'Question') -eq 'Yes') {
            $Settings.Lhm = $false; Save-Settings; Start-Sensors
        }
        return
    }
    $msg = "Per leggere temperature dei core, ventole e consumi serve un componente che accede ai sensori della scheda madre." +
           "`n`nVerranno installati tramite winget:`n- LibreHardwareMonitor (open source)`n- PawnIO, il driver firmato che usa per leggere i sensori`n`nProcedere?"
    if ([MtTr]::Msg($msg, 'MultiTool', 'YesNo', 'Question') -ne 'Yes') { return }
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
    if ([MtTr]::Msg('Eliminare tutti i log?', 'MultiTool', 'YesNo', 'Question') -eq 'Yes') {
        Get-ChildItem (Join-Path $DataDir 'Logs') -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Load-Logs
    }
})
$ui.LReport.Add_Click({ if ($State.Report) { Open-Shell $State.Report } })

$ui.QUpd.Add_Click({ Open-Mode 'updates' })
$ui.QWU.Add_Click({ Open-Mode 'wu' })
$ui.QDrv.Add_Click({ Open-Mode 'full' })
$ui.QClean.Add_Click({ Open-Mode 'cleanup' })

$ui.LX1.Add_Click({ & $Modes[$State.Mode].X1.Click })
$ui.LX2.Add_Click({ & $Modes[$State.Mode].X2.Click })
$ui.LAll.Add_Click({  foreach ($i in $ListView) { if ($i.Checkable -and $i.Editable) { $i.Selected = $true } } })
$ui.LNone.Add_Click({ foreach ($i in $ListView) { if ($i.Checkable -and $i.Editable) { $i.Selected = $false } } })
$ui.LCsv.Add_Click({ Export-ListCsv })
$ui.HwBat.Add_Click({ New-BatteryReport })
$ui.HwHealth.Add_Click({ New-HealthReportUi })
$ui.HwStress.Add_Click({ Start-Stress })
$ui.HwCopy.Add_Click({
    if (-not $State.HwCards) { Toast 'Attendi la fine della raccolta delle informazioni'; return }
    $txt = ($State.HwCards | ForEach-Object { "== $(T $_.T) ==`r`n" + (($_.Rows | ForEach-Object { "$(T $_.L): $(T $_.V)" }) -join "`r`n") }) -join "`r`n`r`n"
    try { [Windows.Clipboard]::SetText("$env:COMPUTERNAME`r`n`r`n$txt"); Toast 'Inventario copiato negli appunti' } catch { Toast 'Appunti non disponibili, riprova' }
})
$ui.LGo.Add_Click({  Start-Action ([string]$Modes[$State.Mode].GoOp) })
$ui.LGo2.Add_Click({ Start-Action ([string]$Modes[$State.Mode].Go2Op) })
$ui.LCancel.Add_Click({
    if ($sync.Phase -eq 'run') {
        $sync.Cancel = $true
        $ui.LCancel.IsEnabled = $false; $ui.LCancel.Content = T 'Annullamento…'
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
    if ($sync.Phase -eq 'run') { Toast 'Attendi la fine dell''operazione in corso prima di riavviare'; return }
    if ([MtTr]::Msg('Riavviare il computer adesso? Salva prima il lavoro aperto.', 'MultiTool', 'YesNo', 'Warning') -eq 'Yes') {
        Restart-Computer -Force
    }
})


# --- Informazioni / condizioni ---
function Show-About([bool]$MustAccept) {
    Stop-AnyScan
    $ui.AboutAcceptBox.Visibility = Vis $MustAccept
    $ui.NavPanel.IsEnabled = -not $MustAccept
    foreach ($c in $ui.NavPanel.Children) { if ($c -is [Windows.Controls.RadioButton]) { $c.IsChecked = $false } }
    Show-View 'ViewAbout'
}
$d = Get-AppDate
$ui.AboutVer.Text = "Versione $AppVersion" + $(if ($d) { "  ·  rilasciata il $($d.ToString('dd/MM/yyyy'))" } else { '' }) + "  ·  creato da $AppAuthor"
$ui.FootBar.Text = "MultiTool $AppVersion" + $(if ($d) { "  ·  $($d.ToString('dd/MM/yyyy'))" } else { '' }) + "  ·  creato da $AppAuthor  ·  © $((Get-Date).Year)"
if (Test-Path $IcoPath) { try { $ui.AboutLogo.Source = [Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $Root 'MultiTool-512.png')) } catch {} }
$secTpl = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,18,0,0">
  <TextBlock Text="{0}" FontSize="17" FontWeight="SemiBold" Foreground="#E8EAF2" Margin="0,0,0,6"/>
  {1}
</StackPanel>
'@
foreach ($sec in $Legal) {
    $paras = ($sec.B | ForEach-Object { "<TextBlock Text=`"$([Security.SecurityElement]::Escape((T $_)))`" Foreground=`"#9AA0B8`" FontSize=`"13.5`" TextWrapping=`"Wrap`" LineHeight=`"21`" Margin=`"0,4,0,4`"/>" }) -join ''
    [void]$ui.AboutBody.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($secTpl -f [Security.SecurityElement]::Escape((T $sec.T)), $paras))))
}
$ui.FootAbout.Add_Click({ Show-About $false })
$ui.SetAbout.Add_Click({ Show-About $false })
$ui.FootGit.Add_Click({ Open-Shell $AppRepo })
$ui.AboutAccept.Add_Click({
    $Settings.TermsAccepted = $TermsVersion; Save-Settings
    $ui.AboutAcceptBox.Visibility = 'Collapsed'; $ui.NavPanel.IsEnabled = $true
    Go-Home; Start-Prefetch
})
$ui.AboutDecline.Add_Click({ $State.ForceClose = $true; $win.Close() })

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
        if ($nx) { "Prossima esecuzione: $($nx.ToString('ddd dd/MM HH:mm', [Globalization.CultureInfo]::GetCultureInfo($(if ($Settings.Lang -eq 'en') { 'en-GB' } else { 'it-IT' }))))" } else { 'Attività pianificata attiva' }
    } else { 'Non pianificato' }
}

$ui.SetRestore.Add_Click({
    $Settings.Restore = [bool]$ui.SetRestore.IsChecked
    Save-Settings
})

function Register-AutoTask([string]$day, [string]$time) {
    $vbs = Join-Path $DataDir 'auto.vbs'; $vbs2 = Join-Path $DataDir 'auto-logon.vbs'
    Write-TaskVbs $vbs @('Set sh = CreateObject("WScript.Shell")', ('sh.Run """' + $PsExe + '"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ScriptPath + '"" -Auto", 0, True'))
    Write-TaskVbs $vbs2 @('Set sh = CreateObject("WScript.Shell")', ('sh.Run """' + $PsExe + '"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ScriptPath + '"" -Auto -Logon", 0, True'))
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $pr  = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    $st  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -WakeToRun:([bool]$Settings.AutoWake)
    $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At ([datetime]::ParseExact($time, 'H:mm', $null))
    Register-ScheduledTask -TaskName $TaskName -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`"") -Trigger $trg -Principal $pr -Settings $st -Force | Out-Null
    $tl = New-ScheduledTaskTrigger -AtLogOn -User $me; $tl.Delay = 'PT10M'
    $st2 = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName "$TaskName (recupero)" -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs2`"") -Trigger $tl -Principal $pr -Settings $st2 -Force | Out-Null
}
$ui.SetSave.Add_Click({
    $time = $ui.SetTime.Text.Trim()
    if ($time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { Toast 'Orario non valido: usa il formato HH:MM'; return }
    $day = ($days | ForEach-Object { $ui[$_] } | Where-Object { $_.IsChecked } | Select-Object -First 1).Tag
    if (-not $day) { $day = 'Sunday' }
    $Settings.AutoEnabled = [bool]$ui.SetAuto.IsChecked; $Settings.AutoDay = $day; $Settings.AutoTime = $time
    Save-Settings
    try {
        if ($Settings.AutoEnabled) {
            Register-AutoTask $day $time
            Toast 'Aggiornamento automatico pianificato'; Show-TaskAccountNote
        } else {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName "$TaskName (recupero)" -Confirm:$false -ErrorAction SilentlyContinue
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
        $Settings.($s.Tag) = $v; Save-Settings
    })
}
$ui.SetLogoInfo.Text = if ($Settings.ShopLogo) { Split-Path $Settings.ShopLogo -Leaf } else { 'nessuno' }
$ui.SetLogo.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Filter = 'Immagini (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg'
    if ($d.ShowDialog($win)) {
        $dst = Join-Path $DataDir ('logo' + [IO.Path]::GetExtension($d.FileName)); Copy-Item $d.FileName $dst -Force
        $Settings.ShopLogo = $dst; Save-Settings; $ui.SetLogoInfo.Text = Split-Path $d.FileName -Leaf
    }
})
$ui.SetBkAuto.IsChecked = [bool]$Settings.BackupAuto
$ui.SetBkTime.Text = $Settings.BackupTime
$ui.SetBkSave.Add_Click({
    $t = $ui.SetBkTime.Text.Trim()
    if ($t -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { Toast 'Orario non valido: usa il formato HH:MM'; return }
    if ($ui.SetBkAuto.IsChecked -and -not $Settings.BackupDest) { Toast 'Scegli prima la destinazione nella sezione Backup'; $ui.SetBkAuto.IsChecked = $false; return }
    $Settings.BackupAuto = [bool]$ui.SetBkAuto.IsChecked; $Settings.BackupTime = $t; Save-Settings
    Update-BackupTask; if ($Settings.BackupAuto) { Show-TaskAccountNote }; Toast $(if ($Settings.BackupAuto) { "Backup automatico ogni giorno alle $t" } else { 'Backup automatico disattivato' })
})
$ui.SetSensLog.IsChecked = [bool]$Settings.SensLog
$ui.SetSensLog.Add_Click({
    $Settings.SensLog = [bool]$ui.SetSensLog.IsChecked; Save-Settings
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
    $State.ForceClose = $true; Release-AppMutex; $win.Close()
})
$ui.SetEnglish.IsChecked = ($Settings.Lang -eq 'en')
$ui.SetEnglish.Add_Click({
    $Settings.Lang = if ($ui.SetEnglish.IsChecked) { 'en' } else { 'it' }; Save-Settings
    if ($sync.Phase -ne 'run') { Restart-App }
})
Update-BackupInfo
$ui.SetLight.IsChecked = ($EffTheme -eq 'light')
$ui.SetAutoTheme.IsChecked = ($Settings.Theme -eq 'auto')
$ui.SetLight.IsEnabled = ($Settings.Theme -ne 'auto')
$ui.SetAutoTheme.Add_Click({
    $Settings.Theme = if ($ui.SetAutoTheme.IsChecked) { 'auto' } elseif ($ui.SetLight.IsChecked) { 'light' } else { 'dark' }
    $ui.SetLight.IsEnabled = -not $ui.SetAutoTheme.IsChecked
    Save-Settings
    if ($sync.Phase -ne 'run') { Restart-App } else { Toast 'Il tema verrà applicato al prossimo avvio' }
})
$StartTaskName = 'MultiTool - Avvio con Windows'
function Update-StartupTask {
    try {
        if ($Settings.StartWithWindows) {
            $vbs = Join-Path $DataDir 'avvio.vbs'
            Write-TaskVbs $vbs @('Set sh = CreateObject("WScript.Shell")', ('sh.Run """' + $PsExe + '"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ScriptPath + '"" -Hidden", 0, False'))
            $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
            $trg = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
            $trg.Delay = 'PT30S'
            $pr  = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
            $st  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $StartTaskName -Action $act -Trigger $trg -Principal $pr -Settings $st -Force | Out-Null
            if (-not $Settings.Tray) { $Settings.Tray = $true; $ui.SetTray.IsChecked = $true; $Tray.Visible = $true; Save-Settings }
        } else { Unregister-ScheduledTask -TaskName $StartTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    } catch { Toast "Avvio con Windows non impostato: $($_.Exception.Message)" }
}
function Show-TaskAccountNote {
    $u = Get-UserCtx
    if ($u.Other) { [void][MtTr]::Msg("Le attività pianificate vengono registrate per l'account amministratore $env:USERNAME, non per $($u.Name): partiranno solo quando $env:USERNAME ha effettuato l'accesso al PC.", 'MultiTool', 'OK', 'Information') }
}
function Repair-Tasks {
    foreach ($d in @(@{ T = $TaskName; F = 'auto.vbs'; A = '-Auto'; W = 'True' }, @{ T = "$TaskName (recupero)"; F = 'auto-logon.vbs'; A = '-Auto -Logon'; W = 'True' }, @{ T = $BkTaskName; F = 'backup.vbs'; A = '-Backup'; W = 'True' }, @{ T = $StartTaskName; F = 'avvio.vbs'; A = '-Hidden'; W = 'False' })) {
        $t = Get-ScheduledTask -TaskName $d.T -ErrorAction SilentlyContinue
        if (-not $t) { continue }
        $vbs = Join-Path $DataDir $d.F
        $cur = if (Test-Path $vbs) { Get-Content $vbs -Raw } else { '' }
        $act = @($t.Actions)[0]
        if ($cur -notlike "*$ScriptPath*" -or $cur -notlike "*$PsExe*" -or $act.Arguments -ne "`"$vbs`"") {
            Write-TaskVbs $vbs @('Set sh = CreateObject("WScript.Shell")', ('sh.Run """' + $PsExe + '"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ScriptPath + '"" ' + $d.A + '", 0, ' + $d.W))
            Set-ScheduledTask -TaskName $d.T -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`"") | Out-Null
            Write-ErrLog "Attività '$($d.T)' aggiornata al nuovo percorso"
        }
    }
}
$ui.SetStartup.IsChecked = [bool]$Settings.StartWithWindows
$ui.SetStartup.Add_Click({ $Settings.StartWithWindows = [bool]$ui.SetStartup.IsChecked; Save-Settings; Update-StartupTask; if ($Settings.StartWithWindows) { Show-TaskAccountNote }
    Toast $(if ($Settings.StartWithWindows) { 'MultiTool partirà con Windows nell''area di notifica' } else { 'Avvio con Windows disattivato' }) })
$ui.SetTray.IsChecked = [bool]$Settings.Tray
$ui.SetPrefetch.IsChecked = [bool]$Settings.Prefetch
$ui.SetAutoFull.IsChecked = [bool]$Settings.AutoFull
$ui.SetAutoWake.IsChecked = [bool]$Settings.AutoWake
$ui.SetAutoWake.Add_Click({
    $Settings | Add-Member -NotePropertyName AutoWake -NotePropertyValue ([bool]$ui.SetAutoWake.IsChecked) -Force; Save-Settings
    if ($Settings.AutoEnabled) { try { Register-AutoTask $Settings.AutoDay $Settings.AutoTime } catch {} }
    Toast $(if ($Settings.AutoWake) { 'Il PC verrà risvegliato per l''aggiornamento e poi rimesso in sospensione' } else { 'Risveglio automatico disattivato' })
})
$ui.SetAutoFull.Add_Click({ $Settings.AutoFull = [bool]$ui.SetAutoFull.IsChecked; Save-Settings; Toast $(if ($Settings.AutoFull) { 'L''attività automatica eseguirà la manutenzione completa' } else { 'L''attività automatica aggiornerà solo i programmi' }) })
$ui.SetCfgExp.Add_Click({ Export-Config })
$ui.SetCfgImp.Add_Click({ Import-Config })
$ui.SetPrefetch.Add_Click({
    $Settings.Prefetch = [bool]$ui.SetPrefetch.IsChecked; Save-Settings
    if ($Settings.Prefetch) { Start-Prefetch } else { $sync.PrefetchGen = [int]$sync.PrefetchGen + 1; $ui.PrefInfo.Text = '' }
})
$ui.SetUpdUrl.Text = [string]$Settings.UpdateUrl
$ui.SetSelfUpd.IsChecked = [bool]$Settings.AutoSelfUpdate
$ui.SetSelfUpd.Add_Click({ $Settings.AutoSelfUpdate = [bool]$ui.SetSelfUpd.IsChecked; Save-Settings })
$ui.SetLight.Add_Click({
    $Settings.Theme = if ($ui.SetLight.IsChecked) { 'light' } else { 'dark' }
    Save-Settings
    if ($sync.Phase -ne 'run') { Restart-App } else { Toast 'Il tema verrà applicato al prossimo avvio' }
})
$ui.SetTray.Add_Click({
    $Settings.Tray = [bool]$ui.SetTray.IsChecked; $Tray.Visible = $Settings.Tray
    if (-not $Settings.Tray -and $Settings.StartWithWindows) { $Settings.StartWithWindows = $false; $ui.SetStartup.IsChecked = $false; Update-StartupTask }
    Save-Settings
})
function Set-UpdUrl {
    $u = $ui.SetUpdUrl.Text.Trim().TrimEnd('/')
    if ($u -eq [string]$Settings.UpdateUrl) { return $true }
    if ($u -and $u -notmatch '^https://') { Toast 'Indirizzo non valido: deve iniziare con https://'; $ui.SetUpdUrl.Text = [string]$Settings.UpdateUrl; return $false }
    if ($u -and $u -ne $DefaultUpdateUrl -and [MtTr]::Msg("MultiTool scaricherà ed eseguirà come amministratore gli aggiornamenti da:`n$u`n`nUsa solo un indirizzo di cui ti fidi. Continuare?", 'MultiTool', 'YesNo', 'Warning') -ne 'Yes') { $ui.SetUpdUrl.Text = [string]$Settings.UpdateUrl; return $false }
    $Settings.UpdateUrl = $u; Save-Settings; $true
}
$ui.SetUpdUrl.Add_LostFocus({ [void](Set-UpdUrl) })
$ui.SetUpdCheck.Add_Click({ if (Set-UpdUrl) { Start-UpdCheck } })
$ui.SetUpdGo.Add_Click({
    if ($sync.Phase -eq 'run') { Toast 'Attendi la fine dell''operazione in corso'; return }
    if ([MtTr]::Msg("Aggiornare MultiTool alla versione $($sync.NewVersion)? Il programma verrà riavviato.", 'MultiTool', 'YesNo', 'Question') -eq 'Yes') { Install-SelfUpdate }
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
    if ($sync.Toast) { Toast $sync.Toast; $sync.Toast = $null }
    if ((Get-Date) -gt $State.ToastUntil) {
        if ($State.Q.Count) {
            $ui.ToastText.Text = $State.Q[0]; $State.Q.RemoveAt(0)
            $ui.Toast.Visibility = 'Visible'; $State.ToastUntil = (Get-Date).AddSeconds(4)
        } elseif ($ui.Toast.Visibility -eq 'Visible') { $ui.Toast.Visibility = 'Collapsed' }
    }

    # Stress test
    if ($State.StressUntil) {
        foreach ($se in @($sync.Sens)) { if ($se -and $se.T -eq 'Temperature' -and "$($se.G) $($se.N)" -match '(?i)cpu|core|package|tctl|tdie|processor|processore|zona termica' -and "$($se.G) $($se.N)" -notmatch '(?i)gpu|disk|disco|nvme|ssd' -and $se.V -gt $State.StressMax -and $se.V -lt 125) { $State.StressMax = [double]$se.V } }
        $left = $State.StressUntil - (Get-Date)
        if ($left.TotalSeconds -le 0) {
            $sync.Stress = $false; $State.StressUntil = $null; $ui.HwStress.Content = T 'Stress test CPU'
            $mx = [math]::Round($State.StressMax)
            $msg = if (-not $mx) { 'Stress test finito, ma non ho letto temperature: attiva i sensori avanzati' } elseif ($mx -ge 95) { "Stress test finito: $mx °C, temperatura CRITICA (pulizia ventole o pasta termica)" } elseif ($mx -ge 85) { "Stress test finito: $mx °C, temperatura alta" } else { "Stress test finito: $mx °C massimi, raffreddamento a posto" }
            Toast $msg; Add-History 'Hardware' 'Stress test CPU' $(if ($mx) { "$mx °C" } else { 'n.d.' }) $(if ($mx -ge 95) { 'err' } else { 'ok' })
        } else { $ui.HwSensMsg.Text = T ("Stress test in corso: $([int]$left.TotalMinutes):$('{0:00}' -f $left.Seconds) rimanenti  ·  massima $([math]::Round($State.StressMax)) °C") }
    }

    # Auto-aggiornamento: applica appena il programma è libero
    if ($State.PendingSelfUpdate -and (-not $State.SelfUpdRetry -or (Get-Date) -gt $State.SelfUpdRetry) -and $sync.Phase -in 'idle', 'review' -and -not $State.SelfUpdating -and ($ui.ViewHome.Visibility -eq 'Visible' -or -not $win.IsVisible)) {
        $State.SelfUpdating = $true
        if (-not $State.UpdToastDone) { Toast "Aggiorno MultiTool alla versione $($State.PendingSelfUpdate)…"; $State.UpdToastDone = $true }
        $State.SelfUpdAt = (Get-Date).AddSeconds(3)
    }
    if ($State.SelfUpdating -and $State.SelfUpdAt -and (Get-Date) -gt $State.SelfUpdAt) { $State.SelfUpdAt = $null; $State.SelfUpdRetry = $null; Install-SelfUpdate; $State.SelfUpdating = $false; if (-not $State.SelfUpdRetry) { $State.PendingSelfUpdate = $null } }

    # Conteggio aggiornamenti in background
    if ($null -ne $sync.UpdCount) {
        $n = $sync.UpdCount; $sync.UpdCount = $null
        if ($n -gt 0) {
            $ui.QUpdSub.Text = "$n aggiornamenti disponibili"
            if ($Tray.Visible -and $n -gt [int]$State.LastUpdN) { $State.BalloonMode = 'updates'; $Tray.ShowBalloonTip(6000, 'MultiTool', (T "$n aggiornamenti disponibili. Clicca per vederli."), 'Info') }
        } elseif ($n -eq 0) { $ui.QUpdSub.Text = 'Tutto aggiornato' }
        $State.LastUpdN = $n
    }

    # Auto-aggiornamento
    if ($sync.UpdChecked) {
        $sync.UpdChecked = $false
        if ($sync.UpdError) { $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  controllo non riuscito: $($sync.UpdError)" }
        elseif ($sync.NewVersion) {
            $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  disponibile la $($sync.NewVersion)"
            $ui.SetUpdGo.Visibility = 'Visible'
            if ($Settings.AutoSelfUpdate) { $State.PendingSelfUpdate = $sync.NewVersion }
            else { Toast "È disponibile MultiTool $($sync.NewVersion): vai in Impostazioni per aggiornare" }
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
        Update-LastOps
        try { Test-HealthAlarms $i } catch { Write-ErrLog "Allarmi: $($_.Exception.Message)" }
        $ui.HHealth.Children.Clear()
        foreach ($d in @($i.PD)) {
            $ok = $d.Health -eq 'Healthy'
            $st = switch ($d.Health) { 'Healthy' { 'Integro' } 'Warning' { 'Attenzione' } 'Unhealthy' { 'Guasto' } default { 'Sconosciuto' } }
            $det = @($(if ($d.Media -and $d.Media -ne 'Unspecified') { $d.Media }), $(if ($d.Size) { Format-Size $d.Size }),
                     $(if ($d.Temp) { "$($d.Temp) °C" }), $(if ($null -ne $d.Wear) { "usura $($d.Wear)%" }), $(if ($d.Hours) { "$($d.Hours) ore" })) | Where-Object { $_ }
            $col = if ($ok) { '#34D399' } elseif ($d.Health -eq 'Warning') { '#FBBF24' } else { '#F87171' }
            $ui.HHealth.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($HealthTpl -f [Security.SecurityElement]::Escape($d.Name), [Security.SecurityElement]::Escape((T ($det -join '  ·  '))), (T $st), $col)))) | Out-Null
        }
        if ($i.Bat) {
            $h = $i.Bat.Health
            $col = if ($null -eq $h) { '#9AA0B8' } elseif ($h -ge 80) { '#34D399' } elseif ($h -ge 60) { '#FBBF24' } else { '#F87171' }
            $txt = "Carica $($i.Bat.Charge)%" + $(if ($null -ne $h) { "  ·  capacità $h% rispetto al nuovo" } else { '' })
            $ui.HHealth.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($HealthTpl -f (T 'Batteria'), (T $txt), $(if ($null -eq $h) { 'n.d.' } elseif ($h -ge 80) { 'Buona' } elseif ($h -ge 60) { 'Usurata' } else { 'Da sostituire' }), $col)))) | Out-Null
        }
        if (-not $ui.HHealth.Children.Count) { $ui.HHealth.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($HealthTpl -f (T 'Dati non disponibili'), (T 'Il sistema non espone lo stato dei dischi'), '—', '#9AA0B8')))) | Out-Null }
        $ui.HDisks.Children.Clear()
        foreach ($d in $i.Disks) {
            if (-not $d.Size) { continue }
            $pct = [int][Math]::Round(($d.Size - $d.Free) / $d.Size * 100)
            $name = [Security.SecurityElement]::Escape("$($d.Name)  $($d.Label)")
            $txt  = [Security.SecurityElement]::Escape((T "$(Format-Size $d.Free) liberi di $(Format-Size $d.Size)"))
            $col  = if ($pct -ge 90) { '#F87171' } elseif ($pct -ge 75) { '#FBBF24' } else { '#8B6CFF' }
            $ui.HDisks.Children.Add([Windows.Markup.XamlReader]::Parse((Apply-Theme ($DiskTpl -f $name, $txt, $pct, (100 - $pct), $col)))) | Out-Null
        }
    }

    # Seconda istanza: porta la finestra in primo piano
    if ($ShowEvt.WaitOne(0)) { Show-Main; $win.Topmost = $true; $win.Topmost = $false }

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
            if ($sync.LhmResult -eq 'ok') { $Settings.Lhm = $true; Save-Settings; Toast 'Sensori avanzati attivati'; Start-Sensors }
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
                    $t.FindName('n').Text = T $se.N; $t.FindName('g').Text = T $se.G; $t.ToolTip = "$($se.G) - $($se.N)"
                    [void]$ui.HwSens.Children.Add($t); $State.Tiles[$se.K] = $t
                }
                $val = if ($se.U -in 'RPM', 'MHz') { '{0:N0}' -f $se.V } else { '{0:N1}' -f $se.V }
                $vb = $t.FindName('v'); $vb.Text = "$val $($se.U)"
                $vb.Foreground = if ($se.T -eq 'Temperature' -and $se.V -ge 85) { '#F87171' } elseif ($se.T -eq 'Temperature' -and $se.V -ge 70) { '#FBBF24' } elseif ($EffTheme -eq 'light') { '#1B1E27' } else { '#E8EAF2' }
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
                $ui.LFilterBox.Visibility = Vis ($Items.Count -gt 8 -and -not $M.Search); $ui.LCsv.Visibility = 'Visible'
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
            $ui.LSummary.Text = T "$($sync.Done) di $($sync.Total) completati"
            if (-not $sync.Cancel) { $ui.LSub.Text = $sync.Status }
        }
        'done' {
            [void][NativePow.Power]::SetThreadExecutionState(0x80000000)
            if ($State.HoldWork) { $State.HoldWork = $false; try { $WorkMx.ReleaseMutex() } catch {} }
            Invalidate-Cache $State.Mode
            if ($sync.ExtraRows) {
                $xr = @($sync.ExtraRows.ToArray() | ForEach-Object { T $_.Name })
                foreach ($old in @($Items | Where-Object { $xr -contains $_.Name })) { [void]$Items.Remove($old) }
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
            if ($sync.LastBackup) {
                $Settings.LastBackup = $sync.LastBackup; $sync.LastBackup = $null
                if ($sync.BackupSel) { $Settings | Add-Member -NotePropertyName BackupSel -NotePropertyValue @($sync.BackupSel) -Force; $sync.BackupSel = $null }
                Save-Settings; Update-BackupInfo
            }
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
            if (-not $win.IsVisible -and $Tray.Visible) { $State.BalloonMode = $null; $Tray.ShowBalloonTip(6000, 'MultiTool', "$($M.Title): $sum", 'Info') }
            elseif (-not $win.IsActive) { Show-Toast "MultiTool - $($M.Title)" $(if ($sum) { $sum } else { 'Operazione completata' }) }
            $ui.LCsv.Visibility = Vis ($Items.Count -gt 0)
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
    if ($Settings.Tray) { Hide-ToTray }
    else { $win.WindowState = 'Minimized' }
})
$win.Add_StateChanged({
    if ($win.WindowState -eq 'Maximized') {
        try {
            $hw = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
            $wa = [Windows.Forms.Screen]::FromHandle($hw).WorkingArea
            $m = [Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformFromDevice
            $win.MaxHeight = $wa.Height * $m.M22 + 2; $win.MaxWidth = $wa.Width * $m.M11 + 2
        } catch { $wa = [Windows.SystemParameters]::WorkArea; $win.MaxHeight = $wa.Height + 2; $win.MaxWidth = $wa.Width + 2 }
    } else { $win.MaxHeight = [double]::PositiveInfinity; $win.MaxWidth = [double]::PositiveInfinity }
})
$win.Add_IsVisibleChanged({
    $timer.Interval = [TimeSpan]::FromMilliseconds($(if ($win.IsVisible) { 250 } else { 750 }))
    if ($win.IsVisible) { Start-Bg '$sync.Online = Test-Online' @{} }
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
try { [Microsoft.Win32.SystemEvents]::add_SessionEnding({ $State.ForceClose = $true }) } catch {}
function Hide-ToTray {
    $win.Hide()
    if (-not $State.TrayTip) { $State.TrayTip = $true; $State.BalloonMode = $null; $Tray.ShowBalloonTip(4000, 'MultiTool', (T 'MultiTool resta attivo qui. Doppio clic per riaprirlo, tasto destro › Esci per chiuderlo.'), 'Info') }
}
$ui.BtnClose.Add_Click({ $win.Close() })
$win.Add_Closing({
    param($s, $e)
    if ($Settings.Tray -and -not $State.ForceClose) { $e.Cancel = $true; Hide-ToTray; return }
    $rb = $win.RestoreBounds
    if (-not $rb.IsEmpty) { $Settings.WinL = $rb.Left; $Settings.WinT = $rb.Top; $Settings.WinW = $rb.Width; $Settings.WinH = $rb.Height }
    $Settings.WinMax = ($win.WindowState -eq 'Maximized')
    try { Save-Settings } catch {}
    if ($sync.Phase -eq 'run') {
        $r = [MtTr]::Msg('Un''operazione è in corso: chiudendo ora potresti lasciare un''installazione a metà. Chiudere comunque?', 'MultiTool', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true }
    }
})
$win.Add_Closed({ try { $Tray.Visible = $false; $Tray.Dispose() } catch {}; [Environment]::Exit(0) })

$h = (Get-Date).Hour
$ui.HHello.Text = $(if ($Settings.Lang -eq 'en') { if ($h -lt 12) { 'Good morning' } elseif ($h -lt 18) { 'Good afternoon' } else { 'Good evening' } } elseif ($h -lt 12) { 'Buongiorno' } elseif ($h -lt 18) { 'Buon pomeriggio' } else { 'Buonasera' }) + ", $env:USERNAME"

# --- Controlli all'avvio ---
try { Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}
if ($Installed -and $Settings.AclVer -ne 1) {
    try {
        $r = Invoke-Hidden "$env:SystemRoot\System32\icacls.exe" "`"$Base`" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX /T /C /Q" 120
        Get-ChildItem $Base -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $a = $_.GetAccessControl(); $a.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544'); $_.SetAccessControl($a) } catch {} }
        if ($r.Code -eq 0) { $Settings | Add-Member -NotePropertyName AclVer -NotePropertyValue 1 -Force; Save-Settings }
    } catch { Write-ErrLog "Permessi cartella dati: $($_.Exception.Message)" }
}
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
        $sync.Toast = if ((Get-UserCtx).Other) { "Accesso come ${me}: avvio, privacy, pulizia e backup vengono applicati all'utente $((Get-UserCtx).Name)" } else { "Stai usando l'account amministratore ${me}: avvio automatico e file temporanei riguardano quell'account, non $session" }
    }
} catch {}
try {
    $el = Join-Path $DataDir 'Logs\errori.log'
    if ((Test-Path $el) -and (Get-Item $el).Length -gt 1MB) { (Get-Content $el -Tail 2000) | Set-Content $el -Encoding UTF8 }
} catch {}
$ui.AppVer.Text = "MultiTool $AppVersion  ·  Ctrl+K per cercare"
try {
    Get-ChildItem (Join-Path $DataDir 'Rapporti') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) -and $_.Name -notmatch '^(Consegna|Etichetta|Intervento|Stato-PC)-' } | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem (Join-Path $DataDir 'DriverBackup') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
        Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {}
if ($Settings.BackupDest -and (-not $Settings.LastBackup -or ((Get-Date) - [datetime]$Settings.LastBackup).TotalDays -gt 7)) {
    if ([string]$Settings.LastBkNag -ne (Get-Date).ToString('yyyyMMdd')) {
        Toast "L'ultimo backup ha più di 7 giorni: vai nella sezione Backup"
        $Settings | Add-Member -NotePropertyName LastBkNag -NotePropertyValue (Get-Date).ToString('yyyyMMdd') -Force; Save-Settings
    }
}
if ($Settings.SensLog) { Start-Sensors }
if ([int]$Settings.Mig -lt 2) {
    $Settings | Add-Member -NotePropertyName Mig -NotePropertyValue 2 -Force
    $Settings.Tray = $true; $Settings.AutoSelfUpdate = $true; $Tray.Visible = $true
    $ui.SetTray.IsChecked = $true; $ui.SetSelfUpd.IsChecked = $true
    Save-Settings
}
if (-not $Settings.FirstRun) { $Settings | Add-Member -NotePropertyName FirstRun -NotePropertyValue (Get-Date).ToString('s') -Force; Save-Settings }
if ([string]$Settings.LastVersion -ne $AppVersion) {
    if ($Settings.LastVersion) { Toast "MultiTool aggiornato alla versione $AppVersion. Le novità sono in Ctrl+K › Novità" }
    $Settings | Add-Member -NotePropertyName LastVersion -NotePropertyValue $AppVersion -Force; Save-Settings
}
try { Repair-Tasks } catch { Write-ErrLog "Attività: $($_.Exception.Message)" }
try {
    $me = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 1 -ErrorAction Stop
    if ($me -and $me.TimeCreated.ToString('s') -ne [string]$Settings.LastMemCheck) {
        $Settings | Add-Member -NotePropertyName LastMemCheck -NotePropertyValue $me.TimeCreated.ToString('s') -Force; Save-Settings
        if ($me.TimeCreated -gt (Get-Date).AddDays(-2)) { Toast $(if ($me.Id -in 1101, 1201) { 'Test della memoria: nessun errore' } else { 'Test della memoria: rilevati ERRORI nella RAM' }) }
    }
} catch {}
if (-not (Test-Metered)) { Start-CountCheck; Start-UpdCheck } else { $ui.SetUpdInfo.Text = "Versione installata: $AppVersion  ·  connessione a consumo: controllo rimandato" }
Update-AutoInfo
if ($Settings.TermsAccepted -ne $TermsVersion) { Show-About $true }
elseif ($Hidden) {
    Show-View 'ViewHome'; $State.DeferPrefetch = $true
    $dp = New-Object Windows.Threading.DispatcherTimer; $dp.Interval = [TimeSpan]::FromMinutes(5)
    $dp.Add_Tick({ param($s, $e) $s.Stop(); if ($State.DeferPrefetch) { $State.DeferPrefetch = $false; Start-Prefetch } }); $dp.Start()
} else { Show-View 'ViewHome'; Start-Prefetch }
Refresh-Info
if ($Hidden -and $Settings.Tray -and $Settings.TermsAccepted -eq $TermsVersion) {
    $win.ShowInTaskbar = $false; $win.WindowState = 'Minimized'
    $win.Add_Loaded({ $win.Hide(); $win.WindowState = 'Normal'; $win.ShowInTaskbar = $true })
}
[void]$win.ShowDialog()
