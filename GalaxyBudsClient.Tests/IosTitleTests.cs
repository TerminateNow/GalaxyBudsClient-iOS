using FluentAssertions;
using GalaxyBudsClient.Interface;
using NUnit.Framework;

namespace GalaxyBudsClient.Tests;

[TestFixture]
public class IosTitleTests
{
    [TestCase("Galaxy Buds3 Pro (0D81)", "Galaxy Buds3 Pro")]
    [TestCase("Galaxy Buds2 Pro (a1F3) ", "Galaxy Buds2 Pro")]
    [TestCase("Galaxy Buds3 Pro", "Galaxy Buds3 Pro")]
    [TestCase("My Buds (work)", "My Buds (work)")]
    [TestCase("Buds (0D81) spare", "Buds (0D81) spare")]
    [TestCase("(0D81)", "(0D81)")]
    public void StripAddressSuffix_RemovesOnlyTrailingHexCode(string name, string expected)
    {
        MainView.StripAddressSuffix(name).Should().Be(expected);
    }
}
