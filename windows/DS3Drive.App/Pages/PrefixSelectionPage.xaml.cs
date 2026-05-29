namespace DS3Drive.App.Pages;

using System;
using System.Threading;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

/// <summary>
/// Wizard step 3 (Prefix). Renders a lazy-loaded folder tree of the selected bucket's
/// prefixes (keys ending in "/") via <see cref="IDS3SdkService.ListChildPrefixesAsync"/>.
/// Picking "Use root" or a folder node + Continue forwards to
/// <see cref="DriveSetupViewModel.SelectPrefix"/> (null = root). The shared view-model is
/// the navigation parameter; the SDK is resolved from DI for the tree data.
/// </summary>
public sealed partial class PrefixSelectionPage : Page
{
    private readonly IDS3SdkService _sdk;
    private string _selectedPrefix = string.Empty; // empty = root

    public PrefixSelectionPage()
    {
        _sdk = App.Host.Services.GetRequiredService<IDS3SdkService>();
        InitializeComponent();
    }

    public DriveSetupViewModel? ViewModel { get; private set; }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is DriveSetupViewModel vm)
        {
            ViewModel = vm;
            await LoadChildrenAsync(PrefixTree.RootNodes, prefix: null);
        }
    }

    /// <summary>Loads the immediate child folders under a prefix into a node list, marking
    /// each as expandable (HasUnrealizedChildren) for lazy expansion.</summary>
    private async System.Threading.Tasks.Task LoadChildrenAsync(
        System.Collections.Generic.IList<TreeViewNode> into, string? prefix)
    {
        if (ViewModel?.SelectedBucket is null)
        {
            return;
        }

        TreeLoadingRing.IsActive = true;
        try
        {
            var children = await _sdk.ListChildPrefixesAsync(ViewModel.SelectedBucket.Name, prefix, CancellationToken.None);
            foreach (string childKey in children)
            {
                into.Add(new TreeViewNode
                {
                    Content = LeafSegment(childKey),
                    HasUnrealizedChildren = true,
                });
            }
        }
        catch (Exception)
        {
            // The empty/inaccessible tree is non-fatal — the user can still "Use root".
        }
        finally
        {
            TreeLoadingRing.IsActive = false;
        }
    }

    private async void PrefixTree_Expanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Node.HasUnrealizedChildren)
        {
            args.Node.HasUnrealizedChildren = false;
            string prefix = FullPrefix(args.Node);
            await LoadChildrenAsync(args.Node.Children, prefix);
        }
    }

    private void PrefixTree_ItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is TreeViewNode node)
        {
            _selectedPrefix = FullPrefix(node);
            BreadcrumbText.Text = string.IsNullOrEmpty(_selectedPrefix) ? "Root" : _selectedPrefix;
        }
    }

    private void UseRoot_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _selectedPrefix = string.Empty;
        BreadcrumbText.Text = "Root";
        ViewModel?.SelectPrefixCommand.Execute(null);
    }

    /// <summary>Commits the current tree selection (called by the wizard's Continue button).</summary>
    public void CommitSelection() =>
        ViewModel?.SelectPrefixCommand.Execute(string.IsNullOrEmpty(_selectedPrefix) ? null : _selectedPrefix);

    private static string LeafSegment(string key) =>
        key.TrimEnd('/').Split('/')[^1] + "/";

    private string FullPrefix(TreeViewNode node)
    {
        // Walk up to the root composing the full S3 key.
        var segments = new System.Collections.Generic.Stack<string>();
        TreeViewNode? current = node;
        while (current is not null && current.Content is string segment)
        {
            segments.Push(segment);
            current = current.Parent;
        }

        return string.Concat(segments);
    }
}
