#!/usr/bin/env bash
# bootstrap_steamcmd.sh (v1) by Emma / InvoxiPlayGames, 2026
# https://github.com/InvoxiPlayGames/bootstrap_steamcmd
#   v1 - 31/10/2026 - Initial release

STEAMCMD_DIR="${STEAMCMD_DIR:-./Steam/}"
mkdir -p $STEAMCMD_DIR
# TODO clear tmp dir on quit, but its tmp its okay
STEAMTMP=$(mktemp -d)
mkdir -p $STEAMTMP

echo "Bootstrapping SteamCMD into '$STEAMCMD_DIR'..."

# decide the manifest we want to use
CLIENT_SRV="https://client-update.steamstatic.com"
CLIENT_MANIFEST=""
CLIENT_OSNAME="linux"
UNAME=$(uname)
ARCH=$(uname -m)
GREPTYPE="GNU"
if [ "$UNAME" == "Linux" ]; then
    CLIENT_MANIFEST="steam_cmd_linux"
    CLIENT_OSNAME="linux"
    # FIXME check if BSD or GNU grep. most likely GNU, if youre GNUless you can't run SteamCMD, but...
elif [ "$UNAME" == "Darwin" ]; then
    CLIENT_MANIFEST="steam_cmd_osx"
    CLIENT_OSNAME="osx"
    GREPTYPE="BSD"
    # FIXME when Valve make the non-beta binary Universal
    if [ "$ARCH" == "arm64" ]; then
        CLIENT_MANIFEST="steam_cmd_publicbeta_osx"
    fi
else
    echo "Unknown OS type $UNAME, not continuing"
    exit 1
fi

echo "Downloading '$CLIENT_MANIFEST' manifest for platform '$CLIENT_OSNAME'"
raw_manifest=$(curl --progress-bar $CLIENT_SRV/$CLIENT_MANIFEST)
if [ ! $? -eq 0 ]; then
    echo "Failed to download file (status code $?), quitting..."
    exit 1
fi
# HACK stupid stupid stupid hack to "normalise" tabs and line endings for later
raw_manifest=$(echo $raw_manifest)

# TODO check to see if the curl response was successful
# TODO get the version from the manifest

# downloads a file from the Steam update manifest based on its key
download_manifest_file() {
    #reset all our variables
    current_file=
    current_size=
    current_sha2=
    current_IsBootstrapperPackage=
    #really shitty regular expressions to parse valve key/value pairs
    # FIXME these don't work on all manifest files without crap trick
    group_name=$1
    # garbage because of BSD vs GNU grep differences...
    if [ "$GREPTYPE" == "BSD" ]; then
        group_manifest=$(grep -Eo '\"'$group_name'\"\n?(?: +|\t+)\{([a-zA-Z0-9_\.\-\t\n\\\" ]*)(?: +|\t+)\}' <<< "$raw_manifest")
        group_filtered=$(grep -Eo '(?: +|\t+)"([0-9A-Za-z]*)"(?: +|\t+)"([0-9A-Za-z\._-]+)"' <<< "$group_manifest")
    else
        group_manifest=$(grep -Po '\"'$group_name'\"\n?(?: +|\t+)\{([a-zA-Z0-9_\.\-\t\n\\\" ]*)(?: +|\t+)\}' <<< "$raw_manifest")
        group_filtered=$(grep -Po '(?: +|\t+)"([0-9A-Za-z]*)"(?: +|\t+)"([0-9A-Za-z\._-]+)"' <<< "$group_manifest")
    fi
    # TODO the below sed regex is not correct and doesn't work with everything...
    group_parsed=$(sed -E 's/[[:space:]]+"([0-9A-Za-z]+)"[[:space:]]+"([0-9A-Za-z\._-]+)"/current_\1=\2/' <<< $group_filtered)
    #parse it as bash variables, populates stuff
    source <(echo "$group_parsed")
    if [ -z $current_file ]; then
        echo "Couldn't find file '$group_name' in manifest, quitting..."
        exit 1
    fi
    echo "Downloading '$current_file'..."
    curl --progress-bar -o $STEAMTMP/$current_file $CLIENT_SRV/$current_file
    if [ ! -f $STEAMTMP/$current_file ]; then
        echo "Failed to download file (file doesn't exist), quitting..."
        exit 1
    fi
    if [ ! $? -eq 0 ]; then
        echo "Failed to download file (status code $?), quitting..."
        exit 1
    fi
    dled_sha2=$(sha256sum -b $STEAMTMP/$current_file)
    # have to remove the filename suffix from sha256sum
    dled_sha2=${dled_sha2%% *}
    if [ ! "$dled_sha2" == "$current_sha2" ]; then
        echo "File checksum mismatched, quitting..."
        exit 1
    fi
    echo "Extracting '$current_file'..."
    unzip -d $STEAMCMD_DIR -o $STEAMTMP/$current_file > /dev/null
    if [ ! $? -eq 0 ]; then
        echo "Failed to unzip file, quitting..."
        exit 1
    fi
    # clean up
    rm $STEAMTMP/$current_file
}

