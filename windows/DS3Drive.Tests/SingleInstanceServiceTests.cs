namespace DS3Drive.Tests;

using DS3Drive.ViewModels.Platform;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

/// <summary>
/// Tests the named-Mutex single-instance guard (CONTEXT D-27). The first service to
/// <see cref="ISingleInstanceService.Acquire"/> wins ownership; a second service on the
/// same (per-user SID-scoped) name must lose. <see cref="SingleInstanceService.Dispose"/>
/// releases ownership so a subsequent acquire succeeds again.
/// </summary>
public sealed class SingleInstanceServiceTests
{
    [Fact]
    public void FirstInstance_AcquiresOwnership()
    {
        using var svc = new SingleInstanceService(NullLogger<SingleInstanceService>.Instance);
        Assert.True(svc.Acquire());
    }

    [Fact]
    public void SecondInstance_WhileFirstHoldsMutex_DoesNotAcquire()
    {
        using var first = new SingleInstanceService(NullLogger<SingleInstanceService>.Instance);
        Assert.True(first.Acquire());

        using var second = new SingleInstanceService(NullLogger<SingleInstanceService>.Instance);
        Assert.False(second.Acquire());
    }

    [Fact]
    public void Acquire_IsIdempotent_ReturnsSameResult()
    {
        using var svc = new SingleInstanceService(NullLogger<SingleInstanceService>.Instance);
        Assert.True(svc.Acquire());
        Assert.True(svc.Acquire());
    }

    [Fact]
    public void AfterDispose_NewInstanceCanReacquire()
    {
        var first = new SingleInstanceService(NullLogger<SingleInstanceService>.Instance);
        Assert.True(first.Acquire());
        first.Dispose();

        using var second = new SingleInstanceService(NullLogger<SingleInstanceService>.Instance);
        Assert.True(second.Acquire());
    }
}
