using Avalonia;
using Avalonia.iOS;
using Foundation;
using GalaxyBudsClient.iOS.Impl;
using GalaxyBudsClient.Platform;
using ReactiveUI.Avalonia;

namespace GalaxyBudsClient.iOS;

[Register("AppDelegate")]
#pragma warning disable CA1711 // Identifiers should not have incorrect suffix
public partial class AppDelegate : AvaloniaAppDelegate<App>
#pragma warning restore CA1711
{
    protected override AppBuilder CustomizeAppBuilder(AppBuilder builder)
    {
        // Logs go to application.log in the app data folder (see PlatformUtils.AppDataPath)
        Program.Startup(false);
        PlatformImpl.InjectExternalBackend(new IosPlatformImplCreator());

        return base.CustomizeAppBuilder(builder)
            .WithInterFont()
            .LogToTrace()
            .UseReactiveUI(_ => { });
    }
}
