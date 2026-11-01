#define AppVersion GetEnv("DEBRIFY_VERSION")
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{9B23C6A1-6A05-4B0C-9D6C-5DB02E2AA8F7}}
AppName=Nextup
AppVersion={#AppVersion}
AppPublisher=Nextup
AppPublisherURL=https://github.com/Alehaaaa/debrify
DefaultDirName={autopf}\\Debrify
DisableDirPage=yes
DefaultGroupName=Nextup
DisableProgramGroupPage=yes
OutputDir=..\\build\\windows\\installer
OutputBaseFilename=nextup-{#AppVersion}-setup
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=runner\\resources\\app_icon.ico
WizardStyle=modern

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\\build\\windows\\x64\\runner\\Release\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\\Nextup"; Filename: "{app}\\debrify.exe"
Name: "{autodesktop}\\Nextup"; Filename: "{app}\\debrify.exe"; Tasks: desktopicon

[Registry]
; Register stremio:// URL protocol
Root: HKCU; Subkey: "Software\\Classes\\stremio"; ValueType: string; ValueData: "URL:Stremio Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\\Classes\\stremio"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\\Classes\\stremio\\shell\\open\\command"; ValueType: string; ValueData: """{app}\\debrify.exe"" ""%1"""

; Register magnet:// URL protocol
Root: HKCU; Subkey: "Software\\Classes\\magnet"; ValueType: string; ValueData: "URL:Magnet Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\\Classes\\magnet"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\\Classes\\magnet\\shell\\open\\command"; ValueType: string; ValueData: """{app}\\debrify.exe"" ""%1"""

; Register debrify:// URL protocol (OAuth callbacks, etc.)
Root: HKCU; Subkey: "Software\\Classes\\debrify"; ValueType: string; ValueData: "URL:Debrify Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\\Classes\\debrify"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\\Classes\\debrify\\shell\\open\\command"; ValueType: string; ValueData: """{app}\\debrify.exe"" ""%1"""

[Run]
Filename: "{app}\\debrify.exe"; Description: "Launch Nextup"; Flags: nowait postinstall skipifsilent
