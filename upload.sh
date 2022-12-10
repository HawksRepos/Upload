#!/bin/bash
#################################################################
# Author(s): Hawks                                                 #
# Version: v0.1.0                                               #
# Date: 2022-12-10                                              #
# Description:  Google file upload script that uses Rclone      #
#               and also cycles through Google Service Accounts #
#################################################################

# Global variables ##################
KEYS=20
CLEANSLEEP=86400
BASE="/home/hawks/.config/rclone/upload"
USERAGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.131 Safari/537.36"
EXCLUDEARRAY=("*.nfo" "*.jpeg" "*.jpg" "*sample*" "*SAMPLE*" "*.png" "*.html" "*.backup~" "*.partical~" "**_HIDDEN~" "*.unionfs/**" "**partial~" ".unionfs-fuse/**" ".fuse_hidden**" ".FUSE_HIDDEN**" "**.grab/**" "**sabnzbd**" "**nzbget**" "**qbittorrent**" "**rutorrent**" "**deluge**" "**transmission**" "**jdownloader**" "**makemkv**" "**handbrake**" "**bazarr**" "**ignore**" "**inProgress**" "**torrent**" "**nzb**")
SERVICE="/etc/systemd/system/upload.service"

### Creates readable/usable array for Rsync & Rclone command arguments ###
EXCLUDELIST=("${EXCLUDEARRAY[@]/#/--exclude=}")

### Log files ###
LOGS="$BASE/logs/upload.log"
VERBOSELOG="$BASE/logs/verbose.log"
ERRORLOG="$BASE/logs/error.log"

# Upload Functions ###################

log() {
    echo " $(date "+%Y-%m-%d %H:%M:%S") -- ${1} -- " >>${LOGS}
}

sudoCheck() {
    ### Check if script is running as root ###
    if [[ ! $(id -u) == "0" ]]; then 
        log "Script not running with Sudo. Exiting script now"
        exit 0
    fi
}

installRedis() {
    ### Redis is used to keep track of key position past script restarts and also allows for manual overide ###
    sudoCheck
    curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg 1>$VERBOSELOG 2>$ERRORLOG
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list 1>$VERBOSELOG 2>$ERRORLOG
    sudo apt-get update 1>$VERBOSELOG 2>$ERRORLOG
    sudo apt-get install redis 1>$VERBOSELOG 2>$ERRORLOG || exit 1
}

installRsync() {
    ### Rsync is used to copy over files into a neutral directory before they are uploaded ###
    sudoCheck
    sudo apt-get update 1>$VERBOSELOG 2>$ERRORLOG
    sudo apt-get install rsync 1>$VERBOSELOG 2>$ERRORLOG || exit 1
}

installRclone() {
    ### Rclone is used to upload files to Google Drive ###
    sudoCheck
    curl https://rclone.org/install.sh | sudo bash 1>$VERBOSELOG 2>$ERRORLOG || exit 1
}

installUpload() {
    ### Install and start upload service and exit manual running script ###
    sudoCheck
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
    log "Upload service now running. Exiting script and running as service"
    exit 3
}

startup() {
    ### Make required folder and files for the script ###
    mkdir -p $BASE/logs /mnt/{downloads,move} &
    ### Install apps required for upload script ###
    [[ -z $(command -v redis-cli) ]] && installRedis
    [[ -z $(command -v rsync) ]] && installRsync
    [[ -z $(command -v rclone) ]] && installRclone
    ### Create and start upload service if it doesn't exist ###
    service upload status &> /dev/null || installUpload
    ### Clear logs ###
    sleep 5
    : >$LOGS
    log "Starting Uploader"
}

keyRotate() {
    ### If the uploader gets stuck, restarting the service will automatically choose the next key ###
    if [[ -z "$(redis-cli GET liveKey)" || "$(redis-cli GET liveKey)" -gt $((KEYS - 1)) ]]; then
        redis-cli SET liveKey 1
        sa="GDSA$(redis-cli --raw GET liveKey)C"
    else
        sa="GDSA$(redis-cli --raw INCR liveKey)C"
    fi
}

fileWait() {
    ### Until files exist in the /mnt/move folder, keep looping while trying to sync files ###
    until [[ $(find "/mnt/move" -type f | wc -l) -gt 0 ]]; do
        log "Next key to be used: $sa"
        log "Currently no files to upload"
        log "Cleaning empty folders left behind"
        find /mnt/move/ -type d -empty -delete 1>$VERBOSELOG 2>$ERRORLOG
        log "Checking for new files to upload"
        rsync "/mnt/downloads/" "/mnt/move/" -aqp --remove-source-files --link-dest="/mnt/downloads/" "${EXCLUDELIST[@]}" 1>$VERBOSELOG 2>$ERRORLOG
        log "Sleeping for 20 seconds"
        echo " $(tail -n 1000 ${LOGS})" >${LOGS}
        sleep 20
    done
}

upload() {
    ### Once files exist in /mnt/move start the upload command ###
    log "Found files to upload, starting upload"
    log "Starting upload with $sa"
    rclone moveto "/mnt/move" "${sa}:/" \
        --config=${BASE}/rclone.conf \
        --log-file=${LOGS} \
        "${EXCLUDELIST[@]}" \
        --log-level=INFO \
        --stats=1s \
        --stats-file-name-length=0 \
        --max-size=300G \
        --tpslimit=100 \
        --tpslimit-burst=200 \
        --checkers=16 \
        --transfers=8 \
        --no-traverse \
        --fast-list \
        --skip-links \
        --cutoff-mode=SOFT \
        --drive-chunk-size=128M \
        --user-agent="${USERAGENT}" \
        --max-transfer=720G
    log "Completed upload with $sa"
    log "Rotating to next key"
}

cleanDownloads() {
    ### Print all file paths in folder to a temp file, then delete if they exist 24 hours later to keep clean ###
    find /mnt/downloads/nzb/ -type f >/dev/shm/files2Clean
    sleep $CLEANSLEEP
    log "Cleaning files in the download folder"
    while read -r f; do rm "$f" || :; done <"/dev/shm/files2Clean" 1>$VERBOSELOG 2>$ERRORLOG
    find /mnt/downloads/nzb/ -type d -empty -delete 1>$VERBOSELOG 2>$ERRORLOG
    log "Download folder cleansed"
}

# Script loop #####################
startup
while :; do cleanDownloads; done &
while :; do
    keyRotate
    fileWait
    upload
done
