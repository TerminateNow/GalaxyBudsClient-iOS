using Foundation;
using GalaxyBudsClient.Platform;
using UIKit;

namespace GalaxyBudsClient.iOS.Impl;

public class DesktopServices : BaseDesktopServices
{
    public override bool IsAutoStartEnabled { get; set; } = false;

    public override void OpenUri(string uri)
    {
        var url = NSUrl.FromString(uri);
        if (url == null)
            return;

        UIApplication.SharedApplication.InvokeOnMainThread(() =>
            UIApplication.SharedApplication.OpenUrl(url, new UIApplicationOpenUrlOptions(), null));
    }
}
