namespace DS3Drive.ViewModels.ViewModels;

using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DS3Drive.Core.Exceptions;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

/// <summary>The four wizard steps, in D-09 verbatim order (Project → Bucket → Prefix → Confirm).</summary>
public enum WizardStep
{
    Project = 0,
    Bucket = 1,
    Prefix = 2,
    Confirm = 3,
}

/// <summary>
/// Drive-setup wizard state machine — the Windows expansion of Apple's collapsed
/// 2-step <c>SyncSetupViewModel</c> (apple/DS3Drive/Views/Sync/ViewModels/SyncViewModel.swift,
/// PATTERNS §2.5) into the 4-step machine mandated by D-09. <c>CreateDriveAsync</c> ports
/// the addDrive flow from SetupSyncView.swift:67-83: reconcile the API key
/// (<see cref="IDS3SdkService.LoadOrCreateApiKeyAsync"/>), then persist via
/// <see cref="IDriveManagementService.AddAsync"/> (PATTERNS §3.3 persistence triple),
/// then raise <see cref="WizardCompleted"/> so the host returns to the drives list.
/// Back navigation preserves picker state (UI-SPEC Open Design Question #4: yes).
/// </summary>
public partial class DriveSetupViewModel : ObservableObject
{
    private readonly IDS3SdkService _sdk;
    private readonly IDriveManagementService _driveManager;
    private readonly ILogger<DriveSetupViewModel> _logger;

    [ObservableProperty] private WizardStep currentStep = WizardStep.Project;
    [ObservableProperty] private DS3Project? selectedProject;
    [ObservableProperty] private DS3Bucket? selectedBucket;
    [ObservableProperty] private string? selectedPrefix;       // null = root
    [ObservableProperty] private string driveName = string.Empty; // default from bucket name
    [ObservableProperty] private string? creationError;
    [ObservableProperty] private bool isCreating;
    [ObservableProperty] private IReadOnlyList<DS3Project> projects = Array.Empty<DS3Project>();
    [ObservableProperty] private IReadOnlyList<DS3Bucket> buckets = Array.Empty<DS3Bucket>();
    [ObservableProperty] private bool isLoadingProjects;
    [ObservableProperty] private bool isLoadingBuckets;

    public DriveSetupViewModel(
        IDS3SdkService sdk,
        IDriveManagementService driveManager,
        ILogger<DriveSetupViewModel> logger)
    {
        _sdk = sdk;
        _driveManager = driveManager;
        _logger = logger;
    }

    /// <summary>The IAM user the wizard creates drives for. Set by the host from the live
    /// session before the wizard opens (the Apple anchor carries the same IAMUser).</summary>
    public DS3IAMUser? CurrentUser { get; set; }

    /// <summary>Raised on successful drive creation; the host observes it to navigate back
    /// to the drives list (analog of SetupSyncView dismissing the wizard sheet).</summary>
    public event EventHandler<DS3Drive>? WizardCompleted;

    /// <summary>Raised when the user cancels the wizard; the host returns to the drives list.</summary>
    public event EventHandler? WizardCancelled;

    /// <summary>Loads the account's projects (UI-SPEC "Loading projects…" ring).</summary>
    [RelayCommand]
    private async Task LoadProjectsAsync(CancellationToken ct)
    {
        if (IsLoadingProjects)
        {
            return;
        }

        IsLoadingProjects = true;
        CreationError = null;
        try
        {
            Projects = await _sdk.GetProjectsAsync(ct).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            _logger.LogError("Failed to load projects: {Message}", ex.Message);
            Projects = Array.Empty<DS3Project>();
            CreationError = MapErrorCopy(ex);
        }
        finally
        {
            IsLoadingProjects = false;
        }
    }

    /// <summary>Loads the buckets for the selected project (UI-SPEC "Loading buckets…" ring).</summary>
    [RelayCommand]
    private async Task LoadBucketsAsync(CancellationToken ct)
    {
        if (SelectedProject is null || IsLoadingBuckets)
        {
            return;
        }

        IsLoadingBuckets = true;
        CreationError = null;
        try
        {
            Buckets = await _sdk.GetBucketsAsync(SelectedProject, ct).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            _logger.LogError("Failed to load buckets: {Message}", ex.Message);
            Buckets = Array.Empty<DS3Bucket>();
            CreationError = MapErrorCopy(ex);
        }
        finally
        {
            IsLoadingBuckets = false;
        }
    }

    /// <summary>Selects a project, advances to the Bucket step, and kicks off bucket loading
    /// (port of SyncSetupViewModel.selectProject + step advance).</summary>
    [RelayCommand]
    private void SelectProject(DS3Project? project)
    {
        if (project is null)
        {
            return;
        }

        SelectedProject = project;
        CurrentStep = WizardStep.Bucket;
        _ = LoadBucketsAsync(CancellationToken.None);
    }

