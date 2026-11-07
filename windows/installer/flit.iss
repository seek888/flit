; Flit 的 Windows 安装包脚本（Inno Setup 6）。
;
; 由 CI 调用：
;   iscc /DAppVersion=1.0.0-preview.2 /DBuildSha=abc1234 windows\installer\flit.iss
;
; 设计取舍：
; - per-user 安装（PrivilegesRequired=lowest），不需要管理员权限、不写 HKLM、不进「程序和功能」的系统级区域。
; - 安装目录 %LOCALAPPDATA%\Programs\Flit，与便携 zip 可以并存（用户二选一）。
; - VC++ 运行库已经在构建产物目录里（CI 的 Bundle VC++ runtime DLLs 步骤），
;   安装包直接随文件带走，用户机器不用预装 Redistributable，避免「找不到 msvcp140.dll」。

#define AppName "Flit"
#define AppPublisher "seek888"
#define AppExeName "flit.exe"
#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef BuildSha
  #define BuildSha "dev"
#endif
; VersionInfoProductVersion 只接受纯数字；pubspec 的版本可能带 -preview.N 后缀，
; CI 会额外传 /DNumericVersion=1.0.0.0。
#ifndef NumericVersion
  #define NumericVersion "1.0.0.0"
#endif

[Setup]
AppId={{6B7B0C1A-2F6E-4C43-9A0E-9C2E8F3B6A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion} ({#BuildSha})
AppPublisher={#AppPublisher}
AppComments=Flutter development workspace for Windows
DefaultDirName={localappdata}\Programs\Flit
DefaultGroupName=Flit
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=FlitSetup-{#AppVersion}-x64
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName} {#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
VersionInfoVersion=1.0.0.0
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=Flit Windows installer
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#NumericVersion}

; 简体中文语言文件随仓库提供（Inno Setup 官方 jrsoftware/issrc 的 Files/Languages/ChineseSimplified.isl）。
; CI 的 choco 安装包只带 Default.isl，所以用脚本目录（ISPP 的 SourcePath）引用仓库内文件；
; 文件不在时退回只装英文，避免编译失败。
#define ChineseIsl SourcePath + "ChineseSimplified.isl"
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(ChineseIsl)
Name: "chinesesimplified"; MessagesFile: "{#ChineseIsl}"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Flit"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\Flit"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,Flit}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Flit 的用户数据不放在安装目录（工具链/工程在 %LOCALAPPDATA%\FlitDesk），
; 卸载只删程序本身，不删工程，避免用户丢代码。
Type: filesandordirs; Name: "{app}"