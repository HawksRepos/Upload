#!/bin/bash
#################################################################
# Author(s): Hawks & LubricantJam                               #
# Version: v0.2.2                                               #
# Date: 2023-02-08                                              #
# Description:  Dropbox file upload script that uses Rclone     #
#################################################################

# Global variables ##################
KEYS=3
TRANSFERS=8
CLEANTIME="02:00"
RESETTIME="00:00"
DOWNLOADPATH="/mnt/downloads"
BASE="/docker/upload"
USERAGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.131 Safari/537.36"
EXCLUDEARRAY=("*.nfo" "*.jpeg" "*.jpg" "*sample*" "*SAMPLE*" "*.png" "*.html" "*.backup~" "*.partical~" "**_HIDDEN~" "*.unionfs/**" "**partial~" ".unionfs-fuse/**" ".fuse_hidden**" ".FUSE_HIDDEN**" "**.grab/**" "**sabnzbd**" "**nzbget**" "**qbittorrent**" "**rutorrent**" "**deluge**" "**transmission**" "**jdownloader**" "**makemkv**" "**handbrake**" "**bazarr**" "**ignore**" "**inProgress**" "**torrent**" "**nzb**")
WEBHOOK='https://WEBHOOK-URL'

# Include http/https and the port (even if proxied) to the below variable
PLEX_API_URL="https://plex.domain.com:443"
PLEX_API_TOKEN="YOUR-PLEX-TOKEN"
PLEX_MOVIES_LIBRARY_ID=1
PLEX_SHOWS_LIBRARY_ID=3
PLEX_ANIME_LIBRARY_ID=2

### Creates readable/usable array for Rsync & Rclone command arguments ###
EXCLUDELIST=("${EXCLUDEARRAY[@]/#/--exclude=}")

### Log files ###
LOGS="$BASE/logs/upload.log"
VERBOSELOG="$BASE/logs/verbose.log"
ERRORLOG="$BASE/logs/error.log"

# Start Up Functions #######################################################
sendNotification() {
    curl -H "Content-Type: application/json" -X POST -d "{\"embeds\": [{\"title\": \"$1\", \"description\": \"$2\", \"color\": \"$3\"}]}" $WEBHOOK
}

log() {
    echo " $(date "+%Y-%m-%d %H:%M:%S") -- ${1} -- " >>${LOGS}
}

startup() {
    ### Make required folder and files for the script ###
    mkdir -p $BASE/logs /mnt/{downloads,move} &
    ### Install apps required for upload script ###
    for program in redis-cli rsync rclone; do
        [[ -z $(command -v $program) ]] && install-$program
    done
    ### Create and start upload service if it doesn't exist ###
    service upload status &> /dev/null || install-upload
    ### Clear logs ###
    sleep 5
    : >$LOGS
    # Reset upload slots to 0 on script restart
    redis-cli SET uploadSlot 0
    # Reset the fileLocks
    keys=$(redis-cli KEYS "fileLock:*")
    # Iterate through each key and delete it
    while read -r key; do
        redis-cli DEL "$key"
        log "Deleted the file lock: $key"
    done <<< "$keys"
    # Initial launch message
    title="Initial Launch"
    msg="The upload service is now online and watching for uploads."
    msgColor="4321431"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
}

# Upload Functions ########################################################
keyRotate() {
    ### If the uploader gets stuck, restarting the service will automatically choose the next key ###
    if [[ -z "$(redis-cli GET liveKey)" || "$(redis-cli GET liveKey)" -gt $((KEYS - 1)) ]]; then
        redis-cli SET liveKey 1
        sa="dcrypt-$(redis-cli --raw GET liveKey)"
    else
        sa="dcrypt-$(redis-cli --raw INCR liveKey)"
    fi
    title="Key Rotation"
    msg="Moving to the service key \`$sa\`. \nWaiting for files to upload."
    msgColor="16172079"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    fileWait
}

fileWait() {
    ### Until files exist in the /mnt/move folder, keep looping while trying to sync files ###
    until [[ $(find "$DOWNLOADPATH/" -type f ! -path "$DOWNLOADPATH/nzb/*" | wc -l) -gt 0 ]]; do
        log "Checking for new files to upload with: $sa"
        echo " $(tail -n 1000 ${LOGS})" >${LOGS}
        sleep 60
    done
    msg="Checking key \`$sa\` to start the upload."
    log "$msg"
    upload
}

upload() {
    # Create list of files that need to be moved
    mapfile -t uploadFiles < <(find $DOWNLOADPATH -type f ! -path "$DOWNLOADPATH/nzb/*")
    # Loop through the list of files to upload
    for Ufile in "${uploadFiles[@]}"; do
        # Make sure only 4 files are uploaded at once
        while [[ $(redis-cli --raw GET uploadSlot) -ge ${TRANSFERS} ]]; do
            # While upload slots are full, sleep for 30 second
            sleep 30
            log "Upload slots full, sleeping for 30 seconds before trying again."
        done

        file=$(basename "$Ufile")
        # Check if the file is already being uploaded
        if [ "$(redis-cli GET "fileLock:$file")" != "1" ]; then
            # Update key size in database
            updateSize "$Ufile"
            # Upload files as a background process
            fileUpload &
        else
            log "'$file' is already being uploaded."
        fi

        # Sleep to not rush the loop and allow redis time to update
        sleep 5
    done
}

updateSize() {
    totalSize=$(du -cb "$1" | awk 'END {print $1}')
    keySize=$(redis-cli GET "keySize:$sa")
    [[ -z "$keySize" ]] && keySize=0
    keySize=$((keySize + totalSize))
    # Max upload size in bytes
    if [[ $keySize -gt 107374182400 ]]; then
        # Comment the line below if not using dropbox
        redis-cli SET "keySize:$sa" 0
        keyRotate
    else
        redis-cli SET "keySize:$sa" $keySize
    fi
}

