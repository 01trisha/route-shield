#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef PublishDir
  #error PublishDir is required
#endif

[Setup]
AppId=RouteShield.Windows
AppName=Route Shield
AppVersion={#AppVersion}
AppPublisher=Route Shield
AppPublisherURL=https://github.com/01trisha/route-shield
DefaultDirName={localappdata}\Programs\Route Shield
DefaultGroupName=Route Shield
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
SetupIconFile=RouteShield\RouteShield.ico
UninstallDisplayIcon={app}\RouteShield.exe
CloseApplications=yes
RestartApplications=no
LicenseFile=..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Route Shield"; Filename: "{app}\RouteShield.exe"

[Run]
Filename: "{app}\RouteShield.exe"; Description: "Route Shield"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{userstartup}\Route Shield.lnk"
