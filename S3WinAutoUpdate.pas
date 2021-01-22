{$SCOPEDENUMS ON}
unit s3WinAutoUpdate;

interface

uses
  System.SysUtils;

type

  Ts3UpdateEvent = reference to procedure(Sender: TObject; AETag: string);
  Ts3RestartEvent = reference to procedure(Sender: TObject; var aHandled: boolean);
  Ts3UpdateCheckOption = (checkBuild, checkFullVersion);
  Ts3UpdateFileOption = (updateExe, updateRunSetup, updateRunSetupSilent);

  Is3WinAutoUpdate = interface
    function  GetETag: string;
    function  GetFileToReplace: string;
    procedure SetFileToReplace(const Value: TFilename);
    function  GetUpdateUrl: string;
    procedure SetUpdateUrl(const Value: string);
    function  UpdateAvailable: Boolean;
    procedure DoUpdate(aUpdateOption: Ts3UpdateFileOption = Ts3UpdateFileOption.updateExe);
    property  FileToReplace : TFilename read GetFileToReplace write SetFileToReplace;
    property  UpdateURL: string read GetUpdateUrl write SetUpdateUrl;
    property  ETag: string read GetETag;
    procedure StartCheck;
    procedure PauseCheck;
  end;

  Ts3AutoUpdateFactory = class
  public
    class function Create(const aUrl: string; const aFileToReplace: TFilename; const ACurrentETag: string; const aIntervalSeconds: integer;
                          const aUpdateAvailableEvent: Ts3UpdateEvent; const aOnCurrentVersionEvent: Ts3UpdateEvent; const aOnRestartRequired: Ts3RestartEvent;
                          const aCheckOption = [Ts3UpdateCheckOption.checkBuild]): Is3WinAutoUpdate;
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
    fRestartRequired: Ts3RestartEvent;
    function  GetUpdateUrl: string;
    procedure SetUpdateUrl(const Value: string);
    function  GetETag: string;
    procedure HandleTimerEvent(Sender: TObject);
  public
    constructor Create(const AUrl: string; const aFileToReplace: TFilename; const ACurrentETag: string; const AIntervalSeconds: integer;
      const AUpdateAvailableEvent: Ts3UpdateEvent; const AOnCurrentVersionEvent: Ts3UpdateEvent; const OnRestartRequired: Ts3RestartEvent; const aCheckOption = [Ts3UpdateCheckOption.checkBuild];
      const AutoStart: boolean = True);
    function  UpdateAvailable: Boolean;
    procedure DoUpdate(aUpdateOption: Ts3UpdateFileOption = Ts3UpdateFileOption.updateExe);
    property  UpdateUrl: string read GetUpdateUrl write SetUpdateUrl;
    property  ETag: string read GetETag;
    property  FileToReplace: TFileName read fFileToReplace;
    procedure StartCheck;
    procedure PauseCheck;
    destructor Destroy; override;
  end;

procedure GetApplicationVersion(var AMajor, AMinor, ARelease, ABuild: integer; const AExe: string = '');
var
	VerInfoSize, VerValueSize, DUMMY: DWORD;
	VerInfo:pointer;
	VerValue: PVSFixedFileInfo;
  AFilename: string;
