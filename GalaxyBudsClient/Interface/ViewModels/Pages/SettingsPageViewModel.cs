using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Threading;
using FluentIcons.Common;
using GalaxyBudsClient.Generated.I18N;
using GalaxyBudsClient.Interface.Pages;
using GalaxyBudsClient.Model.Config;
using GalaxyBudsClient.Platform;
using ReactiveUI;

namespace GalaxyBudsClient.Interface.ViewModels.Pages;

public partial class SettingsPageViewModel : MainPageViewModelBase
{
    public SettingsPageViewModel()
    {
        CanManageDevices = BluetoothImpl.HasValidDevice;
        BluetoothImpl.Instance.Device.DeviceChanged += OnDeviceChanged;
        BluetoothImpl.Instance.Connected += (_, _) => RefreshMultipointState();
        BluetoothImpl.Instance.Disconnected += (_, _) => RefreshMultipointState();
        RefreshMultipointState();
    }

    private void OnDeviceChanged(object? sender, Device? e)
    {
        CanManageDevices = BluetoothImpl.HasValidDevice;
        RefreshMultipointState();
    }

    /* Disconnection events arrive on the Bluetooth backend's thread, so bounce back to the UI thread */
    public void RefreshMultipointState() => Dispatcher.UIThread.Post(() =>
    {
        IsMultipointSupported = MultipointPatcher.IsSupportedByCurrentDevice;
        CanApplyMultipoint = IsMultipointSupported && BluetoothImpl.Instance.IsConnected;
    });

    public bool IsAutoStartEnabled
    {
        get => PlatformUtils.IsRunningInFlatpak
            ? Settings.Data.FlatpakAutoStartEnabled
            : PlatformImpl.DesktopServices.IsAutoStartEnabled;
        set
        {
            PlatformImpl.DesktopServices.IsAutoStartEnabled = value;
            if (PlatformUtils.IsRunningInFlatpak)
                Settings.Data.FlatpakAutoStartEnabled = value;
            this.RaisePropertyChanged();
        }
    }
    
    /* iOS: settings of the BudsBridge SpringBoard tweak (the popup over other apps and the lock screen, and the battery
       notification). They're kept by the BudsBridge service, read when the page opens and saved through it. */
    public bool IsBudsBridgeSettingsVisible => PlatformUtils.IsIOS;
    [Reactive] private bool _isBudsBridgeSettingsAvailable;
    private bool _systemPopupEnabled = true;
    private bool _batteryNotificationEnabled = true;
    private bool _loadingBudsBridgeSettings;

    public bool SystemPopupEnabled
    {
        get => _systemPopupEnabled;
        set => SetBudsBridgeSetting(ref _systemPopupEnabled, value, BudsBridgeSettings.Popup);
    }

    public bool BatteryNotificationEnabled
    {
        get => _batteryNotificationEnabled;
        set => SetBudsBridgeSetting(ref _batteryNotificationEnabled, value, BudsBridgeSettings.BatteryNotification);
    }

    private void SetBudsBridgeSetting(ref bool field, bool value, string setting, [CallerMemberName] string? property = null)
    {
        if (field == value)
            return;
        field = value;
        this.RaisePropertyChanged(property);
        if (!_loadingBudsBridgeSettings)
            _ = SaveBudsBridgeSettingAsync(setting, value);
    }

    private async Task SaveBudsBridgeSettingAsync(string setting, bool value)
    {
        if (await BudsBridgeSettings.SetAsync(setting, value) != value)
            await LoadBudsBridgeSettingsAsync();  // not saved: show what the service has
    }

    private async Task LoadBudsBridgeSettingsAsync()
    {
        if (!IsBudsBridgeSettingsVisible)
            return;
        var popup = await BudsBridgeSettings.GetAsync(BudsBridgeSettings.Popup);
        var notification = await BudsBridgeSettings.GetAsync(BudsBridgeSettings.BatteryNotification);
        Dispatcher.UIThread.Post(() =>
        {
            _loadingBudsBridgeSettings = true;
            // Without the service (or with one older than 0.5.1) the switches are shown off and can't be changed
            IsBudsBridgeSettingsAvailable = popup != null && notification != null;
            SystemPopupEnabled = popup ?? false;
            BatteryNotificationEnabled = notification ?? false;
            _loadingBudsBridgeSettings = false;
        });
    }

    public override void OnNavigatedTo()
    {
        base.OnNavigatedTo();
        _ = LoadBudsBridgeSettingsAsync();
    }

    [Reactive] private object _canManageDevices = false;
    [Reactive] private bool _isMultipointSupported;
    [Reactive] private bool _canApplyMultipoint;
    
    public string CurrentVersion => Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "Unknown";
    public override Control CreateView() => new SettingsPage { DataContext = this };

    public override string TitleKey => Keys.SettingsHeader;
    public override Symbol IconKey => Symbol.Settings;
    public override bool ShowsInFooter => true;
}
