using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Foundation;
using GalaxyBudsClient.Platform;
using GalaxyBudsClient.Platform.Interfaces;
using GalaxyBudsClient.Platform.Model;
using Serilog;

#pragma warning disable CS0067

namespace GalaxyBudsClient.iOS.Impl;

/// <summary>
/// Bluetooth backend for jailbroken iOS. iOS gives apps no RFCOMM access, so this talks to the
/// BudsBridge service (ios/BudsBridge, package com.galaxybudsclient.budsrfcomm) on 127.0.0.1.
/// <para>
/// Protocol: one command line per TCP connection.
/// <c>LIST</c> answers <c>DEVICE &lt;MAC&gt;\t&lt;0|1&gt;\t&lt;name&gt;</c> lines and <c>END</c>.
/// <c>CONNECT &lt;MAC&gt;</c> answers <c>OK &lt;channel&gt;</c> followed by raw RFCOMM bytes in both
/// directions, or <c>ERR &lt;reason&gt;</c>. The service picks the RFCOMM channel itself.
/// </para>
/// </summary>
public class BridgeBluetoothService : IBluetoothService
{
    private const string Host = "127.0.0.1";
    private const int DefaultPort = 8762;
    private const string BridgeSettingsPath =
        "/var/jb/var/mobile/Library/Preferences/com.galaxybudsclient.budsrfcomm.plist";

    // The first CONNECT to a new device can scan RFCOMM channels for up to a minute
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(90);
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(10);

    private const string ServiceMissingMessage =
        "Cannot reach the BudsBridge service on this iPhone. Make sure the package " +
        "com.galaxybudsclient.budsrfcomm is installed and the jailbreak is active.";
    private const string ConnectionLostMessage =
        "Connection closed. The earbuds are either out of range, in their case, or disconnected.";

    public event EventHandler<BluetoothException>? BluetoothErrorAsync;
    public event EventHandler? Connecting;
    public event EventHandler? Connected;
    public event EventHandler? RfcommConnected;
    public event EventHandler<string>? Disconnected;
    public event EventHandler<byte[]>? NewDataAvailable;

    public bool IsStreamConnected { get; private set; }

    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private readonly object _sessionLock = new();
    private TcpClient? _client;
    private NetworkStream? _stream;
    private CancellationTokenSource? _readCancel;

    internal static int Port
    {
        get
        {
            try
            {
                using var settings = NSDictionary.FromFile(BridgeSettingsPath);
                if (settings?["Port"] is NSNumber port && port.Int32Value is > 0 and < 65536)
                    return port.Int32Value;
            }
            catch (Exception ex)
            {
                Log.Debug(ex, "iOS.BridgeBluetoothService: Cannot read the bridge settings");
            }
            return DefaultPort;
        }
    }

    #region Connection
    public async Task ConnectAsync(string macAddress, string serviceUuid, CancellationToken cancelToken)
    {
        CloseSession();
        Connecting?.Invoke(this, EventArgs.Empty);

        Log.Debug("iOS.BridgeBluetoothService: Connecting to {Mac} through BudsBridge...", macAddress);
        var (client, stream) = await OpenAsync(cancelToken);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancelToken);
            timeout.CancelAfter(ConnectTimeout);

            await WriteLineAsync(stream, $"CONNECT {macAddress}", timeout.Token);
            string reply;
            try
            {
                reply = await ReadLineAsync(stream, timeout.Token)
                        ?? throw new IOException("the service closed the connection");
            }
            catch (OperationCanceledException) when (!cancelToken.IsCancellationRequested)
            {
                throw new BluetoothException(BluetoothException.ErrorCodes.TimedOut,
                    "Connection timed out. Make sure the earbuds are connected to this iPhone and out of their case.");
            }

            if (!reply.StartsWith("OK", StringComparison.Ordinal))
            {
                var reason = reply.StartsWith("ERR ", StringComparison.Ordinal) ? reply[4..] : reply;
                Log.Error("iOS.BridgeBluetoothService: BudsBridge refused the connection: {Reason}", reason);
                throw new BluetoothException(BluetoothException.ErrorCodes.ConnectFailed, DescribeError(reason));
            }

