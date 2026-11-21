using System;
using Avalonia;
using Avalonia.iOS;
using Foundation;
using GalaxyBudsClient.iOS.Impl;
using GalaxyBudsClient.Platform;
using ObjCRuntime;
using ReactiveUI.Avalonia;
using Serilog;

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

        // A managed exception that reaches native code aborts the app before Serilog flushes.
        // Write it to application.log first, so crashes can be diagnosed from the log alone.
        Runtime.MarshalManagedException += (_, args) => LogFatal(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => LogFatal(args.ExceptionObject as Exception);

        PlatformImpl.InjectExternalBackend(new IosPlatformImplCreator());

        return base.CustomizeAppBuilder(builder)
            .WithInterFont()
            .LogToTrace()
            .UseReactiveUI(_ => { });
    }

    private static void LogFatal(Exception? ex)
    {
        Log.Fatal(ex, "iOS: Unhandled exception, the app will terminate");
        Log.CloseAndFlush();
    }
}
