unit s3WinAutoUpdate;

interface

uses
  System.SysUtils;

type

  Ts3UpdateEvent = reference to procedure(Sender: TObject; AETag: string);
  Ts3RestartEvent = reference to procedure(Sender: TObject; var aHandled: boolean);
  Ts3UpdateCheckOption = (checkETagOnly, checkBuild, checkFullVersion);
  Ts3UpdateFileOption = (updateExe, updateRunSetup, updateRunSetupSilent);
  TFileVersionPart = (vMajor, vMinor, vRelease, vBuild);
  TFileVersionInfo = array[TFileVersionPart] of word;

  Is3WinAutoUpdate = interface
    function  GetETag: string;
    function  GetFileToReplace: TFilename;
    function  GetUpdateUrl: string;
    procedure SetUpdateUrl(const Value: string);
    function  UpdateAvailable: Boolean;
    procedure DoUpdate(aUpdateOption: Ts3UpdateFileOption = updateExe; aDoRestart: boolean = TRUE; const aOnRestartRequired: Ts3RestartEvent = nil);
    property  UpdateURL: string read GetUpdateUrl write SetUpdateUrl;
    property  FileToReplace : TFilename read GetFileToReplace;
    property  ETag: string read GetETag;
    procedure StartCheck;
    procedure PauseCheck;
  end;

  Ts3AutoUpdateFactory = class
  public
    class function Create(const aUrl: string; const aFileToReplace: TFilename; const ACurrentETag: string; const aIntervalSeconds: integer;
                          const aUpdateAvailableEvent: Ts3UpdateEvent; const aOnCurrentVersionEvent: Ts3UpdateEvent; const aCheckOption : Ts3UpdateCheckOption = checkETagOnly;
                          const AutoStart: boolean = True): Is3WinAutoUpdate;
  end;

implementation

uses
  System.Classes, vcl.Forms, System.Net.HttpClient, System.IOUtils, WinApi.ShellAPi, winApi.Windows, WinApi.Messages,
  System.IniFiles, System.DateUtils, System.StrUtils, vcl.ExtCtrls;

type
  Ts3WinAutoUpdate = class(TInterfacedObject, Is3WinAutoUpdate)
  private
    fTimer: TTimer;
    fUpdateUrl: string;
    fIntervalSeconds: integer;
    fNewFile: string;
    fFileToReplace: TFileName;
    fUpdateAvailable: Boolean;
    fETag: string;
    fCheckOption: Ts3UpdateCheckOption;
    fUpdateAvailableEvent: Ts3UpdateEvent;
    fOnCurrentVersionEvent: Ts3UpdateEvent;
    function  GetUpdateUrl: string;
    procedure SetUpdateUrl(const Value: string);
    function  GetETag: string;
    procedure HandleTimerEvent(Sender: TObject);
    function GetFileToReplace: TFileName;
  public
    constructor Create(const AUrl: string; const aFileToReplace: TFilename; const ACurrentETag: string; const AIntervalSeconds: integer;
      const AUpdateAvailableEvent: Ts3UpdateEvent; const AOnCurrentVersionEvent: Ts3UpdateEvent; const aCheckOption : Ts3UpdateCheckOption = checkETagOnly;
      const AutoStart: boolean = True);
    function  UpdateAvailable: Boolean;
    procedure DoUpdate(aUpdateOption: Ts3UpdateFileOption = updateExe; aDoRestart: boolean = TRUE; const aOnRestartRequired: Ts3RestartEvent = nil);
    property  UpdateUrl: string read GetUpdateUrl write SetUpdateUrl;
    property  FileToReplace: TFileName read GetFileToReplace;
    property  ETag: string read GetETag;
    procedure StartCheck;
    procedure PauseCheck;
    destructor Destroy; override;
  end;

function IsVerHigher(const New : TFileVersionInfo; const Current: TFileVersionInfo) : boolean;
begin
  Result :=
    ((New[vMajor] > Current[vMajor]) OR
    ((New[vMajor] = Current[vMajor]) AND (New[vMinor] > Current[vMinor])) OR
    ((New[vMajor] = Current[vMajor]) AND (New[vMinor] = Current[vMinor]) AND (New[vRelease] > Current[vRelease])) OR
    ((New[vMajor] = Current[vMajor]) AND (New[vMinor] = Current[vMinor]) AND (New[vRelease] = Current[vRelease]) AND (New[vBuild] > Current[vBuild])));
end;

procedure GetApplicationVersion(var FileVer: TFileVersionInfo; const AExe: string = '');
var
	VerInfoSize, VerValueSize, DUMMY: DWORD;
	VerInfo:pointer;
	VerValue: PVSFixedFileInfo;
  AFilename: string;