            Log.Debug("iOS.BridgeBluetoothService: RFCOMM open ({Reply})", reply);
            var readCancel = new CancellationTokenSource();
            lock (_sessionLock)
            {
                _client = client;
                _stream = stream;
                _readCancel = readCancel;
                IsStreamConnected = true;
            }
            _ = Task.Run(() => ReadLoop(client, stream, readCancel.Token));
        }
        catch (Exception ex) when (ex is IOException or SocketException)
        {
            client.Dispose();
            Log.Error(ex, "iOS.BridgeBluetoothService: Connection to BudsBridge failed");
            throw new BluetoothException(BluetoothException.ErrorCodes.ConnectFailed,
                "Lost the connection to the BudsBridge service while connecting.");
        }
        catch
        {
            client.Dispose();
            throw;
        }

        RfcommConnected?.Invoke(this, EventArgs.Empty);
    }

    public Task DisconnectAsync()
    {
        Log.Debug("iOS.BridgeBluetoothService: Disconnecting...");
        CloseSession();
        return Task.CompletedTask;
    }

    private void CloseSession()
    {
        lock (_sessionLock)
        {
            _readCancel?.Cancel();
            _readCancel?.Dispose();
            _readCancel = null;
            _stream = null;
            _client?.Dispose();  // closing the TCP connection makes the service close the RFCOMM channel
            _client = null;
            IsStreamConnected = false;
        }
    }

    private static string DescribeError(string reason)
    {
        if (reason == "busy")
            return "Another app is already connected to the earbuds through BudsBridge. Close it and try again.";
        return $"Connection failed: {reason}. Make sure the earbuds are connected to this iPhone and out of their case.";
    }
    #endregion

    #region Transmission
    private async Task ReadLoop(TcpClient client, NetworkStream stream, CancellationToken token)
    {
        var buffer = new byte[4096];
        string? reason = null;
        try
        {
            while (!token.IsCancellationRequested)
            {
                var read = await stream.ReadAsync(buffer, token);
                if (read <= 0)
                {
                    reason = ConnectionLostMessage;
                    break;
                }
                NewDataAvailable?.Invoke(this, buffer.AsSpan(0, read).ToArray());
            }
        }
        catch (OperationCanceledException)
        {
            // DisconnectAsync
        }
        catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException)
        {
            if (!token.IsCancellationRequested)
            {
                Log.Error("iOS.BridgeBluetoothService: Read failed: {Message}", ex.Message);
                reason = ConnectionLostMessage;
            }
        }

        if (reason == null || token.IsCancellationRequested)
            return;

        lock (_sessionLock)
        {
            // Only report if this is still the active session
            if (!ReferenceEquals(_client, client))
                return;
        }
        Log.Warning("iOS.BridgeBluetoothService: Connection closed by BudsBridge");
        CloseSession();
        Disconnected?.Invoke(this, reason);
    }

    public async Task SendAsync(byte[] data)
    {
        NetworkStream? stream;
        lock (_sessionLock)
        {
            stream = _stream;
        }
        if (stream == null)
        {
            throw new BluetoothException(BluetoothException.ErrorCodes.SendFailed, "Not connected to the earbuds.");
        }

        await _sendLock.WaitAsync();
        try
        {
            await stream.WriteAsync(data);
        }
        catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException)
        {
            Log.Error("iOS.BridgeBluetoothService: Send failed: {Message}", ex.Message);
            CloseSession();
            Disconnected?.Invoke(this, "Error while sending data. Connection to the earbuds has been closed.");
        }
        finally
        {
            _sendLock.Release();
        }
    }

    public async Task<BluetoothDevice[]> GetDevicesAsync()
    {
        using var timeout = new CancellationTokenSource(CommandTimeout);
        var (client, stream) = await OpenAsync(timeout.Token);
        using (client)
        {
            var devices = new List<BluetoothDevice>();
            try
            {
                await WriteLineAsync(stream, "LIST", timeout.Token);
                while (await ReadLineAsync(stream, timeout.Token) is { } line && line != "END")
                {
                    // DEVICE <MAC>\t<connected 0/1>\t<name>
                    if (!line.StartsWith("DEVICE ", StringComparison.Ordinal))
                        continue;
                    var parts = line[7..].Split('\t', 3);
                    if (parts.Length < 3)
                        continue;
                    devices.Add(new BluetoothDevice(parts[2], parts[0], parts[1] == "1", true, new BluetoothCoD(0)));
                }
            }
            catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException)
            {
                Log.Error("iOS.BridgeBluetoothService: LIST failed: {Message}", ex.Message);
                throw new BluetoothException(BluetoothException.ErrorCodes.NoAdaptersAvailable,
                    "Cannot get the paired devices from the BudsBridge service.");
            }
            return devices.ToArray();
        }
    }
    #endregion

    #region Bridge protocol helpers
    private static async Task<(TcpClient, NetworkStream)> OpenAsync(CancellationToken token)
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            await client.ConnectAsync(Host, Port, token);
            return (client, client.GetStream());
        }
        catch (Exception ex) when (ex is SocketException or IOException)
        {
            client.Dispose();
            Log.Error("iOS.BridgeBluetoothService: Cannot reach BudsBridge: {Message}", ex.Message);
            throw new BluetoothException(BluetoothException.ErrorCodes.NoAdaptersAvailable, ServiceMissingMessage);
        }
        catch (OperationCanceledException)
        {
            client.Dispose();
            throw new BluetoothException(BluetoothException.ErrorCodes.TimedOut, ServiceMissingMessage);
        }
    }

    private static async Task WriteLineAsync(NetworkStream stream, string line, CancellationToken token)
    {
        await stream.WriteAsync(Encoding.UTF8.GetBytes(line + "\n"), token);
    }

    /// <summary>
    /// Reads one '\n'-terminated line byte by byte, so no RFCOMM bytes after it are consumed.
    /// Returns null if the connection closes first.
    /// </summary>
    private static async Task<string?> ReadLineAsync(NetworkStream stream, CancellationToken token)
    {
        var bytes = new List<byte>(64);
        var one = new byte[1];
        while (bytes.Count < 4096)
        {
            if (await stream.ReadAsync(one, token) <= 0)
                return null;
            if (one[0] == '\n')
                break;
            bytes.Add(one[0]);
        }
        return Encoding.UTF8.GetString(bytes.ToArray()).TrimEnd('\r');
    }
    #endregion
}