fileUpload() {
    local="${Ufile#"$DOWNLOADPATH"/}"
    remote=$(dirname "${local}")
    file=$(basename "$Ufile")
    size=$(du -cah "$Ufile" 2>/dev/null | tail -1 | cut -f 1)
    rawDiskSpace=$(($(stat -f --format="%a*%S" .)))
    diskSpace=$(( rawDiskSpace / 2**30 ))"GB"
    title="Uploading File"
    msg="File upload has started. \n\nKey: \`\`\`$sa\`\`\` \nSize: \`\`\`$size\`\`\` \nFile: \`\`\`$file\`\`\` \nFree Disk Space: \`\`\`$diskSpace\`\`\`"
    msgColor="15695665"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    # Add upload slot as taken
    redis-cli --raw INCR uploadSlot
    # Add a file lock so that the same file is not uploaded twice
    redis-cli SET "fileLock:$file" 1
    # Rclone move but with 2h kill timeout, incase it get's stuck
    # Dropbox
    timeout -k 10 2h rclone move "$Ufile" "${sa}:/$remote" \
        --config=/docker/rclone/rclone.conf \
        --log-file=${LOGS} \
        "${EXCLUDELIST[@]}" \
        --log-level=DEBUG \
        --stats=1s \
        --stats-file-name-length 0 \
        --order-by=modtime,ascending \
        --transfers=${TRANSFERS} \
        --checkers=${TRANSFERS} \
        --dropbox-chunk-size=128M \
        --user-agent="${USERAGENT}"
    # Set variables for notification
    rawDiskSpace=$(($(stat -f --format="%a*%S" .)))
    diskSpace=$(( rawDiskSpace / 2**30 ))"GB"
    rawKeyUsed=$(redis-cli --raw GET "keySize:$sa")
    keyUsed=$(( rawKeyUsed / 2**30 ))"GB"
    title="Upload Complete"
    msg="File has successfully been uploaded. \n\nKey: \`\`\`$sa\`\`\` \nKey Used: \`\`\`$keyUsed\`\`\` \nFile Size: \`\`\`$size\`\`\` \nFile: \`\`\`$file\`\`\` \nFree Disk Space: \`\`\`$diskSpace\`\`\`"
    msgColor="4321431"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    # Free up upload slot on completion
    redis-cli --raw DECR uploadSlot
    # Remove the file lock so that the same file is not uploaded twice
    redis-cli DEL "fileLock:$file"
    # Give the drive a chance to load the file before autoscanning.
    sleep 60
    # Fire off the autoscan
    autoScan
}

autoScan() {
    if [[ "$remote" =~ ^movies/.* ]]; then
        libraryid=$PLEX_MOVIES_LIBRARY_ID
        log "Autoscan: Movie Detected for ${remote}"
    elif [[ "$remote" =~ ^tv/.* ]]; then
        libraryid=$PLEX_SHOWS_LIBRARY_ID
        log "Autoscan: Show Detected for ${remote}"
    elif [[ "$remote" == *"anime"* ]]; then
        libraryid=$PLEX_ANIME_LIBRARY_ID
        log "Autoscan: Anime Detected for ${remote}"
    else
        libraryid=0
    fi

    if [ $libraryid -eq 0 ]; then
        log "Autoscan: Library ID not found for: ${remote}"
    else
        log "Running autoscan for '${file}'"
        curl "${PLEX_API_URL}/library/sections/${libraryid}/refresh?path=/mnt/unionfs/${remote}&X-Plex-Token=${PLEX_API_TOKEN}" | sudo bash 1>$VERBOSELOG
    fi
}

# Long-running Loops ######################################################
cleanDownloads() {
    ### Print all file paths in folder to a temp file, then delete if they exist 24 hours later to keep clean ###
    if [[ $(date +%R) == "$CLEANTIME" ]]; then
        find ${DOWNLOADPATH}/nzb/ -type f >/dev/shm/files2Clean
        title="Cleaning Downloads"
        msg="Removing old files from the downloads folder."
        msgColor="39129"
        sendNotification "$title" "$msg" "$msgColor"
        log "$msg"
        while read -r f; do rm "$f" || :; done <"/dev/shm/files2Clean" 1>$VERBOSELOG 2>$ERRORLOG
        find "${DOWNLOADPATH}/nzb/" -type d -empty -delete 1>$VERBOSELOG 2>$ERRORLOG
        find "${DOWNLOADPATH}" -mindepth 1 -type d -empty -delete 1>$VERBOSELOG 2>$ERRORLOG
        msg="Success! Downloads have been cleaned"
        msgColor="4321431"
        sendNotification "$title" "$msg" "$msgColor"
        log "$msg"
        sleep 60
    fi
}

resetSizes() {
    if [[ $(date +%R) == "$RESETTIME" ]]; then
        for i in $(seq 1 "$KEYS" ); do
            key="dcrypt-${i}"
            redis-cli SET "keySize:$key" 0
        done
        title="Key Reset"
        msg="Reset all key limits. \nReady to upload."
        msgColor="16172079"
        sendNotification "$title" "$msg" "$msgColor"
        log "$msg"
        sleep 60
    fi
}

# Script loop #############################################################
startup                                 # Check if everything is installed and running
keyRotate                               # Rotate the key on start-up, in case they get stuck

while :; do cleanDownloads; done &      # Start the download folder cleaning loop
while :; do resetSizes; done &          # Start the key reset loop
while :; do fileWait; done              # Start the uploading script sequance