begin
  try
    AMajor := 0;
    AMinor := 0;
    ARelease := 0;
    ABuild := 0;
    AFileName := AExe;

    if AFileName = '' then
      AFileName := ParamStr(0);
    if FileExists(AFilename) = False then
      Exit;
    VerInfoSize:=GetFileVersionInfoSize(Pchar(AFilename), DUMMY);
    GetMem(verinfo, verinfosize);
    GetFileVersionInfo(pchar(AFilename),0,VerInfoSize, VerInfo);
    VerQueryValue(VerInfo,'\',Pointer(VerValue), VerValueSize);
    With VerValue^ do
    begin
      AMajor := dwFileVersionMS shr 16;				//Major
      AMinor := dwFileVersionMS and $FFFF;		//Minor
      ARelease := dwFileVersionLS shr 16;				//Release
      ABuild := dwFileVersionLS and $FFFF;    //Build
    end;
    FreeMem(VerInfo, VerInfoSize);
  except
    // corrupt *.exe?
  end;
end;

function GetApplicationBuild(const AExe: string = ''): integer;
var
  v1,v2,v3,v4: integer;
begin
  GetApplicationVersion(v1, v2, v3, v4, AExe);
  Result := v4;
end;

function GetBuildFromVersionStr(AVersionStr: string): integer;
var
  AStrings: TStrings;
begin
  Result := 0;
  AStrings := TStringList.Create;
  try
    AStrings.Text := Trim(StringReplace(AVersionStr, '.', #13, [rfReplaceAll]));
    if AStrings.Count = 0 then
      Exit;
    Result := StrToIntDef(AStrings[AStrings.Count-1], 0);
  finally
    AStrings.Free;
  end;
end;

{ Ts3WinAutoUpdate }

constructor Ts3WinAutoUpdate.Create(const aUrl: string; const aFileToReplace: TFilename; const aCurrentETag: string; const aIntervalSeconds: integer;
  const aUpdateAvailableEvent: Ts3UpdateEvent; const aOnCurrentVersionEvent: Ts3UpdateEvent; const aOnRestartRequired: Ts3RestartEvent; const aCheckOption = [Ts3UpdateCheckOption.checkBuild];
  const AutoStart : boolean = True);
begin
  FUpdateAvailable := False;
  FETag := aCurrentETag;
  FUpdateUrl := aUrl;
  FFileToReplace := aFileToReplace;
  FIntervalSeconds := AIntervalSeconds;
  FUpdateAvailableEvent := aUpdateAvailableEvent;
  FOnCurrentVersionEvent := aOnCurrentVersionEvent;
  FOnRestartRequired := aOnRestartRequired;
  FCheckOption := aCheckOption;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := AIntervalSeconds;
  FTimer.OnTimer := HandleTimerEvent;
  FTimer.Enabled := AutoStart;
end;

destructor Ts3WinAutoUpdate.Destroy;
begin
  FTimer.Free;
  inherited;
end;

procedure Ts3WinAutoUpdate.DoUpdate(aUpdateOption: Ts3UpdateFileOption = Ts3UpdateFileOption.updateExe);
begin

  case aUpdateoption of
    Ts3UpdateFileOption.updateExe:
    begin
        if FNewFile = '' then
        begin
          FUpdateAvailable := False;
          Exit;
        end;
        DeleteFile(ChangeFileExt(ParamStr(0), '.old'));
        RenameFile(ParamStr(0), ChangeFileExt(ParamStr(0), '.old'));
        if CopyFile(PWideChar(FNewFile), PWideChar(ParamStr(0)), False) then
        begin
          Sleep(1000);
          ShellExecute(0, nil, PChar(ParamStr(0)), nil, nil, SW_SHOWNORMAL);
          DeleteFile(FNewFile);
          FNewFile := '';
          FUpdateAvailable := False;
          Sleep(1000);
          PostMessage(Application.MainForm.Handle, WM_QUIT, 0, 0);
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
                FNewFile := ChangeFileExt(TPath.GetTempFileName, '.exe');
                AStream.SaveToFile(FNewFile);
                if (GetApplicationBuild(FNewFile) > GetApplicationBuild) or (FCheckBuild = False) then
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
            FTimer.Interval := FIntervalSeconds*1000;
            FTimer.Enabled := True;
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
  const AUpdateAvailableEvent, AOnCurrentVersionEvent: Ts3UpdateEvent; const aCheckOption): Is3WinAutoUpdate;
begin
//  Result := Ts3WinAutoUpdate.Create(AUrl, AIntervalSeconds, ACurrentETag,  ACheckBuild, AUpdateAvailableEvent, AOnCurrentVersionEvent);
end;

end.