using Avalonia.Interactivity;
using FluentAvalonia.UI.Controls;
using GalaxyBudsClient.Interface.Services;
using GalaxyBudsClient.Interface.ViewModels.Pages;
using GalaxyBudsClient.Platform;

namespace GalaxyBudsClient.Interface.Pages;

public partial class HomePage : BasePage<HomePageViewModel>
{
    public HomePage()
    {
        InitializeComponent();

        if (PlatformUtils.UseIosDesign)
            Content = new IosHomeView();
        
        AddHandler(FASettingsExpanderItem.ClickEvent, OnSettingsItemClicked);
    }

    private static void OnSettingsItemClicked(object? sender, RoutedEventArgs e)
    {
        if (e.Source is not FASettingsExpanderItem item)
            return;
        
        NavigationService.Instance.Navigate(item.Name);
    }
}
