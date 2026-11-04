; JavHub Desktop installer (Inno Setup 6). Per-user: no admin rights needed.
; Build: ISCC.exe /DAppVersion=0.3.0 installer\javhub.iss  (after `flutter build windows --release`)

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F1C2E4B-8D7A-4C35-9B1E-5A2D7C9E0F31}
AppName=JavHub
AppVersion={#AppVersion}
AppVerName=JavHub {#AppVersion}
AppPublisher=LiamZhaofor
DefaultDirName={localappdata}\Programs\JavHub
DefaultGroupName=JavHub
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=JavHub-Setup-{#AppVersion}
SetupIconFile=..\assets\app_icon.ico
UninstallDisplayIcon={app}\JavHub.exe
UninstallDisplayName=JavHub
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; files of an older build that this one no longer ships
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{group}\JavHub"; Filename: "{app}\JavHub.exe"
Name: "{group}\卸载 JavHub"; Filename: "{uninstallexe}"
Name: "{userdesktop}\JavHub"; Filename: "{app}\JavHub.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\JavHub.exe"; Description: "{cm:LaunchProgram,JavHub}"; Flags: nowait postinstall skipifsilent
