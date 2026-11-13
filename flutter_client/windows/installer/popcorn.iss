; Popcorn for Windows — installer (Inno Setup 6).
;
; Don't compile this directly: run build_installer.ps1 (next to it), which
; builds the app, adds the C++ runtime and passes the version.
; Output: build\installer\Popcorn-Setup-<version>.exe

#ifndef AppVersion
  #error Pass /DAppVersion=x.y.z (build_installer.ps1 does).
#endif
#ifndef StageDir
  #error Pass /DStageDir=<folder with the app's files> (build_installer.ps1 does).
#endif

#define AppName "Popcorn"
; Named Popcorn.exe, as the earlier homemade installer did (2026-11), so its
; shortcuts and the process name stay the same.
#define AppExe "Popcorn.exe"

[Setup]
; Never change AppId: it's how Windows knows a new version replaces the old.
AppId={{4AC3C330-42DA-44B4-8052-773796D5DD8D}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Popcorn
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Installing over the earlier homemade installer's folder (whose uninstaller
; left its files) is the normal case: no "folder already exists" question.
DirExistsWarning=no
; Installs for the current user, with no administrator prompt — always, so
; an update lands on the earlier install (no "for all users" choice: that
; went to Program Files and left the per-user copy and its shortcut).
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\..\build\installer
OutputBaseFilename=Popcorn-Setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; A running copy is closed before its files are replaced.
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; What the earlier homemade installer left in the same folder.
Type: files; Name: "{app}\Uninstall-Popcorn.exe"
Type: files; Name: "{app}\flutter_client.exe"

[Registry]
; The earlier installer's own "Installed apps" entry, replaced by this one's.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\Popcorn"; Flags: deletekey dontcreatekey

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; A running copy holds its files open; closed first so they can all go.
Filename: "{sys}\taskkill.exe"; Parameters: "/f /t /im {#AppExe}"; Flags: runhidden; RunOnceId: "ClosePopcorn"

[UninstallDelete]
; Everything the app saved, so uninstalling leaves nothing behind.
; Downloaded videos, caches and the web view's files (lib/services/windows_app_folder.dart):
Type: filesandordirs; Name: "{app}\data"
; Settings — and, from versions before the data folder (or when the
; install folder can't be written to), the downloads and caches too:
Type: filesandordirs; Name: "{userappdata}\com.popcorn"
Type: filesandordirs; Name: "{localappdata}\com.popcorn"
Type: filesandordirs; Name: "{localappdata}\flutter_webview_windows\Popcorn"
Type: dirifempty; Name: "{localappdata}\flutter_webview_windows"
Type: filesandordirs; Name: "{%TEMP}\libCachedImageData"
Type: files; Name: "{%TEMP}\popcorn_sub_*"
Type: files; Name: "{%TEMP}\current_book.epub"
Type: files; Name: "{%TEMP}\poster_*.jpg"
