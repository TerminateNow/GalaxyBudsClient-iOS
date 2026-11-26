using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using Avalonia.Logging;
using Avalonia.Threading;
using GalaxyBudsClient.Platform;
using Serilog;
using AvaloniaLevel = Avalonia.Logging.LogEventLevel;
using SerilogLevel = Serilog.Events.LogEventLevel;

namespace GalaxyBudsClient.Utils.Interface;

/// <summary>
/// Diagnostics for platforms where the only feedback is application.log (iOS).
/// <list type="bullet">
/// <item>Forwards Avalonia's own log (render loop exceptions, layout cycles, ...) to Serilog. Without this,
/// Avalonia only writes to Trace, so an exception thrown on every frame shows as a black screen and nothing in the log.</item>
/// <item>A watchdog that logs when the UI thread stops responding, or when it responds but layout and rendering never get
/// a turn (an endless chain of normal-priority dispatcher work).</item>
/// <item>Startup milestones, so the log shows how far the UI got.</item>
/// </list>
/// On for iOS; set GBC_UI_DIAGNOSTICS=1 to turn it on elsewhere.
/// </summary>
public static class UiDiagnostics
{
    private const int StallSeconds = 3;

    public static bool IsEnabled { get; } =
        PlatformUtils.IsIOS || Environment.GetEnvironmentVariable("GBC_UI_DIAGNOSTICS") == "1";

    private static bool _initialized;
    private static long _normalBeat;
    private static long _renderBeat;
    private static int _normalPending;
    private static int _renderPending;

    public static void Init()
    {
        if (!IsEnabled || _initialized)
            return;
        _initialized = true;

        Logger.Sink = new SerilogAvaloniaSink();

        _normalBeat = _renderBeat = Stopwatch.GetTimestamp();
        new Thread(WatchdogLoop) { IsBackground = true, Name = "UiDiagnostics watchdog" }.Start();
        Log.Information("UiDiagnostics: enabled (Avalonia log forwarded, UI thread watchdog running)");
    }

    public static void Milestone(string messageTemplate, params object?[] values)
    {
        if (IsEnabled)
            Log.Information("UI: " + messageTemplate, values);
    }

    private static void WatchdogLoop()
    {
        bool normalStalled = false, renderStalled = false;
        long lastNormalReport = 0, lastRenderReport = 0;

        while (true)
        {
            Thread.Sleep(1000);

            // Only one beat of each kind in the queue at a time, so a stalled thread doesn't pile them up
            if (Interlocked.Exchange(ref _normalPending, 1) == 0)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    Interlocked.Exchange(ref _normalBeat, Stopwatch.GetTimestamp());
                    Interlocked.Exchange(ref _normalPending, 0);
                }, DispatcherPriority.Normal);
            }
            if (Interlocked.Exchange(ref _renderPending, 1) == 0)
            {
                // Runs only once no normal-priority work is waiting, the same condition layout and rendering need
                Dispatcher.UIThread.Post(() =>
                {
                    Interlocked.Exchange(ref _renderBeat, Stopwatch.GetTimestamp());
                    Interlocked.Exchange(ref _renderPending, 0);
                }, DispatcherPriority.Render);
            }

            var now = Stopwatch.GetTimestamp();
            var normalAge = Stopwatch.GetElapsedTime(Interlocked.Read(ref _normalBeat), now).TotalSeconds;
            var renderAge = Stopwatch.GetElapsedTime(Interlocked.Read(ref _renderBeat), now).TotalSeconds;

            if (normalAge >= StallSeconds)
            {
                // Report when it starts, then every 10 seconds while it lasts
                if (!normalStalled || Stopwatch.GetElapsedTime(lastNormalReport, now).TotalSeconds >= 10)
                {
                    Log.Warning("UiDiagnostics: the UI thread hasn't run for {Seconds:F0}s (blocked or stuck in a loop)", normalAge);
                    lastNormalReport = now;
                }
                normalStalled = true;
            }
            else if (normalStalled)
            {
                Log.Information("UiDiagnostics: the UI thread is running again");
                normalStalled = false;
            }

            if (!normalStalled && renderAge >= StallSeconds)
            {
                if (!renderStalled || Stopwatch.GetElapsedTime(lastRenderReport, now).TotalSeconds >= 10)
                {
                    Log.Warning("UiDiagnostics: the UI thread runs, but render-priority work hasn't for {Seconds:F0}s " +
                                "(queued work keeps it busy, so layout and rendering never run)", renderAge);
                    lastRenderReport = now;
                }
                renderStalled = true;
            }
            else if (renderStalled && renderAge < StallSeconds)
            {
                Log.Information("UiDiagnostics: rendering is running again");
                renderStalled = false;
            }
        }
    }

    /// <summary>
    /// Writes Avalonia's warnings and errors to Serilog. Each message is logged at most a few times,
    /// because some (render loop exceptions) repeat on every frame.
    /// </summary>
    private sealed class SerilogAvaloniaSink : ILogSink
    {
        private const int MaxRepeats = 5;
        private readonly ConcurrentDictionary<string, int> _counts = new();

        public bool IsEnabled(AvaloniaLevel level, string area)
        {
            // Binding warnings are frequent and usually harmless; keep their errors only
            return area == LogArea.Binding ? level >= AvaloniaLevel.Error : level >= AvaloniaLevel.Warning;
        }

        public void Log(AvaloniaLevel level, string area, object? source, string messageTemplate)
            => Log(level, area, source, messageTemplate, []);

        public void Log(AvaloniaLevel level, string area, object? source, string messageTemplate,
            params object?[] propertyValues)
        {
            var count = _counts.AddOrUpdate(area + messageTemplate, 1, (_, c) => c + 1);
            if (count > MaxRepeats)
                return;

            var suffix = count == MaxRepeats ? " (repeats; further occurrences not logged)" : string.Empty;
            var exception = propertyValues.OfType<Exception>().FirstOrDefault();
            Serilog.Log.Write((SerilogLevel)(int)level, exception,
                "Avalonia [{Area}] ({Source}): " + messageTemplate + suffix,
                new object?[] { area, source?.GetType().Name ?? "-" }.Concat(propertyValues).ToArray());
        }
    }
}
