#!/usr/bin/env bash

### Shared helpers used by the source-only and Microsoft toolset initialization scripts.
### Both flavors of the build need to repoint the VMR at an externally supplied SDK and,
### optionally, at an externally supplied set of packages, so the primitives live here.

# Rewrites the SDK version entries of a global.json in place. Both the "sdk"/"version" and the
# "tools"/"dotnet" entries hold the version of the SDK used to build and are read during the build:
# the MSBuild SDK resolver uses the former, Arcade's tools.sh the latter. Each substitution is scoped
# to the object that owns the key so that unrelated entries elsewhere in the file are left alone.
# Written with sed rather than jq because jq isn't guaranteed to be present on the build images, and
# via a temporary file because the -i flag isn't portable across GNU and BSD sed.
function update_global_json_sdk_version() {
  local global_json_file="$1"
  local sdk_version="$2"
  local tmp_file="${global_json_file}.tmp"

  sed -E \
    -e "/\"sdk\"[[:space:]]*:/,/\}/ s|(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*\"|\1${sdk_version}\"|" \
    -e "/\"tools\"[[:space:]]*:/,/\}/ s|(\"dotnet\"[[:space:]]*:[[:space:]]*\")[^\"]*\"|\1${sdk_version}\"|" \
    "$global_json_file" > "$tmp_file"
  mv "$tmp_file" "$global_json_file"
}

# Rewrites a single "msbuild-sdks" entry of a global.json in place. This is how the bootstrap
# Arcade SDK gets repointed at a locally built package: MSBuild resolves SDKs named here through
# NuGet, so the version must match a package that is reachable from the configured sources.
function update_global_json_msbuild_sdk_version() {
  local global_json_file="$1"
  local sdk_id="$2"
  local sdk_version="$3"
  local tmp_file="${global_json_file}.tmp"
  # Escape the dots in the package id so they aren't treated as "any character" by sed.
  local escaped_id="${sdk_id//./\\.}"

  sed -E \
    -e "s|(\"${escaped_id}\"[[:space:]]*:[[:space:]]*\")[^\"]*\"|\1${sdk_version}\"|" \
    "$global_json_file" > "$tmp_file"
  mv "$tmp_file" "$global_json_file"
}

# Adds a local package source to a NuGet.config. Used to make an externally supplied package
# directory reachable by the outer VMR build, including MSBuild SDK resolution which reads the
# NuGet.config next to the project rather than any restore-time property.
# Existing sources with the same key are replaced so the function is safe to call repeatedly.
function add_nuget_source_to_config() {
  local nuget_config_file="$1"
  local source_name="$2"
  local source_path="$3"
  local tmp_file="${nuget_config_file}.tmp"

  if [ ! -f "$nuget_config_file" ]; then
    echo "ERROR: NuGet.config '$nuget_config_file' does not exist"
    exit 1
  fi

  # The entry has to go after any <clear /> inside <packageSources>, otherwise NuGet discards the
  # source we just added. awk rather than sed because that placement needs a line of lookahead.
  sed -E -e "/<add[[:space:]]+key=\"${source_name}\"/d" "$nuget_config_file" \
    | awk -v entry="    <add key=\"${source_name}\" value=\"${source_path}\" />" '
        /<packageSources>/ && !done { print; want = 1; next }
        want && !done {
          if ($0 ~ /<clear[[:space:]]*\/>/) { print; print entry; done = 1; want = 0; next }
          print entry; done = 1; want = 0; print; next
        }
        { print }
      ' > "$tmp_file"
  mv "$tmp_file" "$nuget_config_file"
}

# Echoes the version of a package in a flat directory of .nupkg files, e.g. passing
# "Microsoft.DotNet.Arcade.Sdk" for a directory holding
# "Microsoft.DotNet.Arcade.Sdk.11.0.0-beta.26411.119.nupkg" echoes "11.0.0-beta.26411.119".
# Echoes nothing when the package isn't present, which callers treat as "leave this one alone".
function find_package_version() {
  local packages_dir="$1"
  local package_id="$2"

  local package_path
  package_path=$(find "$packages_dir" -name "${package_id}.[0-9]*.nupkg" -print 2>/dev/null | sort | head -n 1)

  if [ -z "$package_path" ]; then
    return 0
  fi

  local file_name
  file_name=$(basename "$package_path" .nupkg)
  echo "${file_name#"${package_id}."}"
}
