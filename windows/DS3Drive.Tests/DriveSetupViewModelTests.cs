namespace DS3Drive.Tests;

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Exceptions;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;
using NSubstitute.ExceptionExtensions;
using Xunit;

/// <summary>
/// Tests the 4-step drive-setup wizard state machine (PATTERNS §2.5, D-09). The SDK +
/// drive manager are NSubstitute fakes so these run headless (Category != Integration).
/// Ports the macOS SyncSetupViewModelTests patterns (PATTERNS §2.18).
/// </summary>
public sealed class DriveSetupViewModelTests
{
    private static readonly DS3IAMUser User = new("user-1", "alice", "alice@example.com");
    private static readonly DS3Project Project = new("proj-1", "My Project", "org-1");
    private static readonly DS3Bucket Bucket = new("my-bucket", DateTime.UtcNow);

    private static (DriveSetupViewModel vm, IDS3SdkService sdk, IDriveManagementService mgr) Make()
    {
        var sdk = Substitute.For<IDS3SdkService>();
        var mgr = Substitute.For<IDriveManagementService>();
        var vm = new DriveSetupViewModel(sdk, mgr, NullLogger<DriveSetupViewModel>.Instance)
        {
            CurrentUser = User,
        };
        return (vm, sdk, mgr);
    }

    // Test 1
    [Fact]
    public void InitialState_IsProjectStep_NoSelections_NoError()
    {
        var (vm, _, _) = Make();
        Assert.Equal(WizardStep.Project, vm.CurrentStep);
        Assert.Null(vm.SelectedProject);
        Assert.Null(vm.SelectedBucket);
        Assert.Null(vm.SelectedPrefix);
        Assert.Empty(vm.Projects);
        Assert.Null(vm.CreationError);
    }

    // Test 2
    [Fact]
    public async Task LoadProjectsAsync_PopulatesProjects_TogglesLoadingFlag()
    {
        var (vm, sdk, _) = Make();
        sdk.GetProjectsAsync(Arg.Any<CancellationToken>())
            .Returns(Task.FromResult<IReadOnlyList<DS3Project>>(new[] { Project }));

        Assert.False(vm.IsLoadingProjects);
        await vm.LoadProjectsCommand.ExecuteAsync(null);

        Assert.False(vm.IsLoadingProjects);
        Assert.Single(vm.Projects);
        Assert.Equal("My Project", vm.Projects[0].Name);
    }

    // Test 3
    [Fact]
    public async Task LoadProjectsAsync_OnError_SetsCreationError_LeavesProjectsEmpty()
    {
        var (vm, sdk, _) = Make();
        sdk.GetProjectsAsync(Arg.Any<CancellationToken>())
            .Throws(new DS3TransportException(3002, "network down"));

        await vm.LoadProjectsCommand.ExecuteAsync(null);

        Assert.Empty(vm.Projects);
        Assert.NotNull(vm.CreationError);
    }

    // Test 4
    [Fact]
    public void SelectProject_SetsProject_AdvancesToBucket_TriggersBucketLoad()
    {
        var (vm, sdk, _) = Make();
        sdk.GetBucketsAsync(Arg.Any<DS3Project>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromResult<IReadOnlyList<DS3Bucket>>(new[] { Bucket }));

        vm.SelectProjectCommand.Execute(Project);

        Assert.Equal(Project, vm.SelectedProject);
        Assert.Equal(WizardStep.Bucket, vm.CurrentStep);
        sdk.Received().GetBucketsAsync(Project, Arg.Any<CancellationToken>());
    }

    // Test 5
    [Fact]
    public void SelectBucket_SetsBucket_SeedsDriveName_AdvancesToPrefix()
    {
        var (vm, _, _) = Make();
        vm.SelectBucketCommand.Execute(Bucket);

        Assert.Equal(Bucket, vm.SelectedBucket);
        Assert.Equal("my-bucket", vm.DriveName);
        Assert.Equal(WizardStep.Prefix, vm.CurrentStep);
    }

