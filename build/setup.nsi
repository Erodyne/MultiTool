Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "WordFunc.nsh"

!define APPNAME "MultiTool"
!ifndef VERSION
  !define VERSION "0.0.0.0"
!endif
!define SRC ".."
!define UNKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\MultiTool"

Name "${APPNAME}"
OutFile "..\dist\MultiTool-Setup-${VERSION}.exe"
InstallDir "$PROGRAMFILES64\MultiTool"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "MultiTool ${VERSION}"

VIProductVersion "${VERSION}"
VIAddVersionKey /LANG=1040 "ProductName" "MultiTool"
VIAddVersionKey /LANG=1040 "FileDescription" "Installazione di MultiTool"
VIAddVersionKey /LANG=1040 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1040 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1040 "LegalCopyright" "MultiTool"

!define MUI_ICON "${SRC}\MultiTool.ico"
!define MUI_UNICON "${SRC}\MultiTool.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "wizard.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "wizard.bmp"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_RIGHT
!define MUI_HEADERIMAGE_BITMAP "header.bmp"
!define MUI_HEADERIMAGE_UNBITMAP "header.bmp"
!define MUI_ABORTWARNING
!define MUI_COMPONENTSPAGE_SMALLDESC
!define MUI_WELCOMEPAGE_TITLE "Benvenuto in MultiTool"
!define MUI_WELCOMEPAGE_TEXT "MultiTool aggiorna programmi e Windows, installa software, pulisce e ripara il sistema, controlla hardware, sicurezza e rete.$\r$\n$\r$\nRichiede Windows 10 o 11.$\r$\n$\r$\nFai clic su Avanti per continuare."
!define MUI_FINISHPAGE_RUN "$INSTDIR\MultiTool.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Avvia MultiTool"

!insertmacro MUI_PAGE_WELCOME
!define MUI_LICENSEPAGE_TEXT_TOP "Leggi le condizioni d'uso di MultiTool."
!insertmacro MUI_PAGE_LICENSE "condizioni.txt"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "Italian"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "MultiTool richiede Windows a 64 bit."
    Abort
  ${EndIf}
  SetRegView 64
  ReadRegStr $0 HKLM "${UNKEY}" "InstallLocation"
  ${If} $0 != ""
    StrCpy $INSTDIR $0
  ${EndIf}
  ReadRegStr $1 HKLM "${UNKEY}" "DisplayVersion"
  ${If} $1 != ""
    ${VersionCompare} "${VERSION}" "$1" $2
    ${If} $2 == 0
      MessageBox MB_YESNO|MB_ICONQUESTION "MultiTool ${VERSION} è già installato.$\r$\n$\r$\nVuoi reinstallarlo? Impostazioni e dati verranno mantenuti." /SD IDYES IDYES +2
      Abort
    ${ElseIf} $2 == 1
      MessageBox MB_YESNO|MB_ICONQUESTION "È installato MultiTool $1.$\r$\n$\r$\nVuoi aggiornarlo alla versione ${VERSION}? Impostazioni e dati verranno mantenuti." /SD IDYES IDYES +2
      Abort
    ${Else}
      MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON2 "È già installata una versione più recente di MultiTool ($1).$\r$\n$\r$\nQuesto installer contiene la versione ${VERSION}, più vecchia. Tornare alla versione precedente è sconsigliato.$\r$\n$\r$\nInstallare comunque la ${VERSION}?" /SD IDNO IDYES +2
      Abort
    ${EndIf}
  ${EndIf}
FunctionEnd

Section "MultiTool (obbligatorio)" SecMain
  SectionIn RO
  SetRegView 64
  SetShellVarContext all
  DetailPrint "Chiudo MultiTool se è aperto…"
  nsExec::Exec 'powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand RwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBQAHIAbwBjAGUAcwBzACAALQBGAGkAbAB0AGUAcgAgACIATgBhAG0AZQA9ACcAcABvAHcAZQByAHMAaABlAGwAbAAuAGUAeABlACcAIgAgAHwAIABXAGgAZQByAGUALQBPAGIAagBlAGMAdAAgAHsAIAAkAF8ALgBDAG8AbQBtAGEAbgBkAEwAaQBuAGUAIAAtAGwAaQBrAGUAIAAnACoATQB1AGwAdABpAFQAbwBvAGwALgBwAHMAMQAqACcAIAB9ACAAfAAgAEYAbwByAEUAYQBjAGgALQBPAGIAagBlAGMAdAAgAHsAIABTAHQAbwBwAC0AUAByAG8AYwBlAHMAcwAgAC0ASQBkACAAJABfAC4AUAByAG8AYwBlAHMAcwBJAGQAIAAtAEYAbwByAGMAZQAgAC0ARQByAHIAbwByAEEAYwB0AGkAbwBuACAAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAgAH0A'
  Sleep 800

  SetOutPath "$INSTDIR"
  File "${SRC}\MultiTool.exe"
  File "${SRC}\MultiTool.ps1"
  File "${SRC}\MultiTool.ico"
  File "${SRC}\MultiTool-512.png"
  File "${SRC}\Avvia.vbs"
  SetOutPath "$INSTDIR\Strumenti"
  File "${SRC}\Strumenti\Firma-MultiTool.ps1"
  File "${SRC}\Strumenti\qrcode.js"
  File "${SRC}\Strumenti\chart.umd.min.js"
  File "${SRC}\Strumenti\LICENZE.txt"

  ; dati condivisi in ProgramData (non sovrascrive profili modificati)
  CreateDirectory "$APPDATA\MultiTool\Installers"
  CreateDirectory "$APPDATA\MultiTool\Dati"
  SetOutPath "$APPDATA\MultiTool\Profili"
  SetOverwrite off
  File "${SRC}\Profili\*.json"
  SetOverwrite on

  SetOutPath "$INSTDIR"
  CreateShortcut "$SMPROGRAMS\MultiTool.lnk" "$INSTDIR\MultiTool.exe" "" "$INSTDIR\MultiTool.ico" 0 SW_SHOWNORMAL "" "Manutenzione del PC"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "${UNKEY}" "DisplayName" "MultiTool"
  WriteRegStr HKLM "${UNKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNKEY}" "Publisher" "MultiTool"
  WriteRegStr HKLM "${UNKEY}" "DisplayIcon" "$INSTDIR\MultiTool.ico"
  WriteRegStr HKLM "${UNKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNKEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNKEY}" "NoRepair" 1
  SectionGetSize ${SecMain} $0
  WriteRegDWORD HKLM "${UNKEY}" "EstimatedSize" $0
