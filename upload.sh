#!/bin/bash
#################################################################
# Author(s): Hawks                                              #
# Version: v0.1.2                                               #
# Date: 2022-12-16                                              #
# Description:  Google file upload script that uses Rclone      #
#               and also cycles through Google Service Accounts #
#################################################################

# Global variables ##################
KEYS=20
CLEANTIME="02:00"
MOVEPATH="/mnt/move"
DOWNLOADPATH="/mnt/downloads"
BASE="/rclone/upload"
USERAGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.131 Safari/537.36"
EXCLUDEARRAY=("*.nfo" "*.jpeg" "*.jpg" "*sample*" "*SAMPLE*" "*.png" "*.html" "*.backup~" "*.partical~" "**_HIDDEN~" "*.unionfs/**" "**partial~" ".unionfs-fuse/**" ".fuse_hidden**" ".FUSE_HIDDEN**" "**.grab/**" "**sabnzbd**" "**nzbget**" "**qbittorrent**" "**rutorrent**" "**deluge**" "**transmission**" "**jdownloader**" "**makemkv**" "**handbrake**" "**bazarr**" "**ignore**" "**inProgress**" "**torrent**" "**nzb**")
WEBHOOK='https://discord.com/api/webhooks/Your-Web-Hook'
SERVICE="/etc/systemd/system/upload.service"

### Creates readable/usable array for Rsync & Rclone command arguments ###
EXCLUDELIST=("${EXCLUDEARRAY[@]/#/--exclude=}")

### Log files ###
LOGS="$BASE/logs/upload.log"
VERBOSELOG="$BASE/logs/verbose.log"
ERRORLOG="$BASE/logs/error.log"

# Upload Functions ###################

sudoCheck() {
    ### Check if script is running as root ###
    if [[ ! $(id -u) == "0" ]]; then
        log "Script not running with Sudo. Exiting script now"
        exit 0
    fi
}

sendNotification() {
    curl -H "Content-Type: application/json" -X POST -d "{\"embeds\": [{\"title\": \"$1\", \"description\": \"$2\", \"color\": \"$3\"}]}" $WEBHOOK
}

log() {
    echo " $(date "+%Y-%m-%d %H:%M:%S") -- ${1} -- " >>${LOGS}
}

install-redis-cli() {
    ### Redis is used to keep track of key position past script restarts and also allows for manual overide ###
    sudoCheck
    title="Redis Missing"
    msg="Redis has not been detected, installing this now."
    msgColor="12001826"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg 1>$VERBOSELOG 2>$ERRORLOG
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list 1>$VERBOSELOG 2>$ERRORLOG
    sudo apt-get update 1>$VERBOSELOG 2>$ERRORLOG
    sudo apt-get install redis 1>$VERBOSELOG 2>$ERRORLOG || exit 1
}

install-rsync() {
    ### Rsync is used to copy over files into a neutral directory before they are uploaded ###
    sudoCheck
    title="Rsync Missing"
    msg="Rsync has not been detected, installing this now."
    msgColor="12001826"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    sudo apt-get update 1>$VERBOSELOG 2>$ERRORLOG
    sudo apt-get install rsync 1>$VERBOSELOG 2>$ERRORLOG || exit 1
}

install-rclone() {
    ### Rclone is used to upload files to Google Drive ###
    sudoCheck
    title="Rclone Missing"
    msg="Rclone has not been detected, installing this now."
    msgColor="12001826"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    curl https://rclone.org/install.sh | sudo bash 1>$VERBOSELOG 2>$ERRORLOG || exit 1
}

install-upload() {
    ### Install and start upload service and exit manual running script ###
    sudoCheck
    title="Upload Service Missing"
    msg="The upload service has not been detected, installing this now."
    msgColor="12001826"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    [[ ! -f "$SERVICE" ]] && sudo tee -a $SERVICE <<EOF
[Unit]
After=network-online.target

[Service]
Type=simple
User=0
Group=0
ExecStart=/bin/bash $BASE/upload.sh
ExecReload=/bin/kill -s TERM \$MAINPID
ExecStop=/bin/kill -s TERM \$MAINPID
TimeoutStopSec=5
KillMode=control-group

[Install]
WantedBy=default.target
EOF
    sudo systemctl daemon-reload 1>$VERBOSELOG 2>$ERRORLOG
    sudo systemctl enable upload.service 1>$VERBOSELOG 2>$ERRORLOG || exit 2
    sudo systemctl start upload.service 1>$VERBOSELOG 2>$ERRORLOG || exit 2
    msg="Upload service now running. Exiting script and running as service."
    msgColor="12001826"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    exit 3
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
    title="Initial Launch"
    msg="The upload service is now online and watching for uploads."
    msgColor="4321431"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
}

