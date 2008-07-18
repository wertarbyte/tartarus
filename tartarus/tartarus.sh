#!/bin/bash
#
# Tartarus by Stefan Tomanek <stefan.tomanek@wertarbyte.de>
#            http://wertarbyte.de/tartarus.shtml
#
# Last change: $Date$
declare -r VERSION="0.5.2"

CMD_INCREMENTAL="no"
CMD_UPDATE="no"
PROFILE=""
# check command line
while ! [ "$1" == "" ]; do
    if [ "$1" == "-i" -o "$1" == "--inc" ]; then
        CMD_INCREMENTAL="yes"
    elif [ "$1" == "-u" -o "$1" == "--update" ]; then
        CMD_UPDATE="yes"
    else
        PROFILE=$1
    fi
    shift
done

debug() {
    DEBUGMSG="$*"
    hook DEBUG
    echo $DEBUGMSG >&2
}

requireCommand() {
    ERROR=0
    for CMD in $@; do
        which $CMD > /dev/null
        if [ ! $? -eq 0 ]; then
            echo "Unable to locate command '$CMD'"
            ERROR=1
        fi
    done
    return $ERROR
}

cleanup() {
    ABORT=$1
    hook PRE_CLEANUP
    if [ "$ABORT" -eq "1" ]; then
        debug "Canceling backup procedure and cleaning up..."
    fi

    if [ "$CREATE_LVM_SNAPSHOT" == "yes" ]; then
        umount $SNAPDEV 2> /dev/null
        lvremove -f $SNAPDEV 2> /dev/null
    fi
    if [ "$ABORT" -eq "1" ]; then
        debug "done"
    fi
    hook POST_CLEANUP
    exit $ABORT
}

# When processing a hook, we disable the triggering
# of new hooks to avoid loops
HOOKS_ENABLED=1
hook() {
    if [ "$HOOKS_ENABLED" -ne 1 ]; then
        return
    fi
    HOOKS_ENABLED=0
    HOOK="TARTARUS_$1_HOOK"
    # debug "Searching for $HOOK"
    shift
    # is there a defined hook function?
    if type "$HOOK" &> /dev/null; then
        debug "Executing $HOOK"
        "$HOOK" "$@"
    fi
    HOOKS_ENABLED=1
}

# Execute a command and embrace it with hooks
call() {
    METHOD="$1"
    shift
    # Hook functions are upper case
    MHOOK="$(echo "$METHOD" | tr '[:lower:]' '[:upper:]')"
    hook "PRE_$MHOOK"
    "$METHOD" "$@"
    RETURNCODE=$?
    if [ "$RETURNCODE" -ne 0 ]; then
        debug "Command '$METHOD $@' failed with exit code $RETURNCODE"
    fi
    hook "POST_$MHOOK"
}

# We can now check for newer versions of tartarus
update_check() {
    requireCommand curl awk || return
    VERSION_URL="http://wertarbyte.de/tartarus/upgrade-$VERSION"

    NEW_VERSION="$(curl -fs "$VERSION_URL")"
    if [ ! "$?" -eq 0 ]; then
        debug "Error checking version information."
        return 0
    fi

    awk -vCURRENT="$VERSION" -vNEW="$NEW_VERSION" '
BEGIN {
    n1 = split(CURRENT,current,".");
    n2 = split(NEW,new,".");
    while (i<=n1 || i<=n2) {
        x = current[i]
        y = new[i]
        if (x < y) exit 1
        if (x > y) exit 0
        i++;
    }
}
'
    if [ "$?" -eq 1 ]; then
        debug "!!! This script is probably outdated !!!"
        debug "An upgrade to version $NEW_VERSION is available. Please visit http://wertarbyte.de/tartarus.shtml"
        debug ""
        return 1
    fi
    return 0
}

# Do we only want to check for a new version?
if [ "$CMD_UPDATE" == "yes" ]; then
    update_check && debug "No new version available"
    cleanup 0
fi

if ! [ -e "$PROFILE" ]; then
    debug "You have to supply the path to a backup profile file."
    cleanup 1
fi


