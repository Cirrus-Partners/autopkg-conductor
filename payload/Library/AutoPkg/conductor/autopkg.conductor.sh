#!/bin/bash
set +e -uo pipefail

# This script is part of Cirrus Partners’ Munki deployment.
#
# This script executes AutoPkg for a list of recipes, after making sure
# dependencies are in place and everything is up-to-date.
#
# Based on https://github.com/rtrouton/autopkg-conductor/
#
# @author  Shawn Maddock <smaddock@gocirrus.com>
# @license https://opensource.org/licenses/MIT MIT
# @see     https://gitlab.gocirr.us/auto/autopkg-conductor

########################################
###         CONFIG VARIABLES         ###
########################################

# Set these for your environment

recipe_list_path="/Users/Shared/recipe_list.txt"
remote_munki_repo="my-munki-server:/var/www/html/munki_repo"

# These are set automatically

autopkg_user=$(id -un)
autopkg_user_home=$(dscl . -read "/Users/$autopkg_user" NFSHomeDirectory | awk '{print $2}')
autopkg_prefs="$autopkg_user_home/Library/Preferences/com.github.autopkg.plist"
munki_repo_path=$(/usr/libexec/PlistBuddy -c 'Print :MUNKI_REPO' "$autopkg_prefs")
overrides_dir=$(/usr/libexec/PlistBuddy -c 'Print :RECIPE_OVERRIDE_DIRS' "$autopkg_prefs")

########################################
###            FUNCTIONS             ###
########################################

# Define standard logger behavior
Logger() {
  flog -s com.github.autopkg.conductor -c "$2" -l "$1" "$3"
}

# Define logger behavior for debugging
LoggerDebug() {
  local json
  category="$1"
  # wrap as JSON and strip blank lines for portability and compactness
  json=$(jq \
    --compact-output \
    --raw-input \
    --slurp \
    'split("\n") | map(select(. != "")) | map(gsub("^\\s+|\\s+$"; ""))' <<< "${2:0:1000}")
  flog \
    -s com.github.autopkg.conductor \
    -c "$category" \
    -l debug \
    "$(printf '%s command output: {"commandOutput":%s}' "$category" "$json")"
}

# Iterate through reported failures and log. Unlikely to be more than one but it's an array.
ProcessFailures() {
  local failures i json message recipe_id traceback
  failures="$1"
  # loop through failure array
  i=0; while [[ $(jq ".[$i]" <<< "$failures") != "null" ]]; do
    # grab each field
    message=$(jq --raw-output ".[$i].message" <<< "$failures")
    recipe_id=$(jq --raw-output ".[$i].recipe" <<< "$failures")
    traceback=$(jq --raw-output ".[$i].traceback" <<< "$failures")
    shopt -s extglob
    message="${message//+([ $'\t'$'\n'])/ }"
    shopt -u extglob
    json=$(jq \
      --compact-output \
      --raw-input \
      --slurp \
      'split("\n") | map(select(. != "")) | map(gsub("^\\s+|\\s+$"; ""))' <<< "${traceback:0:800}")
    Logger \
      error \
      autopkg \
      "$(printf '%s failed: %s: {"traceback":%s}' "${recipe_id%.munki}" "$message" "$json")"
    ((++i))
  done
}

# Iterate through reported summary results
ProcessResults() {
  local log_grammar log_level processor results
  results="$1"
  while read -r processor; do
    case $processor in
      deprecation_summary_result)
        log_grammar='has been deprecated'
        log_level='default'
        ;;
      url_downloader_summary_result)
        log_grammar='was downloaded'
        log_level='info'
        ;;
      pkg_copier_summary_result)
        log_grammar='was copied'
        log_level='info'
        ;;
      app_pkg_creator_summary_result | chocolatey_packager_summary_result | pkg_creator_summary_result)
        log_grammar='was built'
        log_level='info'
        ;;
      munki_importer_summary_result)
        log_grammar='was imported into Munki'
        log_level='default'
        ;;
      *)
        log_grammar='was processed'
        log_level='default'
        ;;
    esac
    if [[ $(jq ".$processor" <<< "$results") != "null" ]]; then
      ProcessResultRows \
        "${processor%_summary_result}" \
        "$log_level" \
        "$log_grammar" \
        "$(jq ".$processor.data_rows" <<< "$results")"
    fi
  done <<< "$(jq --raw-output 'keys []' <<< "$results")"
}

# Iterate through data rows and log
ProcessResultRows() {
  local i field fields label log_grammar log_level processor rows value
  processor="$1"
  log_level="$2"
  log_grammar="$3"
  rows="$4"

  # shellcheck disable=SC2207
  IFS=$'\n' fields=($(jq --raw-output '.[0] | keys []' <<< "$rows"))

  i=0; while [[ $(jq ".[$i]" <<< "$rows") != "null" ]]; do
    label='Recipe'

    for field in "${fields[@]}"; do
      value=$(jq --raw-output ".[$i].$field" <<< "$rows")
      if [[ $field = 'name' ]]; then
        label="$value"
      elif [[ $field =~ ^(download_path|pkg_path)$ ]]; then
        # do some string splitting and parsing (ugly b/c bash 3 and no gawk)
        regex='local\.munki\.([^/]+)/'
        if [[ $value =~ $regex ]]; then
          label="${BASH_REMATCH[1]}"
        fi
      fi
    done

    Logger \
      "$log_level" \
      "$processor" \
      "$(printf '%s %s: %s' "$label" "$log_grammar" "$(jq --compact-output ".[$i]" <<< "$rows")")"
    ((++i))
  done
}

