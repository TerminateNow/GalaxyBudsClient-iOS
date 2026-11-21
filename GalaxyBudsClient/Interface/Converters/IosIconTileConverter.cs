using System;
using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using SymbolIconSource = FluentIcons.Avalonia.Fluent.SymbolIconSource;

namespace GalaxyBudsClient.Interface.Converters;

/// <summary>
/// iOS design: picks the colored tile behind a settings row icon, like the iOS Settings app.
/// The color comes from the icon's symbol name, so related settings share a color.
/// </summary>
public class IosIconTileConverter : IValueConverter
{
    public static readonly IosIconTileConverter Instance = new();

    private static readonly IBrush Blue = new ImmutableSolidColorBrush(Color.Parse("#0A84FF"));
    private static readonly IBrush Green = new ImmutableSolidColorBrush(Color.Parse("#30D158"));
    private static readonly IBrush Orange = new ImmutableSolidColorBrush(Color.Parse("#FF9F0A"));
    private static readonly IBrush Red = new ImmutableSolidColorBrush(Color.Parse("#FF453A"));
    private static readonly IBrush Pink = new ImmutableSolidColorBrush(Color.Parse("#FF375F"));
    private static readonly IBrush Purple = new ImmutableSolidColorBrush(Color.Parse("#BF5AF2"));
    private static readonly IBrush Indigo = new ImmutableSolidColorBrush(Color.Parse("#5E5CE6"));
    private static readonly IBrush Teal = new ImmutableSolidColorBrush(Color.Parse("#32ADE6"));
    private static readonly IBrush Gray = new ImmutableSolidColorBrush(Color.Parse("#8E8E93"));

    // First match wins, so more specific names come first
    private static readonly (string Part, IBrush Brush)[] Rules =
    [
        ("Delete", Red), ("Warning", Red), ("Error", Red), ("Bug", Red), ("Reset", Red), ("Power", Red),
        ("Lock", Red), ("Heart", Pink), ("DeviceEq", Pink), ("Color", Pink), ("PaintBrush", Pink),
        ("Bluetooth", Blue), ("Link", Blue), ("Info", Blue), ("Language", Blue), ("Globe", Blue),
        ("Rename", Blue), ("Edit", Blue), ("Download", Blue), ("Cursor", Blue), ("Tag", Blue),
        ("Checkmark", Green), ("Play", Green), ("Flash", Green), ("Gauge", Green), ("Data", Green),
        ("Call", Green), ("Target", Green), ("Location", Green), ("Add", Green),
        ("Tap", Orange), ("Hand", Orange), ("Timer", Orange), ("Hourglass", Orange), ("Lightbulb", Orange),
        ("Keyboard", Orange), ("Toolbox", Orange), ("Wrench", Orange), ("Beaker", Orange), ("Badge", Orange),
        ("Mic", Purple), ("Person", Purple), ("Sound", Purple), ("Speaker", Purple), ("Cube", Purple),
        ("Compass", Purple), ("Headphones", Purple), ("Chat", Purple),
        ("Dark", Indigo), ("Blur", Indigo), ("Image", Indigo), ("Accessibility", Indigo),
        ("Arrow", Teal), ("Layout", Teal), ("DualScreen", Teal), ("Navigation", Teal), ("Apps", Teal),
        ("Previous", Teal), ("Next", Teal), ("Pause", Teal), ("Video", Teal), ("Serial", Gray), ("Window", Gray)
    ];

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not SymbolIconSource source)
            return Gray;

        var name = source.Symbol.ToString();
        foreach (var (part, brush) in Rules)
        {
            if (name.Contains(part, StringComparison.Ordinal))
                return brush;
        }
        return Gray;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>iOS design: section headers are upper case.</summary>
public class IosUpperCaseConverter : IValueConverter
{
    public static readonly IosUpperCaseConverter Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value?.ToString()?.ToUpper(culture);

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