# Set default values:
SNAPSHOT_DIR="/snap"
LVM_SNAPSHOT_SIZE="200m"
BASEDIR="/"
EXCLUDE=""
EXCLUDE_FILES=""
# Profile specific
NAME=""
DIRECTORY=""
STAY_IN_FILESYSTEM="no"
CREATE_LVM_SNAPSHOT="no"
LVM_VOLUME_NAME=""
# Valid methods are:
# * FTP
# * FILE
# * SSH
# * SIMULATE
STORAGE_METHOD=""
STORAGE_FILE_DIR=""
STORAGE_FTP_SERVER=""
STORAGE_FTP_USER=""
STORAGE_FTP_PASSWORD=""
STORAGE_FTP_USE_SSL="no"
STORAGE_FTP_SSL_INSECURE="no"
STORAGE_SSH_DIR=""
STORAGE_SSH_USER=""
STORAGE_SSH_SERVER=""
# Options for incremental backups
INCREMENTAL_BACKUP="no"
INCREMENTAL_TIMESTAMP_FILE=""

# Encrypt the backup using a passphrase?
ENCRYPT_SYMMETRICALLY="no"
ENCRYPT_PASSPHRASE_FILE=""
# Encrypt using a public key?
ENCRYPT_ASYMMETRICALLY="no"
ENCRYPT_KEY_ID=""

LIMIT_DISK_IO="no"

CHECK_FOR_UPDATE="yes"

requireCommand tr tar find || cleanup 1

source "$PROFILE"

hook PRE_PROCESS

hook PRE_CONFIGVERIFY
# Has an incremental backup been demanded from the command line?
if [ "$CMD_INCREMENTAL" == "yes" ]; then
    # overriding config file and default setting
    INCREMENTAL_BACKUP="yes"
    debug "Switching to incremental backup because of commandline switch '-i'"
fi

# Do we want to check for a new version?
if [ "$CHECK_FOR_UPDATE" == "yes" ]; then
    debug "Checking for updates..."
    update_check
    debug "done"
fi

# NAME and DIRECTORY are mandatory
if [ -z "$NAME" -o -z "$DIRECTORY" ]; then
    debug "NAME and DIRECTORY are mandatory arguments."
    cleanup 1
fi

# Want incremental backups? Specify INCREMENTAL_TIMESTAMP_FILE
if [ "$INCREMENTAL_BACKUP" -a ! -e "$INCREMENTAL_TIMESTAMP_FILE"  ]; then
    debug "Unable to access INCREMENTAL_TIMESTAMP_FILE ($INCREMENTAL_TIMESTAMP_FILE)."
    cleanup 1
fi

# Do we want to limit the io load?
if [ "$LIMIT_DISK_IO" == "yes" ]; then
    requireCommand ionice || cleanup 1
    ionice -c3 -p $$
fi

# Do we want to freeze the filesystem during the backup run?
if [ "$CREATE_LVM_SNAPSHOT" == "yes" ]; then
    if [ -z "$LVM_VOLUME_NAME" ]; then
        debug "LVM_VOLUME_NAME is mandatory when using LVM snapshots"
        cleanup 1
    fi

    if [ -z "$LVM_MOUNT_DIR" ]; then
        debug "LVM_MOUNT_DIR is mandatory when using LVM snapshots"
        cleanup 1
    fi

    requireCommand lvdisplay lvcreate lvremove || cleanup 1

    # Check whether $LVM_VOLUME_NAME is a valid logical volume
    if ! lvdisplay "$LVM_VOLUME_NAME" > /dev/null; then
        debug "'$LVM_VOLUME_NAME' is not a valid LVM volume."
        cleanup 1
    fi

    # Check whether we have a direcory to mount the snapshot to
    if ! [ -d "$SNAPSHOT_DIR" ]; then
        debug "Snapshot directory '$SNAPSHOT_DIR' not found."
        cleanup 1
    fi
fi

constructFilename() {
    if [ "$INCREMENTAL_BACKUP" == "yes" ]; then
        BASEDON=$(date -r "$INCREMENTAL_TIMESTAMP_FILE" '+%Y%m%d-%H%M')
        INC="-inc-${BASEDON}"
    fi
    FILENAME="tartarus-${NAME}-${DATE}${INC}.tar${ARCHIVE_EXTENSION}"

    hook FILENAME
    
    echo $FILENAME
}

