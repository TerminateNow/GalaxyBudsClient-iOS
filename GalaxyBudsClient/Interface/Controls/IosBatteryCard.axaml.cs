using System;
using System.ComponentModel;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using GalaxyBudsClient.Generated.I18N;
using GalaxyBudsClient.Interface.ViewModels.Controls;
using GalaxyBudsClient.Message;
using GalaxyBudsClient.Model.Config;
using GalaxyBudsClient.Model.Constants;
using GalaxyBudsClient.Model.Specifications;
using GalaxyBudsClient.Platform;
using GalaxyBudsClient.Utils;
using GalaxyBudsClient.Utils.Interface;
using Serilog;

namespace GalaxyBudsClient.Interface.Controls;

/// <summary>
/// iOS design: battery card on the home screen (see IosBatteryCard.axaml).
/// </summary>
public partial class IosBatteryCard : UserControl
{
    private static readonly IBrush Green = new SolidColorBrush(Color.Parse("#30D158"));
    private static readonly IBrush Red = new SolidColorBrush(Color.Parse("#FF453A"));

    private readonly EarbudStatusUnitViewModel _vm = new();
    private bool _showDetails;

    public IosBatteryCard()
    {
        InitializeComponent();
        DataContext = _vm;

        _vm.PropertyChanged += (_, _) => Update();
        BluetoothImpl.Instance.PropertyChanged += OnBluetoothPropertyChanged;
        Settings.MainSettingsPropertyChanged += OnSettingsChanged;
        Settings.Data.PropertyChanged += OnSettingsChanged;
        Settings.DevicePropertyChanged += OnSettingsChanged;
        Loc.LanguageUpdated += Update;
        Update();
    }

    private void OnBluetoothPropertyChanged(object? sender, PropertyChangedEventArgs e)
        => Dispatcher.UIThread.Post(Update);

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
        => Dispatcher.UIThread.Post(Update);

    private void OnDetailsClicked(object? sender, RoutedEventArgs e)
    {
        _showDetails = !_showDetails;
        Update();
    }

    private void Update()
    {
        var connected = BluetoothImpl.Instance.IsConnected;
        StatusDot.Fill = connected ? Green : Red;
        StatusText.Text = connected ? Strings.IosConnectedBridge : Strings.IosNotConnected;

        SetUnit(LeftLevel, LeftPercent, LeftCaption, LeftUnit, Strings.Left,
            connected ? _vm.LeftBattery : 0, _vm.LeftWearState, _vm.IsLeftOnline);
        SetUnit(RightLevel, RightPercent, RightCaption, RightUnit, Strings.Right,
            connected ? _vm.RightBattery : 0, _vm.RightWearState, _vm.IsRightOnline);

        var supportsCase = BluetoothImpl.Instance.DeviceSpec.Supports(Features.CaseBattery);
        CaseUnit.IsVisible = supportsCase;
        var casePct = connected ? _vm.CaseBattery ?? 0 : 0;
        CaseLevel.SweepAngle = casePct * 3.6;
        CaseLevel.Stroke = casePct <= 20 ? Red : Green;
        CasePercent.Text = connected && _vm.CaseBattery != null ? $"{casePct}%" : "–";
        CaseCaption.Text = Strings.Case;
        CaseUnit.Opacity = connected && _vm.CaseBattery != null ? 1 : 0.4;

        UpdateImages();

        DetailsLabel.Text = _showDetails ? Strings.IosBatteryDetailsHide : Strings.IosBatteryDetailsShow;
        DetailsSign.Text = _showDetails ? "−" : "+";
        Details.IsVisible = _showDetails;

        var unit = Settings.Data.TemperatureUnit == TemperatureUnits.Fahrenheit ? "F" : "C";
        LeftVoltageText.Text = string.Format(Strings.IosVoltage, _vm.LeftVoltage);
        RightVoltageText.Text = string.Format(Strings.IosVoltage, _vm.RightVoltage);
        LeftCurrentText.Text = string.Format(Strings.IosCurrent, _vm.LeftCurrent);
        RightCurrentText.Text = string.Format(Strings.IosCurrent, _vm.RightCurrent);
        LeftTemperatureText.Text = string.Format(Strings.IosTemperature, _vm.LeftTemperature, unit);
        RightTemperatureText.Text = string.Format(Strings.IosTemperature, _vm.RightTemperature, unit);

        var spec = BluetoothImpl.Instance.DeviceSpec;
        LeftVoltageText.IsVisible = RightVoltageText.IsVisible = spec.Supports(Features.Voltage);
        LeftCurrentText.IsVisible = RightCurrentText.IsVisible = spec.Supports(Features.Current);
    }

    private static void SetUnit(Arc level, TextBlock percent, TextBlock caption, Control unit,
        string label, int battery, PlacementStates state, bool online)
    {
        level.SweepAngle = Math.Clamp(battery, 0, 100) * 3.6;
        level.Stroke = battery <= 20 ? Red : Green;
        percent.Text = online ? $"{battery}%" : "–";
        caption.Text = online ? $"{label}\n{state.GetLocalizedDescription()}" : $"{label}\n{Strings.IosNotConnected}";
        unit.Opacity = online ? 1 : 0.4;
    }

    private void UpdateImages()
    {
        // Realistic images when enabled and available for this model and color, line icons otherwise
        var device = BluetoothImpl.Instance.Device.Current;
        var model = device?.Model ?? Models.NULL;
        var color = EarbudIcon.ResolveColor(Settings.Data.ColorOverride,
            device?.DeviceColor ?? DeviceMessageCache.Instance.ExtendedStatusUpdate?.DeviceColor, model);
        var realistic = Settings.Data.RealisticEarbudImages && color != null &&
                        BluetoothImpl.Instance.DeviceSpec.Supports(Features.DeviceColor);

        var left = realistic ? LoadImage($"{color}-0.png") : null;
        var right = realistic ? LoadImage($"{color}-1.png") : null;
        var caseImage = realistic ? LoadImage($"{color}-case.png") : null;

        LeftImage.Source = left;
        RightImage.Source = right;
        CaseImage.Source = caseImage;
        LeftImage.IsVisible = left != null;
        RightImage.IsVisible = right != null;
        CaseImage.IsVisible = caseImage != null;
        LeftLines.IsVisible = left == null;
        RightLines.IsVisible = right == null;
        CaseLines.IsVisible = caseImage == null;
    }

    private static Bitmap? LoadImage(string name)
    {
        var uri = new Uri($"{Program.AvaresUrl}/Resources/Device/Realistic/{name}");
        try
        {
            return AssetLoader.Exists(uri) ? new Bitmap(AssetLoader.Open(uri)) : null;
        }
        catch (Exception ex)
        {
            Log.Warning("IosBatteryCard: cannot load {Name}: {Msg}", name, ex.Message);
            return null;
        }
    }
}