    /// <summary>Selects a bucket, seeds the default drive name, advances to the Prefix step.</summary>
    [RelayCommand]
    private void SelectBucket(DS3Bucket? bucket)
    {
        if (bucket is null)
        {
            return;
        }

        SelectedBucket = bucket;
        DriveName = bucket.Name; // suggested name (S3PathUtils.suggestedDriveName analog)
        CurrentStep = WizardStep.Prefix;
    }

    /// <summary>Selects a prefix (null = root) and advances to the Confirm step.</summary>
    [RelayCommand]
    private void SelectPrefix(string? prefix)
    {
        SelectedPrefix = string.IsNullOrEmpty(prefix) ? null : prefix;
        CurrentStep = WizardStep.Confirm;
    }

    /// <summary>Steps back one page, preserving the selection on the page we leave
    /// (UI-SPEC Open Design Question #4: preserve picker state).</summary>
    [RelayCommand]
    private void GoBack()
    {
        CurrentStep = CurrentStep switch
        {
            WizardStep.Confirm => WizardStep.Prefix,
            WizardStep.Prefix => WizardStep.Bucket,
            WizardStep.Bucket => WizardStep.Project,
            _ => WizardStep.Project,
        };
    }

    /// <summary>Cancels the wizard and resets to the initial state.</summary>
    [RelayCommand]
    private void Cancel()
    {
        Reset();
        WizardCancelled?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Creates the drive end-to-end — port of SetupSyncView.swift:67-83 addDrive: reconcile
    /// the API key, build the <see cref="DS3Drive"/>, persist it through the
    /// <see cref="IDriveManagementService"/> persistence triple, then raise
    /// <see cref="WizardCompleted"/>. A double-submit while in flight is ignored.
    /// </summary>
    [RelayCommand]
    private async Task CreateDriveAsync(CancellationToken ct)
    {
        if (IsCreating)
        {
            return;
        }

        if (SelectedProject is null || SelectedBucket is null || CurrentUser is null)
        {
            CreationError = "Setup couldn't finish. Reinstall Cubbit DS3 Drive and try again.";
            return;
        }

        IsCreating = true;
        CreationError = null;
        try
        {
            // 1. Reconcile the API key (same name pattern Apple uses → same console key).
            _ = await _sdk.LoadOrCreateApiKeyAsync(CurrentUser, SelectedProject.Name, ct).ConfigureAwait(true);

            // 2. Build the drive and persist through the triple (PATTERNS §3.3).
            var drive = new DS3Drive(
                Id: Guid.NewGuid(),
                Name: string.IsNullOrWhiteSpace(DriveName) ? SelectedBucket.Name : DriveName.Trim(),
                SyncAnchor: new DS3SyncAnchor(SelectedBucket.Name, SelectedPrefix, SelectedProject.Id, CurrentUser.Id),
                CreatedAt: DateTime.UtcNow);

            await _driveManager.AddAsync(drive, ct).ConfigureAwait(true);
            WizardCompleted?.Invoke(this, drive);
        }
        catch (Exception ex)
        {
            _logger.LogError("Drive creation failed: {Message}", ex.Message);
            CreationError = MapErrorCopy(ex);
            // CurrentStep stays on Confirm so the user can retry.
        }
        finally
        {
            IsCreating = false;
        }
    }

    /// <summary>Resets every selection + step back to the initial state (port of SyncSetupViewModel.reset).</summary>
    public void Reset()
    {
        CurrentStep = WizardStep.Project;
        SelectedProject = null;
        SelectedBucket = null;
        SelectedPrefix = null;
        DriveName = string.Empty;
        CreationError = null;
        IsCreating = false;
        Projects = Array.Empty<DS3Project>();
        Buckets = Array.Empty<DS3Bucket>();
        IsLoadingProjects = false;
        IsLoadingBuckets = false;
    }

    /// <summary>Maps an exception to UI-SPEC §"Error states" copy (no raw server text leaks —
    /// STRIDE T-17-09-05).</summary>
    private static string MapErrorCopy(Exception ex) => ex switch
    {
        ArgumentException => "That drive name isn't allowed. Use letters, numbers, spaces, or - _ . (max 64).",
        DS3AuthenticationException { Reason: AuthFailureReason.ServerError } =>
            "Couldn't load projects. Check your connection and try again.",
        DS3TransportException =>
            "Couldn't load projects. Check your connection and try again.",
        DS3S3Exception =>
            "Your account can't access this bucket. Contact your project administrator to request access.",
        _ => "Couldn't load projects. Check your connection and try again.",
    };
}