# Check backup storage options
if [ "$STORAGE_METHOD" == "FTP" ]; then
    if [ -z "$STORAGE_FTP_SERVER" -o -z "$STORAGE_FTP_USER" -o -z "$STORAGE_FTP_PASSWORD" ]; then
        debug "If FTP is used, STORAGE_FTP_SERVER, STORAGE_FTP_USER and STORAGE_FTP_PASSWORD are mandatory."
        cleanup 1
    fi
    
    requireCommand curl || cleanup 1

    # define storage procedure
    storage() {
        # stay silent, but print error messages if aborting
        OPTS="-u $STORAGE_FTP_USER:$STORAGE_FTP_PASSWORD -s -S"
        if [ "$STORAGE_FTP_USE_SSL" == "yes" ]; then
            OPTS="$OPTS --ftp-ssl"
        fi
        if [ "$STORAGE_FTP_SSL_INSECURE" == "yes" ]; then
            OPTS="$OPTS -k"
        fi
        FILE=$(constructFilename)
        URL="ftp://$STORAGE_FTP_SERVER/$FILE"
        debug "Uploading backup to $URL..."
        curl $OPTS --upload-file - "$URL"
    }
elif [ "$STORAGE_METHOD" == "FILE" ]; then
    if [ -z "$STORAGE_FILE_DIR" -a -d "$STORAGE_FILE_DIR" ]; then
        debug "If file storage is used, STORAGE_FILE_DIR is mandatory and must exist."
        cleanup 1
    fi
    
    requireCommand cat || cleanup 1
    
    # define storage procedure
    storage() {
        FILE="$STORAGE_FILE_DIR/$(constructFilename)"
        debug "Storing backup to $FILE..."
        cat - > $FILE
    }
elif [ "$STORAGE_METHOD" == "SSH" ]; then
    if [ -z "$STORAGE_SSH_SERVER" -o -z "$STORAGE_SSH_USER" -o -z "$STORAGE_SSH_DIR" ]; then
        debug "If SSH storage is used, STORAGE_SSH_SERVER, STORAGE_SSH_USER and STORAGE_SSH_DIR are mandatory."
        cleanup 1
    fi
    
    requireCommand ssh || cleanup 1

    # define storage procedure
    storage() {
        FILENAME=$( constructFilename )
        ssh -l "$STORAGE_SSH_USER" "$STORAGE_SSH_SERVER" "cat > $STORAGE_SSH_DIR/$FILENAME"
    }
elif [ "$STORAGE_METHOD" == "SIMULATE" ]; then

    storage() {
        FILENAME=$( constructFilename )
        debug "Proposed filename is $FILENAME"
        cat - > /dev/null
    }
elif [ "$STORAGE_METHOD" == "CUSTOM" ]; then
    if ! type "TARTARUS_CUSTOM_STORAGE_METHOD" &> /dev/null; then
        debug "If custom storage is used, a function TARTARUS_CUSTOM_STORAGE_METHOD has to be defined."
        cleanup 1
    fi
    storage() {
        TARTARUS_CUSTOM_STORAGE
    }
else
    debug "No valid STORAGE_METHOD defined."
    cleanup 1
fi

# compression method that does nothing
compression() {
    cat -
}
ARCHIVE_EXTENSION=""
if [ "$COMPRESSION_METHOD" == "bzip2" ]; then
    requireCommand bzip2 || cleanup 1
    compression() {
        bzip2
    }
    ARCHIVE_EXTENSION=".bz2"
elif [ "$COMPRESSION_METHOD" == "gzip" ]; then
    requireCommand gzip || cleanup 1
    compression() {
        gzip
    }
    ARCHIVE_EXTENSION=".gz"
fi

# Just a method that does nothing
encryption() {
    cat -
}

# We can only use one method of encryption at once
if [ "$ENCRYPT_SYMMETRICALLY" == "yes" -a "$ENCRYPT_ASYMMETRICALLY" == "yes" ]; then
    debug "ENCRYPT_SYMMETRICALLY and ENCRYPT_ASYMMETRICALLY are mutually exclusive."
    cleanup 1
fi

if [ "$ENCRYPT_SYMMETRICALLY" == "yes" ]; then
    requireCommand gpg || cleanup 1

    # Can we access the passphrase file?
    if ! [ -r "$ENCRYPT_PASSPHRASE_FILE" ]; then
        debug "ENCRYPT_PASSPHRASE_FILE '$ENCRYPT_PASSPHRASE_FILE' is not readable."
        cleanup 1
    else
        encryption() {
            # symmetric encryption
            gpg --no-tty -c --passphrase-file "$ENCRYPT_PASSPHRASE_FILE"
        }
    fi
fi

