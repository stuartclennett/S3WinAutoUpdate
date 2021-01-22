# S3WinAutoUpdate
Auto Updater class for Window apps using Amz S3

### Usage

`fAutoUpdater := Ts3AutoUpdateFactory.Create(aURL, Application.Exename, aCurrentTag, 60, HandleUpdateAvailable, HandleCurrentVersion, checkBuild, TRUE);`

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

- Pass 0 or less as interval for a one-time check
- Pass any filename including the current filename
- 
