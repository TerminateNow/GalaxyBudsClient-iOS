using Avalonia.Interactivity;
using GalaxyBudsClient.Interface.ViewModels.Pages;
using GalaxyBudsClient.Model.Constants;

namespace GalaxyBudsClient.Interface.Pages;

public partial class NoiseControlPage : BasePage<NoiseControlPageViewModel>
{
    public NoiseControlPage()
    {
        InitializeComponent();
    }

    // iOS design: noise control mode rows
    private void OnModeClicked(object? sender, RoutedEventArgs e)
    {
        var mode = (sender as Avalonia.Controls.Control)?.Name switch
        {
            nameof(ModeAnc) => NoiseControlModes.NoiseReduction,
            nameof(ModeAmbient) => NoiseControlModes.AmbientSound,
            _ => NoiseControlModes.Off
        };
        ViewModel?.SetNoiseControlMode(mode);
    }
}