begin
  try
    FileVer[vMajor] := 0;
    FileVer[vMinor] := 0;
    FileVer[vRelease] := 0;
    FileVer[vBuild] := 0;
    AFileName := AExe;
    if AFileName = '' then AFileName := ParamStr(0);
    if not FileExists(AFilename) then EXIT;
    VerInfoSize := GetFileVersionInfoSize(Pchar(AFilename), DUMMY);
    GetMem(verinfo, verinfosize);
    GetFileVersionInfo(pchar(AFilename),0,VerInfoSize, VerInfo);
    VerQueryValue(VerInfo,'\',Pointer(VerValue), VerValueSize);
    With VerValue^ do
    begin
      FileVer[vMajor] := dwFileVersionMS shr 16;				//Major
      FileVer[vMinor] := dwFileVersionMS and $FFFF;		//Minor
      FileVer[vRelease] := dwFileVersionLS shr 16;				//Release
      FileVer[vBuild] := dwFileVersionLS and $FFFF;    //Build
    end;
    FreeMem(VerInfo, VerInfoSize);
  except
    // corrupt *.exe?
  end;
end;

function GetBuildFromVersionStr(AVersionStr: string): integer;
var
  Vers: TArray<string>;
begin
  result := 0;
  Vers := AVersionStr.Split(['.']);
  if Length(Vers) = 4 then
    result := StrToIntDef(Vers[3], result);
end;

{ Ts3WinAutoUpdate }

constructor Ts3WinAutoUpdate.Create(const aUrl: string; const aFileToReplace: TFilename; const aCurrentETag: string; const aIntervalSeconds: integer;
  const aUpdateAvailableEvent: Ts3UpdateEvent; const aOnCurrentVersionEvent: Ts3UpdateEvent; const aCheckOption: Ts3UpdateCheckOption = checkETagOnly;
  const AutoStart : boolean = True);
begin
  FUpdateAvailable := False;
  FETag := aCurrentETag;
  FUpdateUrl := aUrl;
  FFileToReplace := aFileToReplace;
  FIntervalSeconds := AIntervalSeconds;
  FUpdateAvailableEvent := aUpdateAvailableEvent;
  FOnCurrentVersionEvent := aOnCurrentVersionEvent;
  FCheckOption := aCheckOption;
  FTimer := TTimer.Create(nil);
  // pass in zero or less to use as a one-time operation & no repeat
  if aIntervalSeconds > 0 then
    FTimer.Interval := AIntervalSeconds * 1000
  else
    FTimer.Interval := 10; // 1 ms, i.e. almost immediatement
  FTimer.OnTimer := HandleTimerEvent;
  FTimer.Enabled := AutoStart;
end;

destructor Ts3WinAutoUpdate.Destroy;
begin
  FTimer.Free;
  inherited;
end;

procedure Ts3WinAutoUpdate.DoUpdate(aUpdateOption: Ts3UpdateFileOption = updateExe; aDoRestart: boolean = TRUE; const aOnRestartRequired: Ts3RestartEvent = nil);
var
  RestartHandled : boolean;
  aFileReplaced : boolean;
const
  C_OLD_EXTENSION = '.oldfile';
begin
  RestartHandled := false;
  aFileReplaced := false;
  case aUpdateoption of
    Ts3UpdateFileOption.updateExe:
    begin
        if not TFile.Exists(FNewFile, false) then
        begin
          FUpdateAvailable := False;
          Exit;
        end;
        System.SysUtils.DeleteFile(TPath.ChangeExtension(fFileToReplace, C_OLD_EXTENSION));
        System.SysUtils.RenameFile(fFileToReplace, TPath.ChangeExtension(fFileToReplace, C_OLD_EXTENSION));
        aFileReplaced := CopyFile(PWideChar(FNewFile), PWideChar(fFileToReplace), False);

        if aFileReplaced and aDoRestart then
        begin
          if assigned(aOnRestartRequired) then
            aOnRestartRequired(Self, RestartHandled);
          if not RestartHandled then
          begin
            Sleep(1000);
            ShellExecute(0, nil, PChar(fFileToReplace), nil, nil, SW_SHOWNORMAL);
            System.SysUtils.DeleteFile(FNewFile);
            FNewFile := '';
            FUpdateAvailable := False;
            Sleep(1000);
            PostMessage(Application.MainForm.Handle, WM_QUIT, 0, 0);
          end;
        end;
    end;
    Ts3UpdateFileOption.updateRunSetup: ShellExecute(0, nil, PChar(FNewFile), nil, nil, SW_SHOWNORMAL);
    Ts3UpdateFileOption.updateRunSetupSilent: ShellExecute(0, nil, PChar(FNewFile), PChar('/SILENT'), nil, SW_SHOWNORMAL);
  end;
end;

function Ts3WinAutoUpdate.GetETag: string;
begin
  Result := FETag;
end;

function Ts3WinAutoUpdate.GetFileToReplace: TFileName;
begin
  result := fFileToReplace;
end;

function Ts3WinAutoUpdate.GetUpdateUrl: string;
begin
  Result := FUpdateUrl;
end;

procedure Ts3WinAutoUpdate.SetUpdateUrl(const Value: string);
begin
  FUpdateUrl := Value;
end;

procedure Ts3WinAutoUpdate.StartCheck;
begin
  fTimer.Enabled := TRUE;
end;

procedure Ts3WinAutoUpdate.HandleTimerEvent(Sender: TObject);
var
  AHttp: THttpClient;
  AStream: TMemoryStream;
  AResponse: IHTTPResponse;
  ANewETag : string;
  fAllowUpdate: boolean;
  NewVer, OldVer: TFileVersionInfo;
begin
  FTimer.Enabled := False;
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        AHttp := THTTPClient.Create;
        try
          AResponse := AHttp.Head(FUpdateUrl);
          // strip double quotes around the ETag header
          aNewETag :=  StringReplace(AResponse.HeaderValue['ETag'], '"', '', [rfReplaceAll]);
          if (AResponse.StatusCode = 200) and not SameText(aNewETag, FETag) then
          begin
            AStream := TMemoryStream.Create;
            try
              AResponse := AHttp.Get(FUpdateUrl, AStream);
              if AResponse.StatusCode = 200 then
              begin
                FETag := AResponse.HeaderValue['ETag'];
                FNewFile := TPath.GetTempFileName; // this creates a file.
                System.SysUtils.DeleteFile(FNewFile);
                FNewFile := ChangeFileExt(FNewFile, '.exe');

                if fCheckOption >= TS3UpdateCheckOption.checkBuild then // if we have to check file version info, let's get it
                begin
                  GetApplicationVersion(NewVer, fNewFile);
                  GetApplicationVersion(OldVer, fFileToReplace);
                end;

                case fCheckOption of
                  checkBuild:       fAllowUpdate := (NewVer[vBuild] > OldVer[vBuild]);
                  checkFullVersion: fAllowUpdate := IsVerHigher(NewVer, OldVer);
                  else              fAllowUpdate := TRUE; // default to YES so we just check the ETag for being "different". This allows rollback to older versions.
                end;

                if fAllowUpdate then // tell client about it
                begin
                  FUpdateAvailable := True;
                  TThread.Queue(nil,
                    procedure
                    begin
                      if Assigned(FUpdateAvailableEvent) then
                        FUpdateAvailableEvent(Self, FETag);
                    end
                  );
                end;
              end;
            finally
              AStream.Free;
            end;
          end else
          if (AResponse.StatusCode = 200) and SameText(aNewETag, FETag) then
          begin
            TThread.Queue(nil,
              procedure
              begin
                if assigned(fOnCurrentVersionEvent) then
                  fOnCurrentVersionEvent(self, aNewETag);
              end
            );
          end;
        finally
          AHttp.Free;
        end;
      except
        //
      end;
      if (FUpdateAvailable = False) then
      begin
        TThread.Queue(nil,
          procedure
          begin
            if FIntervalSeconds > 0 then
            begin
              FTimer.Interval := FIntervalSeconds * 1000;
              FTimer.Enabled := True;
            end;
          end
        );
      end;


    end
  ).Start;
end;

procedure Ts3WinAutoUpdate.PauseCheck;
begin
  fTimer.Enabled := false;
end;

function Ts3WinAutoUpdate.UpdateAvailable: Boolean;
begin
  Result := FUpdateAvailable;
end;

{ Ts3AutoUpdateFactory }

class function Ts3AutoUpdateFactory.Create(const AUrl: string; const aFileToReplace: TFilename; const ACurrentETag: string; const AIntervalSeconds: integer;
    const AUpdateAvailableEvent, AOnCurrentVersionEvent: Ts3UpdateEvent; const aCheckOption: Ts3UpdateCheckOption; const AutoStart: boolean): Is3WinAutoUpdate;
begin
  result := Ts3WinAutoUpdate.Create(aUrl, aFileToReplace, aCurrentETag, aIntervalSeconds, aUpdateAvailableEvent, aOnCurrentVersionEvent, aCheckOption, AutoStart);
end;

end.