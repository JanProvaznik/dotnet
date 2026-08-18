#!/usr/bin/env bash

### This script initializes the toolset for a Microsoft (non source-only) build that bootstraps
### from an externally supplied SDK and/or package set, i.e. `./build.sh --with-sdk <DIR>
### [--with-packages <DIR>]`.
###
### It is the Microsoft-build counterpart of source_only_toolset_init in
### eng/source-build-toolset-init.sh. Source-only builds have far more to set up (prebuilt
### detection, the custom SDK resolver, the offline package layout); a Microsoft build only needs
### the SDK swapped out and, optionally, the supplied packages made restorable.
###
### This is what the 2-stage bootstrap validation pipeline uses to rebuild the VMR with the
### toolset that the first stage just produced.

source "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/toolset-init-common.sh"

function msft_toolset_init() {
  local custom_sdk_dir="$1"
  local custom_packages_dir="$2"

  local script_dir
  script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
  local repo_root
  repo_root="$( cd "${script_dir}/.." && pwd )"

  echo "Initializing Microsoft build toolset..."

  if [ -n "$custom_sdk_dir" ]; then
    if [ ! -d "$custom_sdk_dir" ]; then
      echo "ERROR: Custom SDK directory '$custom_sdk_dir' does not exist"
      exit 1
    fi
    if [ ! -x "$custom_sdk_dir/dotnet" ]; then
      echo "ERROR: Custom SDK '$custom_sdk_dir/dotnet' does not exist or is not executable"
      exit 1
    fi

    local sdk_version
    # --list-sdks rather than --version: --version resolves through global.json, which at this point
    # still pins the SDK we are replacing, so it would fail (or silently roll forward to something
    # else) exactly when a custom SDK is supplied. A freshly extracted SDK archive holds one SDK;
    # take the last (highest) entry if there is somehow more than one.
    sdk_version=$("$custom_sdk_dir/dotnet" --list-sdks | tail -n 1 | sed -E 's/[[:space:]]*\[.*$//')
    if [ -z "$sdk_version" ]; then
      echo "ERROR: Could not determine the SDK version of the custom SDK at '$custom_sdk_dir'"
      exit 1
    fi
    if [ ! -d "$custom_sdk_dir/sdk/$sdk_version" ]; then
      echo "ERROR: Custom SDK '$custom_sdk_dir' does not contain 'sdk/$sdk_version'"
      exit 1
    fi
    echo "Using custom bootstrap SDK from '$custom_sdk_dir', version '$sdk_version'"

    # Point the root global.json at the custom SDK. Both the dotnet muxer and Arcade's tools.sh
    # resolve the SDK through this file, so a version that doesn't match the SDK being used fails
    # the build before anything gets built. The repositories underneath get the same treatment from
    # the UpdateGlobalJsonVersions target in repo-projects/Directory.Build.targets, which uses the
    # NETCoreSdkVersion of whatever SDK ends up running the build.
    update_global_json_sdk_version "$repo_root/global.json" "$sdk_version"

    # Set these so that eng/common/tools.sh doesn't attempt to restore the SDK. InitializeDotNetCli
    # returns early when _InitializeDotNetCli is already set, and DOTNET_INSTALL_DIR is what gets
    # handed down to the individual repo builds via repo-projects/Directory.Build.props.
    export _InitializeDotNetCli="$custom_sdk_dir"
    export DOTNET_INSTALL_DIR="$custom_sdk_dir"
    export DOTNET_ROOT="$custom_sdk_dir"
  fi

  if [ -n "$custom_packages_dir" ]; then
    if [ ! -d "$custom_packages_dir" ]; then
      echo "ERROR: Custom packages directory '$custom_packages_dir' does not exist"
      exit 1
    fi

    echo "Using custom bootstrap packages from '$custom_packages_dir'"

    # Make the packages reachable by the outer VMR build. MSBuild SDK resolution reads the
    # NuGet.config next to the project, so a restore-time property isn't enough for the
    # Microsoft.DotNet.Arcade.Sdk entry in global.json to resolve locally.
    add_nuget_source_to_config "$repo_root/NuGet.config" "bootstrap-packages" "$custom_packages_dir"

    # Repoint the bootstrap Arcade SDK at the supplied build when it contains one. Repos that build
    # before Arcade (Arcade itself and source-build-assets, see BootstrapArcadeRepos) use this
    # version rather than the Arcade built during this build.
    local arcade_version
    arcade_version=$(find_package_version "$custom_packages_dir" "Microsoft.DotNet.Arcade.Sdk")
    if [ -n "$arcade_version" ]; then
      echo "Using bootstrap Arcade SDK version '$arcade_version'"
      update_global_json_msbuild_sdk_version "$repo_root/global.json" "Microsoft.DotNet.Arcade.Sdk" "$arcade_version"
    fi

    # ExtraRestoreSourcePath adds the directory to each repo's NuGet.config (see the
    # UpdateNuGetConfig target in repo-projects/Directory.Build.targets), while
    # RestoreAdditionalProjectSources covers the VMR-level projects.
    properties+=( "/p:ExtraRestoreSourcePath=$custom_packages_dir" )
    properties+=( "/p:RestoreAdditionalProjectSources=$custom_packages_dir" )
  fi

  echo "Microsoft build toolset initialization complete"
}
