using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Avalonia.Controls.Platform;
using Avalonia.Data;
using FluentAvalonia.UI.Controls;
using FluentAvalonia.UI.Navigation;
using FluentAvalonia.UI.Windowing;
using FluentIcons.Common;
using GalaxyBudsClient.Generated.I18N;
using GalaxyBudsClient.Interface.Controls;
using GalaxyBudsClient.Interface.Dialogs;
using GalaxyBudsClient.Interface.Services;
using GalaxyBudsClient.Interface.ViewModels;
using GalaxyBudsClient.Interface.ViewModels.Pages;
using GalaxyBudsClient.Model.Config;
using GalaxyBudsClient.Platform;
using GalaxyBudsClient.Utils.Interface;
using Serilog;
using SymbolIconSource = FluentIcons.Avalonia.Fluent.SymbolIconSource;

namespace GalaxyBudsClient.Interface;

public partial class MainView : UserControl
{
    public static MainView? Instance { get; private set; }

    private MainViewViewModel? ViewModel => DataContext as MainViewViewModel;
    private PageViewModelBase? CurrentPageViewModel { set; get; }
    private bool _staticEventsSubscribed;
    private bool _attached;
    private bool _navigationPagesReady;

    private readonly MainPageViewModelBase[] _mainPages = [
        new WelcomePageViewModel(),
        new HomePageViewModel(),
        new NoiseControlPageViewModel(),
        new EqualizerPageViewModel(),
        new SpatialAudioPageViewModel(),
        new FindMyBudsPageViewModel(),
        new TouchpadPageViewModel(),
        new AdvancedPageViewModel(),
        new SystemPageViewModel(),
        new DevicesPageViewModel(),
        new SettingsPageViewModel()
    ];

    private readonly SubPageViewModelBase[] _subPages =
    [
        new AmbientCustomizePageViewModel(),
        new BixbyRemapPageViewModel(),
        new FirmwarePageViewModel(),
        new FitTestPageViewModel(),
        new HotkeyPageViewModel(),
        new SystemInfoPageViewModel(),
        new RenamePageViewModel(),
        new FmmConfigPageViewModel(),
        new UsageReportPageViewModel(),
        new BatteryHistoryPageViewModel(),
        new HiddenModePageViewModel()
    ];
    