    // Test 6
    [Fact]
    public void SelectPrefix_Null_MeansRoot_AdvancesToConfirm()
    {
        var (vm, _, _) = Make();
        vm.SelectPrefixCommand.Execute(null);

        Assert.Null(vm.SelectedPrefix);
        Assert.Equal(WizardStep.Confirm, vm.CurrentStep);

        vm.SelectPrefixCommand.Execute("photos/");
        Assert.Equal("photos/", vm.SelectedPrefix);
    }

    // Test 7
    [Fact]
    public void GoBack_FromBucket_ReturnsToProject_PreservesProjectSelection()
    {
        var (vm, sdk, _) = Make();
        sdk.GetBucketsAsync(Arg.Any<DS3Project>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromResult<IReadOnlyList<DS3Bucket>>(Array.Empty<DS3Bucket>()));
        vm.SelectProjectCommand.Execute(Project);

        vm.GoBackCommand.Execute(null);

        Assert.Equal(WizardStep.Project, vm.CurrentStep);
        Assert.Equal(Project, vm.SelectedProject); // preserved (UI-SPEC Open Q #4: yes)
    }

    // Test 8
    [Fact]
    public void GoBack_FromPrefix_ReturnsToBucket_PreservesBucketSelection()
    {
        var (vm, _, _) = Make();
        vm.SelectBucketCommand.Execute(Bucket); // now on Prefix

        vm.GoBackCommand.Execute(null);

        Assert.Equal(WizardStep.Bucket, vm.CurrentStep);
        Assert.Equal(Bucket, vm.SelectedBucket); // preserved
    }

    // Test 9
    [Fact]
    public async Task CreateDriveAsync_OnSuccess_ReconcilesKey_PersistsDrive_RaisesCompleted()
    {
        var (vm, sdk, mgr) = Make();
        sdk.LoadOrCreateApiKeyAsync(Arg.Any<DS3IAMUser>(), Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromResult(new DS3ApiKey("key", "AK", "SK", User.Id)));
        mgr.AddAsync(Arg.Any<DS3Drive>(), Arg.Any<CancellationToken>()).Returns(Task.CompletedTask);

        vm.SelectProjectCommand.Execute(Project);
        vm.SelectBucketCommand.Execute(Bucket);
        vm.SelectPrefixCommand.Execute(null); // Confirm

        DS3Drive? completed = null;
        vm.WizardCompleted += (_, d) => completed = d;

        await vm.CreateDriveCommand.ExecuteAsync(null);

        await sdk.Received().LoadOrCreateApiKeyAsync(User, "My Project", Arg.Any<CancellationToken>());
        await mgr.Received().AddAsync(Arg.Any<DS3Drive>(), Arg.Any<CancellationToken>());
        Assert.NotNull(completed);
        Assert.Equal("my-bucket", completed!.SyncAnchor.Bucket);
        Assert.False(vm.IsCreating);
    }

