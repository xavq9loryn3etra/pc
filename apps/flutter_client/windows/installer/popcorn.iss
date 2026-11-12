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
#define AppExe "flutter_client.exe"

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
; Installs for the current user without an administrator prompt; the user
; can choose "for all users" instead.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
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

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