SectionEnd

Section "Collegamento sul desktop" SecDesk
  SetShellVarContext all
  CreateShortcut "$DESKTOP\MultiTool.lnk" "$INSTDIR\MultiTool.exe" "" "$INSTDIR\MultiTool.ico" 0 SW_SHOWNORMAL "" "Manutenzione del PC"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "Il programma, i profili di esempio e gli strumenti. Impostazioni e dati vanno in ProgramData\MultiTool."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesk} "Aggiunge l'icona di MultiTool sul desktop di tutti gli utenti."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  SetRegView 64
  SetShellVarContext all
  DetailPrint "Chiudo MultiTool e rimuovo le attività pianificate…"
  nsExec::Exec 'powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand RwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBQAHIAbwBjAGUAcwBzACAALQBGAGkAbAB0AGUAcgAgACIATgBhAG0AZQA9ACcAcABvAHcAZQByAHMAaABlAGwAbAAuAGUAeABlACcAIgAgAHwAIABXAGgAZQByAGUALQBPAGIAagBlAGMAdAAgAHsAIAAkAF8ALgBDAG8AbQBtAGEAbgBkAEwAaQBuAGUAIAAtAGwAaQBrAGUAIAAnACoATQB1AGwAdABpAFQAbwBvAGwALgBwAHMAMQAqACcAIAB9ACAAfAAgAEYAbwByAEUAYQBjAGgALQBPAGIAagBlAGMAdAAgAHsAIABTAHQAbwBwAC0AUAByAG8AYwBlAHMAcwAgAC0ASQBkACAAJABfAC4AUAByAG8AYwBlAHMAcwBJAGQAIAAtAEYAbwByAGMAZQAgAC0ARQByAHIAbwByAEEAYwB0AGkAbwBuACAAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAgAH0AOwAgAEcAZQB0AC0AUwBjAGgAZQBkAHUAbABlAGQAVABhAHMAawAgAC0AVABhAHMAawBOAGEAbQBlACAAJwBNAHUAbAB0AGkAVABvAG8AbAAqACcAIAAtAEUAcgByAG8AcgBBAGMAdABpAG8AbgAgAFMAaQBsAGUAbgB0AGwAeQBDAG8AbgB0AGkAbgB1AGUAIAB8ACAAVQBuAHIAZQBnAGkAcwB0AGUAcgAtAFMAYwBoAGUAZAB1AGwAZQBkAFQAYQBzAGsAIAAtAEMAbwBuAGYAaQByAG0AOgAkAGYAYQBsAHMAZQAgAC0ARQByAHIAbwByAEEAYwB0AGkAbwBuACAAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQA7ACAARwBlAHQALQBOAGUAdABGAGkAcgBlAHcAYQBsAGwAUgB1AGwAZQAgAC0ARABpAHMAcABsAGEAeQBOAGEAbQBlACAAJwBNAHUAbAB0AGkAVABvAG8AbAAqACcAIAAtAEUAcgByAG8AcgBBAGMAdABpAG8AbgAgAFMAaQBsAGUAbgB0AGwAeQBDAG8AbgB0AGkAbgB1AGUAIAB8ACAAUgBlAG0AbwB2AGUALQBOAGUAdABGAGkAcgBlAHcAYQBsAGwAUgB1AGwAZQAgAC0ARQByAHIAbwByAEEAYwB0AGkAbwBuACAAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQA='
  Sleep 800
  Delete "$SMPROGRAMS\MultiTool.lnk"
  Delete "$DESKTOP\MultiTool.lnk"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "${UNKEY}"
  MessageBox MB_YESNO|MB_ICONQUESTION "Eliminare anche i dati di MultiTool (impostazioni, cronologia, rapporti, installer e profili in ProgramData)?" /SD IDNO IDNO keep
    RMDir /r "$APPDATA\MultiTool"
  keep:
SectionEnd
