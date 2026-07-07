using System.Runtime.CompilerServices;

// Expose internal types (PlaceholderMaterializer streaming/ghost-removal helpers,
// FetchPlaceholdersHandler) to the test assembly so the Phase 17.3 sync unit tests
// can exercise them directly without widening the public surface. Mirrors the same
// grant on DS3Drive.Core. See 17.3-03-PLAN (Wave 2).
[assembly: InternalsVisibleTo("DS3Drive.Tests")]
