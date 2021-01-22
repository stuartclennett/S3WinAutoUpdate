# S3WinAutoUpdate
Auto Updater class for Window apps using Amz S3

### Usage

    // aURL is your S£ URL
    // Application.Exename is the file to replace -- it might be a DLL or other data file.
    // aCurrentTag is loaded from your settings (or defaults to the initial version ETag you deploy)
    // 60 is the interval in seconds that the check will be made, use 0 or less for a one-time check only 
    // Add event handlers for each scenario 
    //   CAUTION, HandleCurrentVersion will be called every <interval> seconds, so make sure it doesn't do much processing, or only does it once per run?
    // checkBuild flags up to check the file version build number (ETag is always checked as different). checkFullVersion will check the full version info)
    // TRUE = auto start.  If FALSE you're responsible for calling StartCheck.  You can use PauseCheck and StartCheck at any point.
    // 
    fAutoUpdater := Ts3AutoUpdateFactory.Create(aURL, Application.Exename, aCurrentTag, 60, HandleUpdateAvailable, HandleCurrentVersion, checkBuild, TRUE);

    procedure TMyForm.HandleUpdateAvailable(Sender: TObject; const aETag: string);
    begin
	MySettings.LatestETag := aETag;
	MySettings.Save;
	fAutoUpdater.DoUpdate(updateExe, TRUE, HandleOnRestartRequired); // pass nil as event handler to have the updater restart for you
    end;
		
    procedure TMyForm.HandleOnRestartRequired(sender: TObject; var aHandled: boolean);
    begin
	aHandled := TRUE;
	MyData.Save;
	MyRestartApplication;
    end;

