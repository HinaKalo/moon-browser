[Setup]
AppId={{BB69CBC1-3A21-4CEA-AA65-0B36D8E14F22}
AppName=Moon Browser Preview
AppVersion={#ReleaseVersion}
AppPublisher=HinaKalo
AppPublisherURL=https://github.com/HinaKalo/moon-browser
AppSupportURL=https://github.com/HinaKalo/moon-browser/issues
AppUpdatesURL=https://github.com/HinaKalo/moon-browser/releases
DefaultDirName={localappdata}\Programs\Moon Browser
DefaultGroupName=Moon Browser
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\MoonBrowser.exe
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
Compression=lzma2
SolidCompression=yes
ArchiveExtraction=full
OutputBaseFilename=MoonBrowser-Installer-win-x64
VersionInfoVersion=0.1.0.0
WizardStyle=modern

[Files]
Source: "{#EngineUrl}"; DestName: "webkit.zip"; DestDir: "{app}\engine"; Hash: "{#EngineHash}"; ExternalSize: {#EngineBytes}; Flags: download extractarchive external ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Moon Browser"; Filename: "{app}\MoonBrowser.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\MoonBrowser.exe"; Description: "Launch Moon Browser"; Flags: postinstall nowait skipifsilent
