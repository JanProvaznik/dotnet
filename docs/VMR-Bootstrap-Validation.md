# Bootstrap validation

.NET builds itself. The SDK, compilers and MSBuild that build the VMR are a
previously shipped .NET SDK, pinned in [global.json](../global.json) and
periodically advanced by [re-bootstrapping](VMR-re-bootstrapping.md).

That means "the product builds" and "the product can build itself" are two
different claims, and only the second one guarantees that a
[re-bootstrap](VMR-re-bootstrapping.md) will succeed. Bootstrap validation
checks the second claim.

## What it validates

The [bootstrap validation pipeline](../eng/pipelines/bootstrap-validation.yml)
builds the whole product twice in a single run:

1. **Stage 1** builds every vertical the official build produces, using the
   last-known-good SDK from `global.json`. This is an ordinary VMR build.
2. **Stage 2** builds all of them again. Each leg first replaces its bootstrap
   toolset with what stage 1 produced - the freshly built SDK plus the freshly
   built Arcade packages - and then builds and tests with it.

A green stage 2 means the code on that commit can build itself on every platform
we ship.

## Why it exists

Before this pipeline, the only bootstrap coverage in the VMR was on Linux, and
only for source-build: the official build runs
`SB_CentOSStream10_Online_MsftSdk` and then rebuilds with
`SB_CentOSStream10_Offline_CurrentSourceBuiltSdk` from its output. Nothing
equivalent existed for the Microsoft verticals, so a change could break
bootstrappability on Windows, macOS, musl, or any cross or mobile vertical and
CI would stay green. The breakage would only surface at the next re-bootstrap,
long after the responsible change merged.

## Where each leg gets its toolset

A leg's bootstrap SDK always comes from the stage 1 vertical matching the leg's
**host** platform, never its target:

- Short-stack legs (android, ios, tvos, maccatalyst, browser, wasi,
  linux-bionic, and the Mono LLVM legs) build only a runtime, never an SDK - see
  the `ShortStack` property in [eng/RuntimeIdentifier.props](../eng/RuntimeIdentifier.props).
- Cross-built legs (windows-arm64, linux-arm, linux-arm64, all of linux-musl)
  produce an SDK that cannot run on the agent that built it.

| Stage 2 legs | Host | Bootstrap SDK from |
| --- | --- | --- |
| All `Windows*` legs, every architecture and build pass | windows-x64 | `Windows_x64` |
| All Linux-hosted legs: `Linux*`, `Linux_Alpine*`, `Android_*`, `Browser_*`, `Wasi_*`, `LinuxBionic_*` | linux-x64 | `Linux_x64` |
| All macOS-hosted legs: `OSX*`, `iOS*`, `tvOS*`, `MacCatalyst_*` | osx-arm64 | `OSX_arm64` |
| `SB_*` source-build legs | native, per container | the matching `SB_*` leg of the same distro |

The mapping is derived automatically from each job's agent pool in
[templates/jobs/vmr-build.yml](../eng/pipelines/templates/jobs/vmr-build.yml), so
legs added to the official build in future are covered without further wiring.

The bootstrap *packages* follow a slightly different rule. Not every vertical
publishes Arcade's packages - the macOS verticals publish only aspnetcore, emsdk
and runtime packages - so macOS legs take their SDK from `OSX_arm64` but their
packages from `Linux_x64`. Packages are platform-agnostic `.nupkg` files built
from the same commit in the same run, so this is safe.

## How the toolset is swapped

Stage 2 legs pass `--with-sdk` and `--with-packages` (`-withSdk` /
`-withPackages` on Windows) to the build. These used to be source-only options;
they now work for Microsoft builds too, handled by
[eng/msft-toolset-init.sh](../eng/msft-toolset-init.sh) and
[eng/msft-toolset-init.ps1](../eng/msft-toolset-init.ps1), which:

- rewrite `sdk.version` and `tools.dotnet` in the root `global.json` to the
  supplied SDK's version, so both the dotnet muxer and Arcade resolve to it;
- export `DOTNET_INSTALL_DIR` (and `_InitializeDotNetCli` on Unix) so Arcade does
  not download an SDK of its own. `repo-projects/Directory.Build.props` passes
  `DOTNET_INSTALL_DIR` down, so every repo underneath inherits the same SDK;
- add the supplied package directory to the root `NuGet.config` and pass
  `ExtraRestoreSourcePath`, which the `UpdateNuGetConfig` target in
  `repo-projects/Directory.Build.targets` injects into each repo's own
  `NuGet.config`;
- repoint `msbuild-sdks`.`Microsoft.DotNet.Arcade.Sdk` in `global.json` at the
  Arcade built by stage 1.

Only Arcade's packages are carried across. Every other repo already builds
against the Arcade SDK produced by the current build, via
`DiscoverBuiltSdkOverrides` in `repo-projects/Directory.Build.targets`. The repos
listed in `BootstrapArcadeRepos` - Arcade itself and source-build-assets - are
the ones that fall back to the bootstrap version, so that is the version that has
to come from stage 1.

## Running it

The pipeline is manual (`trigger: none`, `pr: none`). A run is roughly twice an
official build, so it is an on-demand health check rather than per-commit CI.
Good times to run it are before a planned re-bootstrap, before branching for a
release, or when bisecting a suspected bootstrap break.

Parameters:

- **Exclude runtime dependent jobs** - set for branches that do not produce a 1xx
  version, matching the official build's option of the same name.
- **Include the Linux source-build legs** - clear this to validate only the
  Microsoft verticals, which is the faster option when triaging a
  Windows/macOS-specific break.

## Reading a failure

- **Stage 1 red** - an ordinary build break. It says nothing about
  bootstrappability, and stage 2 will be skipped.
- **Stage 2 red where stage 1 was green** - a genuine bootstrap break: the
  product cannot build itself. Look first at the `Prepare Bootstrap Toolset` step
  for which SDK was picked up, and at the rewritten `global.json` in the build
  log.
- **Stage 2 red on every leg** - more likely a pipeline problem than a product
  one, since the legs share only the toolset-swapping code.

Artifacts from stage 2 are prefixed with `Stage2_` so that the two stages do not
collide; the stage 1 artifacts keep the same names the official build uses.