if [ "$ENCRYPT_ASYMMETRICALLY" == "yes" ]; then
    requireCommand gpg || cleanup 1

    # Can we access the passphrase file?
    if ! gpg --list-key "$ENCRYPT_KEY_ID" >/dev/null 2>/dev/null; then
        debug "Unable to find ENCRYPT_KEY_ID '$ENCRYPT_KEY_ID'."
        cleanup 1
    else
        encryption() {
            # asymmetric encryption
            gpg --no-tty --trust-model always --encrypt -r "$ENCRYPT_KEY_ID"
        }
    fi
fi

###
# Now we should have verified all arguments
hook POST_CONFIGVERIFY

# Make sure we clean up if the user aborts
trap "cleanup 1" INT

DATE="$(date +%Y%m%d-%H%M)"
# Let's start with the real work
debug "syncing..."
sync
if ! [ -z "$INCREMENTAL_TIMESTAMP_FILE" ]; then
    # Create temporary timestamp file
    echo $DATE > "${INCREMENTAL_TIMESTAMP_FILE}.running"
fi

if [ "$CREATE_LVM_SNAPSHOT" == "yes" ]; then
    # create an LVM snapshot
    SNAPDEV="${LVM_VOLUME_NAME}_snap"
    # Call the hook script
    hook PRE_FREEZE

    lvcreate --size $LVM_SNAPSHOT_SIZE --snapshot --name ${LVM_VOLUME_NAME}_snap $LVM_VOLUME_NAME || (debug "Unable to create snapshot, aborting"; cleanup 1)
    # and another hook
    hook POST_FREEZE
    # mount the new volume
    mkdir -p "$SNAPSHOT_DIR/$LVM_MOUNT_DIR" || (debug "Unable to create mountpoint, aborting"; cleanup 1)
    mount "$SNAPDEV" "$SNAPSHOT_DIR/$LVM_MOUNT_DIR" || (debug "Unable to mount snapshot, aborting"; cleanup 1)
    BASEDIR="$SNAPSHOT_DIR"
fi

# Construct excludes for find
EXCLUDES=""
for i in $EXCLUDE; do
    i=$(echo $i | sed 's#^/#./#; s#/$##')
    # Don't descend in the excluded directory, but print the directory itself
    EXCLUDES="$EXCLUDES -path $i -prune -print0 -o"
done
for i in $EXCLUDE_FILES; do
    i=$(echo $i | sed 's#^/#./#; s#/$##')
    # Ignore files in the directory, but include subdirectories
    EXCLUDES="$EXCLUDES -path '$i/*' ! -type d -prune -o"
done

debug "Beginning backup run..."

OLDDIR=$(pwd)
# We don't want absolut paths
BDIR=$(echo $DIRECTORY | sed 's#^/#./#')
# $BASEDIR is either / or $SNAPSHOT_DIR
cd "$BASEDIR"


TAROPTS="--no-unquote --no-recursion"
FINDOPTS=""
FINDARGS="-print0"
if [ "$STAY_IN_FILESYSTEM" == "yes" ]; then
    FINDOPTS="$FINDOPTS -xdev "
fi

if [ "$INCREMENTAL_BACKUP" == "yes" ]; then
    FINDARGS="-newer $INCREMENTAL_TIMESTAMP_FILE $FINDARGS"
fi

# Make sure that an error inside the pipeline propagates
set -o pipefail

hook PRE_STORE

call find "$BDIR" $FINDOPTS $EXCLUDES $FINDARGS | \
    call tar cp $TAROPTS --null -T -  | \
    call compression | \
    call encryption | \
    call storage

BACKUP_FAILURE=$?

hook POST_STORE

cd $OLDDIR

if [ ! "$BACKUP_FAILURE" -eq 0 ]; then
    debug "ERROR creating/processing/storing backup, check above messages"
    cleanup 1
fi

# If we did a full backup, we might want to update the timestamp file
if [ ! -z "$INCREMENTAL_TIMESTAMP_FILE" -a ! "$INCREMENTAL_BACKUP" == "yes" ]; then
    if [ -e "$INCREMENTAL_TIMESTAMP_FILE" ]; then
        OLDDATE=$(< $INCREMENTAL_TIMESTAMP_FILE)
        cp -a "$INCREMENTAL_TIMESTAMP_FILE" "$INCREMENTAL_TIMESTAMP_FILE.$OLDDATE"
    fi
    mv "${INCREMENTAL_TIMESTAMP_FILE}.running" "$INCREMENTAL_TIMESTAMP_FILE"
fi

hook POST_PROCESS

cleanup 0