keyRotate() {
    ### If the uploader gets stuck, restarting the service will automatically choose the next key ###
    if [[ -z "$(redis-cli GET liveKey)" || "$(redis-cli GET liveKey)" -gt $((KEYS - 1)) ]]; then
        redis-cli SET liveKey 1
        sa="GDSA$(redis-cli --raw GET liveKey)C"
    else
        sa="GDSA$(redis-cli --raw INCR liveKey)C"
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
    until [[ $(find "${MOVEPATH}" -type f | wc -l) -gt 0 ]]; do
        find $MOVEPATH/ -type d -empty -delete 1>$VERBOSELOG 2>$ERRORLOG
        log "Checking for new files to upload with: $sa"
        rsync "$DOWNLOADPATH/" "$MOVEPATH/" -aqp --remove-source-files --link-dest="$DOWNLOADPATH/" "${EXCLUDELIST[@]}" 1>$VERBOSELOG 2>$ERRORLOG
        echo " $(tail -n 1000 ${LOGS})" >${LOGS}
        sleep 30
    done
    title="File Detected"
    msg="Using key \`$sa\` to start the upload."
    msgColor="39129"
    sendNotification "$title" "$msg" "$msgColor"
    log "$msg"
    upload
}

upload() {
    ### Once files exist in /mnt/move start the upload command ###
    mapfile -t uploadFiles < <(find ${MOVEPATH} -type f)
    for Ufile in "${uploadFiles[@]}"; do
        file=$(basename "$Ufile")
        size=$(du -cah "$Ufile" 2>/dev/null | tail -1 | cut -f 1)
        title="Uploading File"
        msg="File upload has started. \n\nKey: \`\`\`$sa\`\`\` \nSize: \`\`\`$size\`\`\` \nFile: \`\`\`$file\`\`\`"
        msgColor="15695665"
        sendNotification "$title" "$msg" "$msgColor"
    done &
    rclone move "${MOVEPATH}" "${sa}:/" \
        --config=${BASE}/rclone.conf \
        --log-file=${LOGS} \
        "${EXCLUDELIST[@]}" \
        --log-level=INFO \
        --stats=1s \
        --stats-file-name-length=0 \
        --max-size=300G \
        --checkers=16 \
        --transfers=8 \
        --no-traverse \
        --fast-list \
        --skip-links \
        --cutoff-mode=SOFT \
        --drive-chunk-size=512M \
        --user-agent="${USERAGENT}" \
        --max-transfer=720G
    for Cfile in "${uploadFiles[@]}"; do
        file=$(basename "$Cfile")
        title="Upload Complete"
        msg="File has successfully been uploaded. \n\nKey: \`\`\`$sa\`\`\` \nFile: \`\`\`$file\`\`\`"
        msgColor="4321431"
        sendNotification "$title" "$msg" "$msgColor"
        log "$msg"
    done
}

cleanDownloads() {
    ### Print all file paths in folder to a temp file, then delete if they exist 24 hours later to keep clean ###
    if [[ $(date +%R) == "$CLEANTIME" ]]; then
        find ${DOWNLOADPATH}/nzb/ -type f >/dev/shm/files2Clean
        title="Cleaning Downloads"
        msg="Removing old files from the downloads folder."
        msgColor="39129"
        sendNotification "$title" "$msg" "$msgColor"
        log "$msg"
        # SAVED=$(du -cah $(cat /dev/shm/files2Clean) 2>/dev/null | tail -1 | cut -f 1)
        while read -r f; do rm "$f" || :; done <"/dev/shm/files2Clean" 1>$VERBOSELOG 2>$ERRORLOG
        find ${DOWNLOADPATH}/nzb/ -type d -empty -delete 1>$VERBOSELOG 2>$ERRORLOG
        msg="Success! Downloads have been cleaned"
        msgColor="4321431"
        sendNotification "$title" "$msg" "$msgColor"
        log "$msg"
    fi
}

# Script loop #####################
startup
while :; do cleanDownloads; done &
while :; do keyRotate; done