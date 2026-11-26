using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using Avalonia.Xaml.Interactivity;
using GalaxyBudsClient.Platform;

namespace GalaxyBudsClient.Interface.MarkupExtensions;

/// <summary>
/// Behavior that hides the control if the app is running on non-desktop platforms.
/// </summary>
public class RequiresDesktopBehavior : Behavior<Control>
{
    public static readonly StyledProperty<bool> NotProperty =
        AvaloniaProperty.Register<RequiresDesktopBehavior, bool>(nameof(Not));
    
    public bool Not
    {
        get => GetValue(NotProperty);
        set => SetValue(NotProperty, value);
    }

    public static readonly StyledProperty<bool> AllowIosDesignProperty =
        AvaloniaProperty.Register<RequiresDesktopBehavior, bool>(nameof(AllowIosDesign));

    /// <summary>
    /// Also show the control with the iOS design (<see cref="PlatformUtils.UseIosDesign"/>).
    /// </summary>
    public bool AllowIosDesign
    {
        get => GetValue(AllowIosDesignProperty);
        set => SetValue(AllowIosDesignProperty, value);
    }
    
    /// <inheritdoc />
    protected override void OnAttachedToVisualTree()
    {
        UpdateState();
    }

    private bool IsDesktopLike => PlatformUtils.IsDesktop || (AllowIosDesign && PlatformUtils.UseIosDesign);
    private bool State => (IsDesktopLike && !Not) ||
                          (!IsDesktopLike && Not);
    protected void UpdateState()
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (AssociatedObject is null)
                return;
        
            AssociatedObject.IsVisible = State;
        }, DispatcherPriority.Normal);
    }
}