using System;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media.Transformation;
using Avalonia.Threading;
using GalaxyBudsClient.Model.Config;
using GalaxyBudsClient.Platform;

namespace GalaxyBudsClient.Interface.Controls;

/// <summary>
/// iOS design: the connection popup. iOS has no extra windows, so instead of <c>BudsPopup</c> this card
/// slides down over the top of <see cref="MainView"/> with the battery levels, and hides itself after a few
/// seconds or when tapped. The battery unit's view model follows status updates for as long as the card exists.
/// </summary>
public partial class IosConnectionBanner : UserControl
{
    private static readonly TimeSpan VisibleDuration = TimeSpan.FromSeconds(4);
    private static readonly TimeSpan AnimationDuration = TimeSpan.FromMilliseconds(350);
    private static readonly TransformOperations Hidden = TransformOperations.Parse("translateY(-160px)");
    private static readonly TransformOperations Shown = TransformOperations.Parse("translateY(0px)");

    private readonly DispatcherTimer _hideTimer;
    private int _generation;

    public IosConnectionBanner()
    {
        InitializeComponent();

        Opacity = 0;
        RenderTransform = Hidden;
        Transitions =
        [
            new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(250) },
            new TransformOperationsTransition
            {
                Property = RenderTransformProperty, Duration = AnimationDuration, Easing = new CubicEaseOut()
            }
        ];

        _hideTimer = new DispatcherTimer { Interval = VisibleDuration };
        _hideTimer.Tick += (_, _) => Hide();
        Card.PointerPressed += OnCardPressed;
    }

    public bool IsShown { get; private set; }

    /// <summary>Shows the card, or keeps it up for another few seconds if it's already showing.</summary>
    public void Show()
    {
        Header.Text = MainView.StripAddressSuffix(BluetoothImpl.Instance.DeviceName);
        Header.IsVisible = !Settings.Data.PopupCompact;

        _hideTimer.Stop();
        _hideTimer.Start();
        if (IsShown)
            return;

        IsShown = true;
        var generation = ++_generation;
        IsVisible = true;
        // Let the card be laid out at its hidden position first, so the change below animates
        Dispatcher.UIThread.Post(() =>
        {
            if (generation != _generation)
                return;
            Opacity = 1;
            RenderTransform = Shown;
        }, DispatcherPriority.Background);
    }

    public void Hide()
    {
        _hideTimer.Stop();
        if (!IsShown)
            return;

        IsShown = false;
        var generation = ++_generation;
        Opacity = 0;
        RenderTransform = Hidden;
        DispatcherTimer.RunOnce(() =>
        {
            if (generation == _generation)
                IsVisible = false;
        }, AnimationDuration);
    }

    private void OnCardPressed(object? sender, PointerPressedEventArgs e)
    {
        e.Handled = true;
        Hide();
    }
}