    public MainView()
    {
        InitializeComponent();
        Instance = this;
        
        var vm = new MainViewViewModel
        {
            VmResolver = ResolveViewModelByType
        };
        vm.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(MainViewViewModel.IsInSetupWizard))
                CheckSetupWizardState();
        };
        DataContext = vm;
        FrameView.NavigationPageFactory = vm.NavigationFactory;

        InitializeNavigationPages();
        
        if (PlatformUtils.UseIosDesign)
            InitializeIosShell();

        FABreadcrumbBar.ItemClicked += OnBreadcrumbBarItemClicked;
        FrameView.Navigated += OnFrameViewNavigated;
        NavView.ItemInvoked += OnNavigationViewItemInvoked;
        NavView.BackRequested += OnNavigationViewBackRequested;
        UiDiagnostics.Milestone("MainView created (iOS design: {IosDesign})", PlatformUtils.UseIosDesign);
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);

        Instance = this;
        NavigationService.Instance.Frame = FrameView;
        _attached = true;
        SubscribeStaticEvents();
        OnLanguageUpdated();

        var insetsManager = TopLevel.GetTopLevel(this)?.InsetsManager;
        if (insetsManager != null && (PlatformUtils.IsAndroid || PlatformUtils.IsIOS))
        {
            insetsManager.DisplayEdgeToEdgePreference = true;
        }
        if (insetsManager != null && PlatformUtils.UseIosDesign)
        {
            insetsManager.SafeAreaChanged -= OnSafeAreaChanged;
            insetsManager.SafeAreaChanged += OnSafeAreaChanged;
            ApplySafeArea(insetsManager.SafeAreaPadding);
        }

        var topLevel = TopLevel.GetTopLevel(this);
        UiDiagnostics.Milestone("MainView attached (size {Size}, safe area {SafeArea})",
            topLevel?.ClientSize, insetsManager?.SafeAreaPadding);
        topLevel?.RequestAnimationFrame(_ => UiDiagnostics.Milestone("First frame tick after attach"));
        LayoutUpdated += OnFirstLayoutUpdated;

        NavigateToStartPageIfNeeded();
    }

    private void OnFirstLayoutUpdated(object? sender, EventArgs e)
    {
        LayoutUpdated -= OnFirstLayoutUpdated;
        UiDiagnostics.Milestone("First layout pass done (bounds {Bounds})", Bounds);
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _attached = false;
        UnsubscribeStaticEvents();
        NavigationService.Instance.ClearFrame(FrameView);

        if (ReferenceEquals(Instance, this))
            Instance = null;

        base.OnDetachedFromVisualTree(e);
    }

    private void SubscribeStaticEvents()
    {
        if (_staticEventsSubscribed)
            return;

        Loc.LanguageUpdated += OnLanguageUpdated;
        Settings.MainSettingsPropertyChanged += OnMainSettingsPropertyChanged;
        _staticEventsSubscribed = true;
    }

    private void UnsubscribeStaticEvents()
    {
        if (!_staticEventsSubscribed)
            return;

        Loc.LanguageUpdated -= OnLanguageUpdated;
        Settings.MainSettingsPropertyChanged -= OnMainSettingsPropertyChanged;
        _staticEventsSubscribed = false;
    }

    private void OnMainSettingsPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SettingsData.ShowSidebar))
        {
            RefreshSidebarState();
            RefreshSidebarItemStates();
        }
    }

    private void OnLanguageUpdated()
    {
        FlowDirection = Loc.ResolveFlowDirection();
    }

    public T? ResolveViewModelByType<T>() where T : PageViewModelBase
    {
        return ResolveViewModelByType(typeof(T)) as T;
    }

    private PageViewModelBase? ResolveViewModelByType(Type arg)
    {
        return _mainPages.Concat<PageViewModelBase>(_subPages).FirstOrDefault(p => p.GetType() == arg);
    }

    private void OnBreadcrumbBarItemClicked(FABreadcrumbBar sender, FABreadcrumbBarItemClickedEventArgs args)
    {
        if(ViewModel == null)
            return;
        
        // Ignore the last item, as it's the current page
        if (args.Index < ViewModel.BreadcrumbItems.Count - 1)
        {
            var vm = ViewModel.BreadcrumbItems[args.Index];
            
            // Remove BreadcrumbItems from the end until the clicked item is the last one
            for(var i = ViewModel.BreadcrumbItems.Count - 1; i >= 0; i--)
            {
                if (ViewModel.BreadcrumbItems[i] == vm)
                {
                    break;
                }
                
                ViewModel.BreadcrumbItems.RemoveAt(i);
            }
            NavigationService.Instance.Navigate(vm.PageType);
            
            // Also remove the items from the FrameView's back stack
            for(var i = FrameView.BackStack.Count - 1; i >= 0; i--)
            {
                var stop = FrameView.BackStack[i].SourcePageType == vm.PageType;
                
                FrameView.BackStack.RemoveAt(i);
                
                if (stop)
                {
                    break;
                }
            }
        }
    }

    protected override void OnLoaded(RoutedEventArgs e)
    {
        base.OnLoaded(e);

        if (VisualRoot is FAAppWindow aw)
        {
            // FA3 removed TitleBar.RightInset; use the window decoration margin so the
            // reserved caption area follows the platform, DPI and current window state.
            TitleBarHost.ColumnDefinitions[1].Width =
                new GridLength(aw.WindowDecorationMargin.Right, GridUnitType.Pixel);
        }
    }
    
    private void CheckSetupWizardState()
    {
        foreach (var item in NavView.MenuItemsSource)
        {
            if(item is not FANavigationViewItem nvi)
                continue;

            if(nvi.Tag is WelcomePageViewModel)
                nvi.IsVisible = ViewModel?.IsInSetupWizard == true;
            else
                nvi.IsVisible = ViewModel?.IsInSetupWizard == false;
        }
        
        foreach (var item in NavView.FooterMenuItemsSource)
        {
            if(item is not FANavigationViewItem nvi)
                continue;

            if (nvi.Tag is not SettingsPageViewModel)
                nvi.IsEnabled = ViewModel?.IsInSetupWizard == false;
        }
        
        if (ViewModel?.IsInSetupWizard == true && CurrentPageViewModel is not WelcomePageViewModel)
        {
            NavigationService.Instance.Navigate(typeof(WelcomePageViewModel));
        }
        else if (ViewModel?.IsInSetupWizard == false && CurrentPageViewModel is WelcomePageViewModel)
        {
            NavigationService.Instance.Navigate(typeof(HomePageViewModel));
        }
    }
    
    private void RefreshSidebarState()
    {
        if (PlatformUtils.UseIosDesign)
            return; // no sidebar: navigation happens through the home screen and the navigation bar

        NavView.Classes.Set("AppNav", Settings.Data.ShowSidebar);
        NavView.Classes.Set("MobileContentContainer", true);
        NavView.PaneDisplayMode = Settings.Data.ShowSidebar ? 
            FANavigationViewPaneDisplayMode.Left : FANavigationViewPaneDisplayMode.LeftMinimal;
    }

    private void RefreshSidebarItemStates()
    {
        foreach(var nvi in NavView.MenuItemsSource.Cast<FANavigationViewItem>()
                    .Concat(NavView.FooterMenuItemsSource.Cast<FANavigationViewItem>()))
        {
            nvi.Classes.Set("AppNav", Settings.Data.ShowSidebar);
        }
    }
    
    private void InitializeNavigationPages()
    {
        RefreshSidebarState();
            
        Dispatcher.UIThread.Post(() =>
        {   
            var menuItems = new List<FANavigationViewItem>(14);
            var footerItems = new List<FANavigationViewItem>(2);
            
            foreach (var page in _mainPages)
            {
                var nvi = new FANavigationViewItem
                {
                    Content = Loc.ResolveOrDefault(page.TitleKey) ?? page.FallbackTitle,
                    Tag = page,
                    IconSource = new SymbolIconSource { Symbol = page.IconKey }
                };

                nvi.Classes.Set("AppNav", Settings.Data.ShowSidebar);

                if (page.ShowsInFooter)
                    footerItems.Add(nvi);
                else
                    menuItems.Add(nvi);
            }

            NavView.MenuItemsSource = menuItems;
            NavView.FooterMenuItemsSource = footerItems;
            _navigationPagesReady = true;
            CheckSetupWizardState();
            NavigateToStartPageIfNeeded();
        }, DispatcherPriority.Render);
    }

    /// <summary>
    /// Shows the first page (Welcome in setup mode, Home otherwise). That needs both the navigation items, created by the
    /// job posted from the constructor, and NavigationService.Frame, set when the view is attached; NavigationService drops
    /// navigation while it has no frame. Either can happen first: on iOS the posted job can run before the view is attached,
    /// which left the app on an empty (black) main view. So both call this, and the second one navigates.
    /// </summary>
    private void NavigateToStartPageIfNeeded()
    {
        if (!_navigationPagesReady || !_attached || FrameView.Content != null)
            return;

        UiDiagnostics.Milestone("Showing the start page (setup wizard: {Wizard})", ViewModel?.IsInSetupWizard);
        NavigationService.Instance.Navigate(ViewModel?.IsInSetupWizard == true
            ? typeof(WelcomePageViewModel)
            : typeof(HomePageViewModel));
    }

    private void OnNavigationViewBackRequested(object? sender, FANavigationViewBackRequestedEventArgs e)
        => GoBack();

    private void GoBack()
    {
        if (!FrameView.CanGoBack)
            return;

        /* Pressing back on a main page: remove all items until a MainPageViewModel is found
           We don't want to return to a sub page. The back button mostly behaves like an up button. */

        if (CurrentPageViewModel is MainPageViewModelBase)
        {
            for (var i = FrameView.BackStack.Count - 1; i >= 0; i--)
            {
                if (FrameView.BackStack[i].SourcePageType.IsSubclassOf(typeof(MainPageViewModelBase)))
                    break;

                Log.Error("Removed {Page}", FrameView.BackStack[i].SourcePageType);
                FrameView.BackStack.RemoveAt(i);
            }
        }

        FrameView.GoBack();
    }

    private void OnNavigationViewItemInvoked(object? sender, FANavigationViewItemInvokedEventArgs e)
    {
        if (e.InvokedItemContainer is not FANavigationViewItem nvi) 
            return;

        if (nvi.Tag == null)
            throw new InvalidOperationException("Tag is null");
            
        NavigationService.Instance.NavigateFromContext(nvi.Tag, e.RecommendedNavigationTransitionInfo);
    }
    
    private void OnFrameViewNavigated(object? sender, FANavigationEventArgs e)
    {
        CurrentPageViewModel?.OnNavigatedFrom();

        var control = e.Content as Control;
        var page = control?.DataContext as PageViewModelBase;
        UiDiagnostics.Milestone("Navigated to {Page}", page?.GetType().Name ?? control?.GetType().Name);

        if (page is MainPageViewModelBase)
        {
            if (page is HomePageViewModel or WelcomePageViewModel)
            {
                FrameView.BackStack.Clear();
            }

            ViewModel?.BreadcrumbItems.Clear();
        }
        
        if (page != null)
        {
            if (e.NavigationMode == FANavigationMode.New || page is MainPageViewModelBase) 
                ViewModel?.BreadcrumbItems.Add(new BreadcrumbViewModel(page.TitleKey, page.GetType()));
            else if (e.NavigationMode == FANavigationMode.Back && ViewModel?.BreadcrumbItems.Count > 0)
                ViewModel?.BreadcrumbItems.RemoveAt(ViewModel.BreadcrumbItems.Count - 1);
        }
        
        foreach (FANavigationViewItem nvi in NavView.MenuItemsSource)
        {
            if (nvi.Tag == page)
            {
                NavView.SelectedItem = nvi;
                SetNvIcon(nvi, true);
            }
            else
            {
                SetNvIcon(nvi, false);
            }
        }

        foreach (FANavigationViewItem nvi in NavView.FooterMenuItemsSource)
        {
            if (nvi.Tag == page)
            {
                NavView.SelectedItem = nvi;
                SetNvIcon(nvi, true);
            }
            else
            {
                SetNvIcon(nvi, false);
            }
        }

        CurrentPageViewModel = page;
        page?.OnNavigatedTo();
        
        if (PlatformUtils.UseIosDesign)
        {
            UpdateIosNavBar(page);
        }
        else if (FrameView.BackStackDepth > 0 && !NavView.IsBackButtonVisible)
        {
            NavView.IsBackButtonVisible = true;
        }
        else if (FrameView.BackStackDepth == 0 && NavView.IsBackButtonVisible)
        {
            NavView.IsBackButtonVisible = false;
        }
    }

    #region iOS design
    private ScrollViewer? _iosScrollViewer;

    private void InitializeIosShell()
    {
        // Minimal pane with its toggle hidden: no sidebar. (IsPaneVisible = false makes FANavigationView
        // loop forever in layout, so don't use it.)
        NavView.PaneDisplayMode = FANavigationViewPaneDisplayMode.LeftMinimal;
        NavView.IsPaneToggleButtonVisible = false;
        NavView.IsBackButtonVisible = false;
        FABreadcrumbBar.IsVisible = false;
        IosNavBar.IsVisible = true;
        IosLargeTitle.IsVisible = true;
        IosLargeTitle.IsHitTestVisible = false;

        // Collapsing on scroll: the header height and the two titles animate (SetIosTitleCollapsed)
        var duration = TimeSpan.FromMilliseconds(250);
        IosNavBar.Transitions =
            [new DoubleTransition { Property = HeightProperty, Duration = duration, Easing = new CubicEaseOut() }];
        IosLargeTitle.Transitions =
            [new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(150) }];
        IosInlineTitle.Transitions =
            [new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(200), Delay = TimeSpan.FromMilliseconds(50) }];

        // The disconnect warning floats at the bottom, over the page, instead of taking a row under the header.
        // In that row, even closed, it kept its top margin and left an empty strip below the header.
        Grid.SetRow(DisconnectedInfoBar, 3);
        DisconnectedInfoBar.ZIndex = 10;
        DisconnectedInfoBar.VerticalAlignment = VerticalAlignment.Bottom;
        DisconnectedInfoBar.Margin = new Thickness(16, 0, 16, 16);
        DisconnectedInfoBar[!IsVisibleProperty] = DisconnectedInfoBar[!FAInfoBar.IsOpenProperty];
        DisconnectedInfoBar[!BackgroundProperty] = DisconnectedInfoBar.GetResourceObservable("IosBannerBrush").ToBinding();
        DisconnectedInfoBar.Effect = new DropShadowEffect { BlurRadius = 16, OffsetY = 2, Color = Color.Parse("#80000000") };
        // The connection popup: a card that slides down over the header (App.ShowPopup)
        _connectionBanner = new IosConnectionBanner { ZIndex = 20, Margin = new Thickness(10, 6, 10, 0) };
        Grid.SetRowSpan(_connectionBanner, 4);
        ContentContainer.Children.Add(_connectionBanner);
        // ApplySafeArea places the header and content itself. Avalonia's automatic safe area padding (on by default)
        // would inset the whole view by the status bar a second time, leaving a gap above the header.
        TopLevel.SetAutoSafeAreaPadding(this, false);
        this[!BackgroundProperty] = this.GetResourceObservable("IosBackgroundBrush").ToBinding();
        BluetoothImpl.Instance.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(BluetoothImpl.DeviceName))
                Dispatcher.UIThread.Post(() => UpdateIosNavBar(CurrentPageViewModel));
        };
    }

    private void OnSafeAreaChanged(object? sender, SafeAreaChangedArgs e) => ApplySafeArea(e.SafeAreaPadding);

    private void ApplySafeArea(Thickness padding)
    {
        // Keep the navigation bar below the status bar and the content above the home indicator
        IosNavBar.Margin = new Thickness(padding.Left + 8, padding.Top, padding.Right + 8, 0);
        ContentContainer.Margin = new Thickness(0, 0, 0, padding.Bottom);
        if (_connectionBanner != null)
            _connectionBanner.Margin = new Thickness(padding.Left + 10, padding.Top + 6, padding.Right + 10, 0);
    }

    private IosConnectionBanner? _connectionBanner;

    /// <summary>
    /// iOS design: shows the connection popup card with the battery levels. False if there's no card
    /// (not the iOS design).
    /// </summary>
    public bool ShowConnectionBanner()
    {
        if (_connectionBanner == null)
            return false;
        _connectionBanner.Show();
        return true;
    }

    private static string ResolveTitle(PageViewModelBase? page)
    {
        if (page == null)
            return string.Empty;
        if (page is HomePageViewModel)
            return StripAddressSuffix(BluetoothImpl.Instance.DeviceName);
        return Loc.ResolveOrDefault(page.TitleKey) ?? page.FallbackTitle;
    }

    // "Galaxy Buds3 Pro (0D81)" -> "Galaxy Buds3 Pro": the buds add the end of their address to the Bluetooth name
    private static readonly Regex AddressSuffix = new(@"\s*\([0-9A-Fa-f]{4}\)\s*$", RegexOptions.Compiled);

    internal static string StripAddressSuffix(string name)
    {
        var stripped = AddressSuffix.Replace(name, string.Empty);
        return stripped.Length > 0 ? stripped : name;
    }

    private void UpdateIosNavBar(PageViewModelBase? page)
    {
        var title = ResolveTitle(page);
        IosLargeTitle.Text = title;
        IosInlineTitle.Text = title;

        IosBackButton.IsVisible = FrameView.CanGoBack && page is not (HomePageViewModel or WelcomePageViewModel);
        IosSettingsButton.IsVisible = page is HomePageViewModel or WelcomePageViewModel;
        // The large title shares the row with the back chevron; without it, it lines up with the content (20 pt)
        IosLargeTitle.Margin = new Thickness(IosBackButton.IsVisible ? 4 : 12, 0, 4, 0);

        SetIosTitleCollapsed(false);
        if (_iosScrollViewer != null)
            _iosScrollViewer.ScrollChanged -= OnIosScrollChanged;
        _iosScrollViewer = null;

        // The large title collapses into the navigation bar once the page is scrolled
        Dispatcher.UIThread.Post(() =>
        {
            _iosScrollViewer = (FrameView.Content as Control)?.GetVisualDescendants().OfType<ScrollViewer>().FirstOrDefault();
            if (_iosScrollViewer != null)
                _iosScrollViewer.ScrollChanged += OnIosScrollChanged;
        }, DispatcherPriority.Loaded);
    }

    private void OnIosScrollChanged(object? sender, ScrollChangedEventArgs e)
    {
        // Only react to the user scrolling, not to the viewport resizing when the title collapses,
        // and use separate thresholds so the two can't trigger each other back and forth
        if (sender is not ScrollViewer sv || e.OffsetDelta.Y == 0)
            return;
        if (sv.Offset.Y > 40)
            SetIosTitleCollapsed(true);
        else if (sv.Offset.Y < 4)
            SetIosTitleCollapsed(false);
    }

    private const double IosNavBarExpanded = 52;
    private const double IosNavBarCollapsed = 40;
    private bool _iosTitleCollapsed;

    private void SetIosTitleCollapsed(bool collapsed)
    {
        if (_iosTitleCollapsed == collapsed)
            return;
        _iosTitleCollapsed = collapsed;
        // The large title fades out while the small one fades in and the header shrinks from 52 to 40 pt
        // (transitions set in InitializeIosShell). The large title stays in the layout at opacity 0.
        IosLargeTitle.Opacity = collapsed ? 0 : 1;
        IosInlineTitle.Opacity = collapsed ? 1 : 0;
        IosNavBar.Height = collapsed ? IosNavBarCollapsed : IosNavBarExpanded;
    }

    private void OnIosBackClicked(object? sender, RoutedEventArgs e) => GoBack();

    private void OnIosSettingsClicked(object? sender, RoutedEventArgs e)
        => NavigationService.Instance.Navigate(typeof(SettingsPageViewModel));
    #endregion

    private static void SetNvIcon(FANavigationViewItem? item, bool selected)
    {
        var t = item?.Tag;

        if (t is ViewModelBase && item?.IconSource is SymbolIconSource source)
        {
            source.IconVariant = selected ? IconVariant.Filled : IconVariant.Regular;
        }
    }

    private async void OnTroubleshootConnectionClicked(object? sender, RoutedEventArgs e)
    {
        await new MessageBox
        {
            Title = Strings.ConnlostTroubleshootTitle,
            Description = Strings.ConnlostTroubleshootContent
        }.ShowAsync();
    }
}
