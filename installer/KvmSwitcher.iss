#define MyAppName "KVM Switcher"
#define MyAppExeName "KvmSwitcher.exe"
#ifndef AppVersion
  #define AppVersion GetFileVersion("..\artifacts\staging\windows\KvmSwitcher.exe")
#endif

[Setup]
AppId={{12CCB92F-EF08-43B1-A44F-96CDAB17D949}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher=KVM Switcher
DefaultDirName={localappdata}\Programs\KvmSwitcher
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
AppMutex=Local\KvmSwitcher.SingleInstance
CloseApplications=no
RestartApplications=no
OutputDir=..\artifacts
OutputBaseFilename=KvmSwitcher-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\assets\KvmSwitcher.ico
UninstallDisplayIcon={app}\KvmSwitcher.exe
UninstallDisplayName={#MyAppName}
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
VersionInfoCompany=KVM Switcher
VersionInfoProductName={#MyAppName}
VersionInfoDescription={#MyAppName} setup
VersionInfoOriginalFileName=KvmSwitcher-Setup.exe
VersionInfoTextVersion={#AppVersion}

[Files]
Source: "..\artifacts\staging\windows\KvmSwitcher.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\artifacts\staging\windows\KvmSwitcher.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\artifacts\staging\windows\KvmSwitcher.deps.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\artifacts\staging\windows\KvmSwitcher.runtimeconfig.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\artifacts\staging\windows\HidSharp.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\artifacts\staging\windows\kvm-switcher_0.8.0-1_all.deb"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\artifacts\staging\windows\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\artifacts\staging\windows\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[Tasks]
Name: "startup"; Description: "Start KVM Switcher when Windows starts"; Flags: unchecked

[Icons]
Name: "{autoprograms}\KVM Switcher"; Filename: "{app}\KvmSwitcher.exe"; WorkingDir: "{app}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "KvmSwitcher"; ValueData: "{code:QuotedAppExe}"; Flags: uninsdeletevalue; Tasks: startup
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "KvmSwitcher"; Flags: deletevalue uninsdeletevalue; Tasks: not startup

[Run]
Filename: "{app}\KvmSwitcher.exe"; Description: "Launch KVM Switcher"; Flags: nowait postinstall skipifsilent

[Code]
function HasWindowsDesktop8RuntimeAtRoot(RootKey: Integer): Boolean;
var
  ValueNames: TArrayOfString;
  I: Integer;
begin
  Result := False;
  if not RegGetValueNames(RootKey, 'SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App', ValueNames) then
    Exit;

  for I := 0 to GetArrayLength(ValueNames) - 1 do
    if (Length(ValueNames[I]) >= 2) and (Copy(ValueNames[I], 1, 2) = '8.') then
    begin
      Result := True;
      Exit;
    end;
end;

function HasWindowsDesktop8Runtime(): Boolean;
begin
  Result := HasWindowsDesktop8RuntimeAtRoot(HKLM64) or HasWindowsDesktop8RuntimeAtRoot(HKLM32);
end;

function InitializeSetup(): Boolean;
begin
  Result := HasWindowsDesktop8Runtime();
  if not Result then
    SuppressibleMsgBox('KVM Switcher requires the x64 .NET 8 Windows Desktop Runtime.' + #13#10 + 'Download: https://dotnet.microsoft.com/en-us/download/dotnet/8.0', mbError, MB_OK, IDOK);
end;

function QuotedAppExe(Param: String): String;
begin
  Result := '"' + ExpandConstant('{app}\KvmSwitcher.exe') + '"';
end;
