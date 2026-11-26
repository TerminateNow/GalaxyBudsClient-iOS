using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Serilog;

namespace GalaxyBudsClient.Platform;

/// <summary>
/// iOS: settings of the BudsBridge SpringBoard tweak (package com.galaxybudsclient.noisecc): the battery popup over other
/// apps and the lock screen, and the battery notification. They live in the BudsBridge service's settings file, which the
/// sandboxed app can't write, so they're read and set with the service's <c>PREF &lt;setting&gt; [on|off]</c> command
/// (budsrfcomm 0.5.1 and newer). The service tells the tweak about a change right away. <c>POPUP</c> (0.5.2) shows the
/// tweak's popup, for the app's "Show demo popup".
/// </summary>
public static class BudsBridgeSettings
{
    public const string Popup = "Popup";
    public const string BatteryNotification = "BatteryNotification";

    /// <summary>The service's port. The iOS head points this at the port from the service's settings file.</summary>
    public static Func<int> PortProvider { get; set; } = () => 8762;

    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    /// <returns>The setting, or null if the service can't be reached or doesn't know <c>PREF</c> (older than 0.5.1).</returns>
    public static Task<bool?> GetAsync(string setting) => RequestAsync($"PREF {setting}");

    /// <returns>The setting as the service saved it, or null if that failed.</returns>
    public static Task<bool?> SetAsync(string setting, bool on) => RequestAsync($"PREF {setting} {(on ? "on" : "off")}");

    /// <summary>Asks the SpringBoard tweak to show its popup now (the service's <c>POPUP</c> command, 0.5.2).</summary>
    public static async Task<bool> ShowPopupAsync() => await SendAsync("POPUP") == "OK";

    private static async Task<bool?> RequestAsync(string command)
    {
        // "PREF <setting> <on|off>", else "ERR <reason>"
        var parts = (await SendAsync(command))?.Split(' ');
        if (parts is { Length: 3 } && parts[0] == "PREF")
            return parts[2] == "on";
        return null;
    }

    private static async Task<string?> SendAsync(string command)
    {
        try
        {
            using var cancel = new CancellationTokenSource(Timeout);
            using var client = new TcpClient { NoDelay = true };
            await client.ConnectAsync("127.0.0.1", PortProvider(), cancel.Token);
            await using var stream = client.GetStream();
            await stream.WriteAsync(Encoding.UTF8.GetBytes(command + "\n"), cancel.Token);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var reply = await reader.ReadLineAsync(cancel.Token);
            if (reply == null || reply.StartsWith("ERR"))
                Log.Warning("BudsBridgeSettings: {Command}: {Reply}", command, reply ?? "no answer");
            return reply;
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "BudsBridgeSettings: {Command} failed", command);
        }
        return null;
    }
}
