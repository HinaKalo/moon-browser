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
SetupIconFile={#AppIcon}
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
ChangesAssociations=yes
Compression=lzma2
SolidCompression=yes
ArchiveExtraction=full
OutputBaseFilename=MoonBrowser-Installer-win-x64
VersionInfoVersion={#WindowsVersion}
WizardStyle=modern

[Files]
Source: "{#EngineUrl}"; DestName: "webkit.zip"; DestDir: "{app}\engine"; Hash: "{#EngineHash}"; ExternalSize: {#EngineBytes}; Flags: download extractarchive external ignoreversion recursesubdirs createallsubdirs; Check: EngineDownloadRequired
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Moon Browser"; Filename: "{app}\MoonBrowser.exe"; WorkingDir: "{app}"; IconFilename: "{app}\MoonBrowser.exe"

[Registry]
Root: HKCU; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Moon Browser"; ValueData: "Software\Clients\StartMenuInternet\MoonBrowser\Capabilities"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Clients\StartMenuInternet\MoonBrowser"; ValueType: string; ValueData: "Moon Browser"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Clients\StartMenuInternet\MoonBrowser\DefaultIcon"; ValueType: string; ValueData: """{app}\MoonBrowser.exe"",0"
Root: HKCU; Subkey: "Software\Clients\StartMenuInternet\MoonBrowser\shell\open\command"; ValueType: string; ValueData: """{app}\MoonBrowser.exe"""
Root: HKCU; Subkey: "Software\Clients\StartMenuInternet\MoonBrowser\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Moon Browser"
Root: HKCU; Subkey: "Software\Clients\StartMenuInternet\MoonBrowser\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "Moon Browser opens HTTP and HTTPS links."
Root: HKCU; Subkey: "Software\Clients\StartMenuInternet\MoonBrowser\Capabilities"; ValueType: string; ValueName: "ApplicationIcon"; ValueData: """{app}\MoonBrowser.exe"",0"
Root: HKCU; Subkey: "Software\Clients\StartMenuInternet\MoonBrowser\Capabilities\URLAssociations"; ValueType: string; ValueName: "http"; ValueData: "MoonBrowser.URL"
Root: HKCU; Subkey: "Software\Clients\StartMenuInternet\MoonBrowser\Capabilities\URLAssociations"; ValueType: string; ValueName: "https"; ValueData: "MoonBrowser.URL"
Root: HKCU; Subkey: "Software\Classes\MoonBrowser.URL"; ValueType: string; ValueData: "Moon Browser URL"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\MoonBrowser.URL"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\MoonBrowser.URL\DefaultIcon"; ValueType: string; ValueData: """{app}\MoonBrowser.exe"",0"
Root: HKCU; Subkey: "Software\Classes\MoonBrowser.URL\shell\open\command"; ValueType: string; ValueData: """{app}\MoonBrowser.exe"" --open-url ""%1"""

[Run]
Filename: "{app}\MoonBrowser.exe"; Description: "Launch Moon Browser"; Flags: postinstall nowait skipifsilent

[Code]
const
  EngineDirectory = $10;
  EngineReparsePoint = $400;
  InvalidFileAttributes = $FFFFFFFF;

function EnginePathAttributes(const Path: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function SafeEngineTree(const Root: String; Depth: Integer): Boolean;
var
  Attr: LongWord;
  Entry: TFindRec;
begin
  Attr := EnginePathAttributes(Root);
  if Attr = InvalidFileAttributes then
  begin
    Result := True;
    Exit;
  end;
  Result := False;
  if (Depth > 32) or ((Attr and (EngineDirectory or EngineReparsePoint)) <> EngineDirectory) then Exit;
  if FindFirst(AddBackslash(Root) + '*', Entry) then
  begin
    try
      repeat
        if (Entry.Name <> '.') and (Entry.Name <> '..') then
        begin
          if (Entry.Attributes and EngineReparsePoint) <> 0 then Exit;
          if (Entry.Attributes and EngineDirectory) <> 0 then
            if not SafeEngineTree(AddBackslash(Root) + Entry.Name, Depth + 1) then Exit;
        end;
      until not FindNext(Entry);
    finally
      FindClose(Entry);
    end;
  end;
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not SafeEngineTree(ExpandConstant('{app}\engine'), 0) then
    Result := 'The WebKit directory contains an unsupported link or is not a regular directory.';
end;

function EngineFileMatches(const Root, RelativePath, ExpectedHash: String): Boolean;
var
  FileName: String;
begin
  FileName := AddBackslash(Root) + RelativePath;
  Result := False;
  if not FileExists(FileName) then Exit;
  try
    Result := CompareText(GetSHA256OfFile(FileName), ExpectedHash) = 0;
  except
    Log('Moon WebKit: could not read ' + RelativePath);
  end;
end;

#include EngineIntegrityInclude

function EngineDownloadRequired(): Boolean;
var
  Root: String;
begin
  Root := ExpandConstant('{app}\engine');
  Result := True;
  if DirExists(Root) and SafeEngineTree(Root, 0) then
    Result := not EngineMatches(Root);
  if Result then
    Log('Moon WebKit: pinned engine missing or changed; download required.')
  else
    Log('Moon WebKit: reusing the installed pinned engine; no download.');
end;
