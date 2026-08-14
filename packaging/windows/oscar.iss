; Inno Setup script for the OSCAR Windows installer.
;
; Chosen over electron-builder's NSIS target, which is built to install an Electron
; app: making it also lay down a 300 MB Java tree, unpack a PostgreSQL prefix, run
; initdb and register two services means a large custom .nsh fighting its per-user
; vs per-machine modes and auto-update assumptions. Inno gives components, a real
; scripting engine with rollback, and unattended flags natively.
;
; Build:  ISCC.exe /DSourceDir=<staged tree> /DAppVersion=3.5.0 oscar.iss

#ifndef AppVersion
  #define AppVersion "3.5.0"
#endif
#ifndef SourceDir
  #define SourceDir "staging\dist"
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif

#define AppName "OSCAR"
#define AppPublisher "Botts Innovative Research, Inc."
#define NodeServiceName "OSCARNode"
#define PgServiceName "OSCARPostgres"

[Setup]
AppId={{7C4B9E2A-3F51-4C8D-9A6E-1D2B8F0A5C73}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\OSCAR
DefaultGroupName=OSCAR
OutputDir={#OutputDir}
OutputBaseFilename=OSCARSetup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
; The payload is a Java tree, a PostgreSQL prefix and a JRE - all 64-bit.
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
; Services and ProgramData both require elevation.
PrivilegesRequired=admin
WizardStyle=modern
UninstallDisplayName={#AppName} {#AppVersion}
LicenseFile={#SourceDir}\licenses\LICENSE.txt
; No code-signing certificate exists yet, so SmartScreen will warn on first run.
; SignTool= is wired up here once one is procured.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "full";   Description: "All-in-one (node, database and desktop client)"
Name: "server"; Description: "Server only (no desktop client)"
Name: "client"; Description: "Desktop client only (connects to a node elsewhere)"
Name: "custom"; Description: "Custom"; Flags: iscustom

[Components]
Name: "server"; Description: "OSCAR node and embedded database"; Types: full server
Name: "client"; Description: "OSCAR desktop client"; Types: full client

[Files]
; --- server component -------------------------------------------------------
Source: "{#SourceDir}\lib\*";      DestDir: "{app}\lib";      Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\pgsql\*";    DestDir: "{app}\pgsql";    Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\jre\*";      DestDir: "{app}\jre";      Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\bin\*";      DestDir: "{app}\bin";      Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\web\*";      DestDir: "{app}\web";      Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\models\*";   DestDir: "{app}\models";   Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\config\*";   DestDir: "{app}\config";   Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\rules\*";    DestDir: "{app}\rules";    Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\documentation\*"; DestDir: "{app}\documentation"; Components: server; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\config.json";     DestDir: "{app}"; DestName: "config.template.json"; Components: server; Flags: ignoreversion
Source: "{#SourceDir}\logback.xml";     DestDir: "{app}"; Components: server; Flags: ignoreversion
Source: "{#SourceDir}\osh-keystore.p12"; DestDir: "{app}"; Components: server; Flags: ignoreversion
Source: "{#SourceDir}\VERSION";          DestDir: "{app}"; Components: server; Flags: ignoreversion
Source: "{#SourceDir}\winsw.exe";        DestDir: "{app}\bin"; DestName: "oscar-node-service.exe"; Components: server; Flags: ignoreversion
Source: "{#SourceDir}\oscar-node.service.xml"; DestDir: "{app}\bin"; DestName: "oscar-node-service.xml"; Components: server; Flags: ignoreversion
Source: "{#SourceDir}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs

; --- client component -------------------------------------------------------
Source: "{#SourceDir}\client\*"; DestDir: "{app}\client"; Components: client; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

[Dirs]
Name: "{commonappdata}\OSCAR\config"; Permissions: service-modify
Name: "{commonappdata}\OSCAR\data";   Permissions: service-modify
Name: "{commonappdata}\OSCAR\logs";   Permissions: service-modify

[Icons]
Name: "{group}\OSCAR";                 Filename: "{app}\client\OSCAR.exe"; Components: client
Name: "{group}\OSCAR Admin Console";   Filename: "http://localhost:8282/sensorhub/admin"; Components: server
Name: "{group}\OSCAR Health Check";    Filename: "{app}\bin\oscarctl.bat"; Parameters: "doctor"; Components: server
Name: "{group}\Uninstall OSCAR";       Filename: "{uninstallexe}"
Name: "{autodesktop}\OSCAR";           Filename: "{app}\client\OSCAR.exe"; Components: client; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Components: client
Name: "exposemqtt";  Description: "Allow MQTT connections from the network (ports 1883 and 8083)"; Components: server; Flags: unchecked

[Run]
Filename: "{app}\bin\oscarctl.bat"; Parameters: "doctor"; Components: server; Flags: runhidden waituntilterminated; StatusMsg: "Verifying the installation..."
Filename: "{app}\client\OSCAR.exe"; Description: "Launch OSCAR"; Components: client; Flags: postinstall nowait skipifsilent

[Code]
var
  AdminPasswordPage: TInputQueryWizardPage;

function IsServerSelected: Boolean;
begin
  Result := WizardIsComponentSelected('server');
end;

{ Runs a command and returns its exit code, or -1 if it could not be launched. }
function RunHidden(const Cmd, Params: String): Integer;
var
  Code: Integer;
begin
  if Exec(Cmd, Params, '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Result := Code
  else
    Result := -1;
end;

function InitializeSetup: Boolean;
begin
  Result := True;
end;

procedure InitializeWizard;
begin
  AdminPasswordPage := CreateInputQueryPage(wpSelectComponents,
    'Administrator Password',
    'Set the password for the OSCAR web interface',
    'This password protects the OSCAR admin console and API. There is no default -' + #13#10 +
    'leave it blank and the installer will generate a random one and record it in' + #13#10 +
    'the installation log.');
  AdminPasswordPage.Add('Password:', True);
  AdminPasswordPage.Add('Confirm:', True);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = AdminPasswordPage.ID) and (not IsServerSelected);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = AdminPasswordPage.ID) and IsServerSelected then
  begin
    if AdminPasswordPage.Values[0] <> AdminPasswordPage.Values[1] then
    begin
      MsgBox('The passwords do not match.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

{ Generates a password when the operator did not supply one. Better a random secret
  they must look up than a well-known default baked into every installation.

  Delegated to the platform RNG rather than the scripting engine's Random(), which is
  not seeded for cryptographic use - and Inno's Pascal Script has no Randomize at all. }
procedure WriteAdminPassword;
var
  Pw, ConfigDir, PwFile: String;
  Lines: TArrayOfString;
begin
  ConfigDir := ExpandConstant('{commonappdata}\OSCAR\config');
  PwFile := ConfigDir + '\admin-password';

  { Never overwrite an existing secret: this may be an upgrade. }
  if FileExists(PwFile) then
    Exit;

  Pw := AdminPasswordPage.Values[0];
  if Pw <> '' then
  begin
    SaveStringToFile(PwFile, Pw + #13#10, False);
    Exit;
  end;

  RunHidden('powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$b = New-Object byte[] 15; ' +
    '[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ' +
    '[Convert]::ToBase64String($b).TrimEnd(''='') -replace ''[/+]'', ''x'' ' +
    '| Set-Content -NoNewline -Path ''' + PwFile + '''"');

  if LoadStringsFromFile(PwFile, Lines) and (GetArrayLength(Lines) > 0) then
    Pw := Trim(Lines[0])
  else
    Pw := '';

  if Pw = '' then
  begin
    MsgBox('Could not generate an administrator password.' + #13#10 +
           'Write one to ' + PwFile + ' before starting the OSCAR node service.',
           mbError, MB_OK);
    Exit;
  end;

  Log('Generated administrator password and saved it to ' + PwFile);
  MsgBox('No password was entered, so one was generated:' + #13#10#13#10 +
         Pw + #13#10#13#10 +
         'It has been saved to:' + #13#10 + PwFile + #13#10#13#10 +
         'Change it after signing in.', mbInformation, MB_OK);
end;

procedure WriteViewerConfig;
var
  ConfigDir, Json: String;
begin
  ConfigDir := ExpandConstant('{commonappdata}\OSCAR\config');
  if FileExists(ConfigDir + '\viewer-config.json') then
    Exit;
  Json :=
    '{' + #13#10 +
    '  "node": {' + #13#10 +
    '    "name": "Local Node",' + #13#10 +
    '    "address": "localhost",' + #13#10 +
    '    "port": 8282,' + #13#10 +
    '    "oshPathRoot": "/sensorhub",' + #13#10 +
    '    "csAPIEndpoint": "/api",' + #13#10 +
    '    "isSecure": false' + #13#10 +
    '  }' + #13#10 +
    '}' + #13#10;
  SaveStringToFile(ConfigDir + '\viewer-config.json', Json, False);
end;

procedure RegisterServices;
var
  App, PgCtl, DataDir, WinSW: String;
  Code: Integer;
begin
  App := ExpandConstant('{app}');
  DataDir := ExpandConstant('{commonappdata}\OSCAR\data');
  PgCtl := App + '\pgsql\bin\pg_ctl.exe';
  WinSW := App + '\bin\oscar-node-service.exe';

  { Create the cluster before registering the service that will start it, so a failure
    here surfaces in the installer rather than as a service that will not start. }
  WizardForm.StatusLabel.Caption := 'Initialising the database (this may take a minute)...';
  Code := RunHidden(App + '\bin\oscarctl.bat', 'init-db');
  if Code <> 0 then
    MsgBox('Database initialisation reported exit code ' + IntToStr(Code) + '.' + #13#10 +
           'Check ' + ExpandConstant('{commonappdata}\OSCAR\logs') + ' for details.',
           mbError, MB_OK);

  { PostgreSQL registers itself with the SCM natively.

    It refuses to run under an account with administrative rights, so the service runs
    as NetworkService, which is unprivileged but can still own its data directory. }
  WizardForm.StatusLabel.Caption := 'Registering the database service...';
  RunHidden('sc.exe', 'delete ' + '{#PgServiceName}');
  Code := RunHidden(PgCtl, 'register -N {#PgServiceName} -D "' + DataDir + '\pgdata" ' +
                           '-S auto -w -t 300');
  if Code <> 0 then
    Log('pg_ctl register returned ' + IntToStr(Code));
  RunHidden('sc.exe', 'config {#PgServiceName} obj= "NT AUTHORITY\NetworkService"');
  RunHidden('icacls.exe', '"' + DataDir + '" /grant "NT AUTHORITY\NetworkService":(OI)(CI)F /T /Q');

  { The node cannot be registered with sc.exe directly - a bare java.exe provides no
    SCM control-message pump and would fail to start with error 1053. WinSW supplies it. }
  WizardForm.StatusLabel.Caption := 'Registering the node service...';
  Code := RunHidden(WinSW, 'install');
  if Code <> 0 then
    { The wrapper is a self-contained .NET 6 build, so a failure here is not a missing
      runtime - most likely a permissions or existing-service problem. }
    MsgBox('Registering the OSCAR node service failed with exit code ' + IntToStr(Code) + '.' + #13#10 +
           'Run this from an elevated prompt to see the error:' + #13#10 +
           '  "' + WinSW + '" install', mbError, MB_OK);

  RunHidden('sc.exe', 'config {#NodeServiceName} depend= {#PgServiceName}');
  RunHidden('sc.exe', 'failure {#NodeServiceName} reset= 300 actions= restart/15000/restart/30000/none');

  WizardForm.StatusLabel.Caption := 'Starting services...';
  RunHidden('sc.exe', 'start {#PgServiceName}');
  RunHidden('sc.exe', 'start {#NodeServiceName}');
end;

procedure AddFirewallRules;
begin
  { Domain and private profiles only - never public. The database is deliberately
    absent: it listens on loopback and is an implementation detail of the node. }
  RunHidden('netsh.exe', 'advfirewall firewall add rule name="OSCAR HTTP (8282)" ' +
            'dir=in action=allow protocol=TCP localport=8282 profile=domain,private');
  if WizardIsTaskSelected('exposemqtt') then
  begin
    RunHidden('netsh.exe', 'advfirewall firewall add rule name="OSCAR MQTT (1883)" ' +
              'dir=in action=allow protocol=TCP localport=1883 profile=domain,private');
    RunHidden('netsh.exe', 'advfirewall firewall add rule name="OSCAR MQTT WebSocket (8083)" ' +
              'dir=in action=allow protocol=TCP localport=8083 profile=domain,private');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if IsServerSelected then
    begin
      WriteAdminPassword;
      WriteViewerConfig;
      RegisterServices;
      AddFirewallRules;
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  App: String;
  Response: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    App := ExpandConstant('{app}');
    { Node first, so it releases the database before the database goes away. }
    RunHidden('sc.exe', 'stop {#NodeServiceName}');
    RunHidden('sc.exe', 'stop {#PgServiceName}');
    if FileExists(App + '\bin\oscar-node-service.exe') then
      RunHidden(App + '\bin\oscar-node-service.exe', 'uninstall');
    RunHidden('sc.exe', 'delete {#NodeServiceName}');
    RunHidden('sc.exe', 'delete {#PgServiceName}');

    RunHidden('netsh.exe', 'advfirewall firewall delete rule name="OSCAR HTTP (8282)"');
    RunHidden('netsh.exe', 'advfirewall firewall delete rule name="OSCAR MQTT (1883)"');
    RunHidden('netsh.exe', 'advfirewall firewall delete rule name="OSCAR MQTT WebSocket (8083)"');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    { Removing a product must not be able to destroy a site's recorded data by
      accident, so this is opt-in and defaults to keeping everything. }
    if DirExists(ExpandConstant('{commonappdata}\OSCAR\data')) then
    begin
      Response := MsgBox('Delete the OSCAR database, recorded video and configuration?' + #13#10#13#10 +
                         ExpandConstant('{commonappdata}\OSCAR') + #13#10#13#10 +
                         'Choose No to keep them for a future reinstall.',
                         mbConfirmation, MB_YESNO or MB_DEFBUTTON2);
      if Response = IDYES then
        DelTree(ExpandConstant('{commonappdata}\OSCAR'), True, True, True);
    end;
  end;
end;
