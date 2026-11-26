using Avalonia.Controls;
using Avalonia.Threading;
using GalaxyBudsClient.Generated.I18N;
using GalaxyBudsClient.Message;
using GalaxyBudsClient.Message.Decoder;
using GalaxyBudsClient.Model.Constants;
using GalaxyBudsClient.Platform;
using GalaxyBudsClient.Utils.Interface;

namespace GalaxyBudsClient.Interface.Pages;

/// <summary>
/// iOS design: home screen content, used by <see cref="HomePage"/> instead of the desktop layout.
/// Row clicks are handled by HomePage (it navigates to the page named like the row).
/// </summary>
public partial class IosHomeView : UserControl
{
    public IosHomeView()
    {
        InitializeComponent();

        SppMessageReceiver.Instance.ExtendedStatusUpdate += (_, e) => Dispatcher.UIThread.Post(() => ShowNoiseControl(e.NoiseControlMode));
        SppMessageReceiver.Instance.NoiseControlUpdateResponse += (_, mode) => Dispatcher.UIThread.Post(() => ShowNoiseControl(mode));
        Loc.LanguageUpdated += OnLanguageUpdated;
        OnLanguageUpdated();
    }

    private void OnLanguageUpdated()
    {
        SoundHeader.Text = Strings.IosSectionSound.ToUpper();
        ControlsHeader.Text = Strings.IosSectionControls.ToUpper();
        MoreHeader.Text = Strings.IosSectionMore.ToUpper();
        ShowNoiseControl(DeviceMessageCache.Instance.ExtendedStatusUpdate?.NoiseControlMode);
    }

    private void ShowNoiseControl(NoiseControlModes? mode)
    {
        NoiseValue.Text = mode != null && BluetoothImpl.Instance.IsConnected ? mode.Value.GetLocalizedDescription() : string.Empty;
    }
}