    // Test 10
    [Fact]
    public async Task CreateDriveAsync_OnError_SetsError_StaysOnConfirm()
    {
        var (vm, sdk, mgr) = Make();
        vm.SelectProjectCommand.Execute(Project);
        vm.SelectBucketCommand.Execute(Bucket);
        vm.SelectPrefixCommand.Execute(null);

        sdk.LoadOrCreateApiKeyAsync(Arg.Any<DS3IAMUser>(), Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Throws(new DS3TransportException(3002, "down"));

        await vm.CreateDriveCommand.ExecuteAsync(null);

        Assert.NotNull(vm.CreationError);
        Assert.False(vm.IsCreating);
        Assert.Equal(WizardStep.Confirm, vm.CurrentStep);
        await mgr.DidNotReceive().AddAsync(Arg.Any<DS3Drive>(), Arg.Any<CancellationToken>());
    }

    // Test 11
    [Fact]
    public void Cancel_ResetsToInitialState()
    {
        var (vm, _, _) = Make();
        vm.SelectBucketCommand.Execute(Bucket); // mutate state

        bool cancelled = false;
        vm.WizardCancelled += (_, _) => cancelled = true;

        vm.CancelCommand.Execute(null);

        Assert.Equal(WizardStep.Project, vm.CurrentStep);
        Assert.Null(vm.SelectedBucket);
        Assert.True(cancelled);
    }

    // Test 12 — D-06 faked seam, S3 branch.
    // The fix in this phase routes bucket listing through a valid DS3DriveS3Client
    // handle (plan 17.1-01/02) so a bad/forbidden bucket surfaces as a clean,
    // catchable DS3S3Exception (2001-2099) instead of the uncatchable
    // AccessViolationException the session-handle deref produced. The wizard must
    // show the inline error, stay on the Bucket step, and leave Buckets empty —
    // never crash. (We do NOT catch AccessViolationException here: it is a
    // corrupted-state exception .NET will not deliver to catch — PATTERNS Pitfall 1.)
    [Fact]
    public async Task LoadBucketsAsync_OnS3Exception_SetsCreationError_StaysOnBucket_LeavesBucketsEmpty()
    {
        var (vm, sdk, _) = Make();
        // Advance to the Bucket step with a project selected (SelectProject fires a
        // fire-and-forget load; we drive a deterministic retry via the command below).
        sdk.GetBucketsAsync(Arg.Any<DS3Project>(), Arg.Any<CancellationToken>())
            .Throws(new DS3S3Exception(2003, "AccessDenied"));
        vm.SelectProjectCommand.Execute(Project);

        // Deterministic re-invoke of the bucket load (the Retry path).
        await vm.LoadBucketsCommand.ExecuteAsync(null);

        Assert.Equal(WizardStep.Bucket, vm.CurrentStep); // inline error, stays on step
        Assert.Empty(vm.Buckets);
        Assert.NotNull(vm.CreationError);
        // Fixed UI copy only — never the raw server text (STRIDE T-17-09-05).
        Assert.DoesNotContain("AccessDenied", vm.CreationError!);
    }

    // Test 14 — WIN-03 happy-path: successful GetBucketsAsync populates Buckets,
    // stays on WizardStep.Bucket, and sets no error.
    // This test targets the gap where only the trigger (Test 4) and the error
    // branches (Tests 12/13) were covered, but not the success-population behavior.
    [Fact]
    public async Task LoadBucketsAsync_OnSuccess_PopulatesBuckets_StaysOnBucket_NoError()
    {
        var (vm, sdk, _) = Make();
        sdk.GetBucketsAsync(Arg.Any<DS3Project>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromResult<IReadOnlyList<DS3Bucket>>(new[] { Bucket }));

        // Advance to Bucket step (sets SelectedProject, required by LoadBucketsCommand guard).
        vm.SelectProjectCommand.Execute(Project);

        // Deterministic re-invoke of the bucket load to await the async result.
        await vm.LoadBucketsCommand.ExecuteAsync(null);

        Assert.Equal(WizardStep.Bucket, vm.CurrentStep);
        Assert.Single(vm.Buckets);
        Assert.Equal("my-bucket", vm.Buckets[0].Name);
        Assert.Null(vm.CreationError);
    }

    // Test 13 — D-06 faked seam, TRANSPORT branch.
    // Per A1 verification against core/ds3-models/src/error.rs, a bad access key
    // surfaces as code 3003 (S3Error in the 3001-3099 transport range) →
    // DS3TransportException, NOT DS3S3Exception. So the bad-credentials path lands
    // here, and the wizard must show the "check your connection" transport copy.
    // Both branches are tested because InvalidAccessKeyId does NOT map into the
    // 2001-2099 S3 range.
    [Fact]
    public async Task LoadBucketsAsync_OnTransportException_SetsCreationError_StaysOnBucket()
    {
        var (vm, sdk, _) = Make();
        sdk.GetBucketsAsync(Arg.Any<DS3Project>(), Arg.Any<CancellationToken>())
            .Throws(new DS3TransportException(3003, "invalid access key"));
        vm.SelectProjectCommand.Execute(Project);

        await vm.LoadBucketsCommand.ExecuteAsync(null);

        Assert.Equal(WizardStep.Bucket, vm.CurrentStep);
        Assert.Empty(vm.Buckets);
        Assert.NotNull(vm.CreationError);
        // Transport copy is shown (the MapErrorCopy DS3TransportException branch).
        Assert.Contains("connection", vm.CreationError!, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("invalid access key", vm.CreationError!);
    }
}
