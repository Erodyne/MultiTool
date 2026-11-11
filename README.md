<p align="center"><img src="MultiTool-512.png" width="128" alt="MultiTool"></p>

<h1 align="center">MultiTool</h1>
<p align="center">Manutenzione completa del PC Windows in un'unica app moderna.</p>

---

## Download

Scarica l'ultima versione dalla pagina **[Releases](../../releases/latest)**:

- `MultiTool-Setup-<versione>.exe`: installer classico (menu Start, desktop, disinstallazione da *App installate*)
- `MultiTool-portatile-<versione>.zip`: versione portatile, estrai e avvia `MultiTool.exe`

Requisiti: Windows 10 o 11 a 64 bit, diritti di amministratore. Per gli aggiornamenti dei programmi serve **winget** (incluso in Windows, app *Programma di installazione app*).

> L'eseguibile non è ancora firmato digitalmente: al primo avvio Windows SmartScreen può mostrare un avviso (*Ulteriori informazioni → Esegui comunque*).

## Funzioni

| Area | Cosa fa |
|---|---|
| **Home** | Sistema, CPU, RAM, antivirus, spazio e salute dei dischi, batteria, azioni rapide |
| **Manutenzione completa** | Aggiornamenti, Windows Update, pulizia e controlli in un clic, con rapporto finale |
| **Preparazione consegna** | Profilo programmi, rimozione app inutili, privacy, aggiornamenti, rapporto di consegna ed etichetta QR con i dati del negozio |
| **Aggiorna programmi** | Elenco aggiornamenti winget e Microsoft Store, conferma, avanzamento in %, esclusioni |
| **Installer locali / Catalogo / Profili** | Installazioni da file, dal catalogo winget o a gruppi |
| **Disinstalla** | Programmi desktop e app dello Store, anche in sequenza |
| **Backup** | Copia di Documenti, Desktop, Immagini… su disco esterno o rete, anche pianificata |
| **Hardware** | Inventario completo (marche, modelli, firmware, seriali) e sensori in tempo reale |
| **Windows Update / Driver** | Aggiornamenti di sistema, stato driver, backup e ripristino driver |
| **Avvio automatico / Pulizia / Riparazione** | Programmi all'avvio, spazio recuperabile, DISM, SFC, CHKDSK |
| **Privacy / Sicurezza / Rete** | Impostazioni privacy reversibili, punteggio di sicurezza con correzioni, diagnosi e test di velocità |
| **Benchmark / Punti di ripristino** | Test CPU, RAM e disco con confronto; gestione dei punti di ripristino |
| **Cronologia / Log / Impostazioni** | Storico operazioni, log, tema chiaro/scuro, inglese, area di notifica, pianificazioni |

## Struttura del repository

```
MultiTool.ps1        programma (PowerShell + WPF)
version.txt          versione pubblicata, letta dall'aggiornamento automatico
Avvia.vbs            avvio alternativo senza .exe
Profili/             profili di installazione di esempio (JSON)
Strumenti/           firma digitale del codice
build/               launcher C#, script NSIS dell'installer e immagini
.github/workflows/   compilazione automatica di installer e zip
```

## Pubblicare una nuova versione

1. Aggiorna `$AppVersion` in `MultiTool.ps1` e lo stesso numero in `version.txt` (formato `AAAA.MM.GG.N`).
2. Fai commit e push su `main`: i PC con MultiTool installato vedranno l'aggiornamento in *Impostazioni*.
3. Crea un tag, ad esempio `v2026.11.11.3`, e fai push del tag: GitHub Actions compila `MultiTool.exe`, l'installer e lo zip e li pubblica in **Releases**.

Puoi anche avviare la compilazione a mano da **Actions → Build e release → Run workflow** (i file restano scaricabili come *artifact*).

## Crediti

MultiTool usa strumenti e servizi di terze parti, mai inclusi nel pacchetto ma scaricati o richiamati solo quando servono:

- [winget](https://github.com/microsoft/winget-cli) e [winget-pkgs](https://github.com/microsoft/winget-pkgs) · Microsoft
- Windows Update, WMI, DISM, SFC, CHKDSK, WinSAT · Microsoft
- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) e [PawnIO](https://pawnio.eu) per i sensori avanzati (facoltativi)
- [NVIDIA SMI](https://developer.nvidia.com/system-management-interface) per i sensori delle schede NVIDIA
- [Cloudflare Speed Test](https://speed.cloudflare.com) e [ipify](https://www.ipify.org) per la sezione Rete
- [qrcodejs](https://github.com/davidshimjs/qrcodejs) e [Chart.js](https://www.chartjs.org) nei rapporti HTML
- Installer creato con [NSIS](https://nsis.sourceforge.io)