# marks a file as executable if it exists
mark_executable_if_exists() {
    if [ -f "$STEAMCMD_DIR/$1" ]; then
        chmod +x "$STEAMCMD_DIR/$1"
    fi
}

# download the bare minimum to get steamcmd to be able to bootstrap itself
download_manifest_file "steamcmd_$CLIENT_OSNAME"
download_manifest_file "steamcmd_bins_$CLIENT_OSNAME"

# mark stuff as executable since zips don't carry those permissions
mark_executable_if_exists "steamcmd.sh"
mark_executable_if_exists "steamcmd"
mark_executable_if_exists "linux32/steamcmd"
mark_executable_if_exists "linux64/steamcmd"
mark_executable_if_exists "linuxarm64/steamcmd"

# patches steamcmd.sh to load from linux64 directory
read -d '' steamcmd_64bit_patcher <<EOF
#!/usr/bin/env bash
# steamcmd64.sh (v1) by Emma / InvoxiPlayGames 2026
# https://github.com/InvoxiPlayGames/bootstrap_steamcmd

echo "-- steamcmd64.sh bootstrapper --"
steamcmd_sh=\$(basename "\$0" 64.sh).sh
# patches steamcmd.sh to instead load from linux64 directory rather than linux32
patched_steamcmd_sh=\$(sed -E 's/: "\\\\\$\\\{STEAM_PLATFORM:=linux32\\\}"/: "\\\\\$\\\{STEAM_PLATFORM:=linux64\\\}" # patched by steamcmd64.sh/' \$steamcmd_sh)
# patches steamcmd to correct the basename that it gets the steamcmd executable name from (since basename would be our patch script)
patched_steamcmd_sh=\$(sed -E 's/STEAMCMD=\\\\\$\\\(basename "\\\\\$0" .sh\\\)/STEAMCMD=\\\\\$\\\(basename "\\\\\$0" 64.sh\\\) # patched by steamcmd64.sh/' <<< \$patched_steamcmd_sh)
# execute patched script
eval \"\$patched_steamcmd_sh\"
EOF
if [ "$UNAME" == "Linux" ] && [ "$ARCH" == "x86_64" ]; then
    # check if we have the 32-bit linker that steamcmd 32bit expects
    # maybe in the future i'll add a command line arg to force steamcmd64.sh's creation, but for now this is fine
    if [ ! -f "/lib/ld-linux.so.2" ]; then
        echo "No 32-bit binary support, creating steamcmd64.sh"
        steamcmd64_sh=$STEAMCMD_DIR/steamcmd64.sh
        echo "$steamcmd_64bit_patcher" > $steamcmd64_sh
        chmod +x $steamcmd64_sh
    fi
fi

# delete the temp dir
rm -rf $STEAMTMP
