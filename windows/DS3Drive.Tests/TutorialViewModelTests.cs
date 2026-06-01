namespace DS3Drive.Tests;

using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Win32;
using NSubstitute;
using Xunit;

/// <summary>
/// Tests the first-launch tutorial slide machine + the HKCU Run-key consent write
/// (CONTEXT D-26 / PATTERNS §2.16). The registry assertions use the real HKCU Run key
/// (per-user, safe to toggle) and clean up after themselves.
/// </summary>
public sealed class TutorialViewModelTests
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "Cubbit DS3 Drive";

    private static TutorialViewModel Make() =>
        new(Substitute.For<INavigator>(), NullLogger<TutorialViewModel>.Instance);

    [Fact]
    public void InitialState_FirstSlide_NotLast()
    {
        var vm = Make();
        Assert.Equal(0, vm.CurrentSlideIndex);
        Assert.False(vm.IsLastSlide);
        Assert.Equal("Next", vm.PrimaryCtaLabel);
    }

    [Fact]
    public void Next_AdvancesThroughSlides_ToLast()
    {
        var vm = Make();
        int slideCount = vm.Slides.Count;
        Assert.True(slideCount >= 2);

        // Advance to the penultimate slide via the Next command.
        for (int i = 0; i < slideCount - 1; i++)
        {
            Assert.False(vm.IsLastSlide);
            vm.NextCommand.Execute(null);
        }

        Assert.True(vm.IsLastSlide);
        Assert.Equal("Get started", vm.PrimaryCtaLabel);
    }

    [Fact]
    public void LastSlide_IsLoginItemConsentSlide()
    {
        var vm = Make();
        vm.CurrentSlideIndex = vm.Slides.Count - 1;
        Assert.True(vm.IsLoginItemSlide);
    }

    [Fact]
    public void Finish_WithStartAtLoginDisabled_RemovesRunKeyValue()
    {
        // Pre-seed the value so we can assert the disabled path removes it.
        using (RegistryKey? runKey = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true))
        {
            runKey?.SetValue(RunValueName, "\"seeded.exe\"");
        }

        var vm = Make();
        vm.StartAtLoginEnabled = false;
        vm.CurrentSlideIndex = vm.Slides.Count - 1;

        // Finish runs on the last slide via Next.
        vm.NextCommand.Execute(null);

        using RegistryKey? verify = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        Assert.Null(verify?.GetValue(RunValueName));
    }

    [Fact]
    public void Finish_WithStartAtLoginEnabled_WritesRunKeyValue()
    {
        var vm = Make();
        vm.StartAtLoginEnabled = true;
        vm.CurrentSlideIndex = vm.Slides.Count - 1;

        try
        {
            vm.NextCommand.Execute(null);

            using RegistryKey? verify = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            object? value = verify?.GetValue(RunValueName);
            Assert.NotNull(value);
            Assert.Contains(".exe", value!.ToString(), System.StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            // Clean up so the test does not leave a real auto-start entry behind.
            using RegistryKey? runKey = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            runKey?.DeleteValue(RunValueName, throwOnMissingValue: false);
        }
    }
}