########################################
###         CONDITION CHECKS         ###
########################################

# If dependencies are not present or usable, log an error and stop execution.
if [[ ! -x $(which flog) ]]; then
  printf 'flog is not available within PATH:%s; exiting.' "$PATH"
  exit 1
fi
Logger info conductor "$(printf 'flog installed at %s.' "$(which flog)")"

if [[ ! -x $(which autopkg) ]]; then
  Logger error conductor "$(printf 'autopkg is not available within PATH:%s; exiting.' "$PATH")"
  exit 1
fi
Logger info conductor "$(printf 'AutoPkg installed at %s.' "$(which autopkg)")"

if [[ ! -x $(which jq) ]]; then
  Logger error conductor "$(printf 'jq in not available within PATH:%s; exiting.' "$PATH")"
  exit 1
fi
Logger info conductor "$(printf 'jq installed at %s.' "$(which jq)")"

if [[ ! -r $recipe_list_path ]]; then
  Logger error conductor "$(printf 'Recipe list is not readable at %s.; exiting.' "$recipe_list_path")"
  exit 1
fi
Logger info conductor "$(printf 'Recipe list located at %s.' "$recipe_list_path")"

########################################
###            MAIN SCRIPT           ###
########################################

start_exec=$(date +%s)
Logger default conductor "$(printf 'Started AutoPkg Conductor as %s.' "$autopkg_user")"

# Update AutoPkg recipe overrides
Logger info git 'Updating AutoPkg recipe overrides...'
if [[ ! -d $overrides_dir ]]; then
  Logger error git 'AutoPkg recipe override directory missing, skipping update.'
else
  pushd "$overrides_dir" &> /dev/null || exit
  if ! git_out=$(git pull 2>&1); then
    Logger error git 'Error updating AutoPkg recipe overrides via git, skipping update.'
  else
    Logger info git 'AutoPkg recipe overrides updated.'
  fi
  LoggerDebug git "$git_out"
  popd &> /dev/null || exit
fi

# Update AutoPkg repositories
Logger info repo_update 'Updating AutoPkg repositories...'
if ! repo_update_out=$(
  autopkg repo-update \
    --prefs="$autopkg_prefs" \
    all 2>&1 > /dev/null
); then
  Logger error repo_update 'Error updating AutoPkg repositories, skipping update.'
else
  Logger info repo_update 'AutoPkg repositories updated.'
fi
# only STDERR captured above due to the volume of output here
LoggerDebug repo_update "$repo_update_out"

# Run AutoPkg recipes
Logger info autopkg 'Running AutoPkg...'

# shellcheck disable=SC2207
IFS=$'\n' recipe_list=($(< $recipe_list_path))
for recipe in "${recipe_list[@]}"; do
  if [[ ! $recipe ]] || [[ $recipe =~ ^# ]]; then
    continue
  fi
  Logger default autopkg "$(printf 'Running AutoPkg recipe %s.' "$recipe")"
  run_out=$(autopkg run \
    --prefs="$autopkg_prefs" \
    --quiet \
    --report-plist="/private/tmp/autopkg_$recipe.plist" \
    "$recipe" makecatalogs.munki 2>&1)
  run_exit_code=$?
  if [[ $run_exit_code -ne 0 ]] && [[ $run_exit_code -ne 70 ]]; then
    Logger error autopkg 'Unknown error executing autopkg run.'
    LoggerDebug autopkg "$run_out"
  fi
  if [[ ! -r /private/tmp/autopkg_$recipe.plist ]]; then
    Logger error autopkg "$(printf 'Report property list for recipe %s is not readable; skipping logging.' "$recipe")"
    continue
  fi
  report=$(plutil -convert json -o - "/private/tmp/autopkg_$recipe.plist")
  if [[ $(jq '.failures[]' <<< "$report") ]]; then
    ProcessFailures "$(jq '.failures' <<< "$report")"
  fi
  if [[ $(jq '.summary_results[]' <<< "$report") ]]; then
    ProcessResults "$(jq '.summary_results' <<< "$report")"
  fi
  unset report
done
Logger info autopkg 'AutoPkg run finished.'

# rsync Munki repository to server
Logger info rsync 'Starting Munki repository sync...'
if ! rsync_out=$(
  rsync \
    --compress \
    --exclude=".DS_Store" \
    --exclude="/catalogs" \
    --omit-dir-times \
    --recursive \
    --times \
    --update \
    "$munki_repo_path/" \
    "$remote_munki_repo" 2>&1
); then
  Logger error rsync 'Error syncing Munki repository to server via rsync, skipping sync.'
else
  Logger info rsync 'Finished Munki repository sync.'
fi
LoggerDebug rsync "$rsync_out"

# Cleanup
rm -f /private/tmp/autopkg_*
rm -rf /private/tmp/munki-*
#rm -rf /private/tmp/tmp*

end_exec=$(date +%s)
Logger default conductor "$(printf 'Stopped AutoPkg Conductor after %d minutes.' $(((end_exec - start_exec) / 60)))"
