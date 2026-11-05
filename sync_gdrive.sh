#!/bin/bash
set -e

# --- CONFIGURATION ---
# Format: "DriveFolderName:GithubPath"
# Example: "My_Reels:videos music_folder:assets/audio"
MAPPINGS="audio:audio reels/Darkambientplaylist:reels"

echo "🔐 Setting up Path-Specific Smart Sync..."

# 1. Prepare Rclone & Auth
curl https://rclone.org/install.sh | sudo bash
mkdir -p ~/.config/rclone
echo "$GDRIVE_SERVICE_ACCOUNT" > ~/.config/rclone/service_account.json

cat <<EOF > ~/.config/rclone/rclone.conf
[private_drive]
type = drive
service_account_file = $HOME/.config/rclone/service_account.json
scope = drive.readonly
EOF

# 2. Loop through Mappings
if [ -n "$GDRIVE_FOLDER_ID" ]; then
    for MAP in $MAPPINGS; do
        # Split the mapping into Source and Destination
        SRC_FOLDER=${MAP%%:*}
        DEST_PATH=${MAP#*:}

        echo "🔄 Syncing Drive [$SRC_FOLDER] to GitHub [$DEST_PATH]..."
        
        # Ensure the custom local directory exists
        mkdir -p "./$DEST_PATH"

        # Mirror the folder
        rclone sync "private_drive:$SRC_FOLDER" "./$DEST_PATH" \
            --drive-root-folder-id "$GDRIVE_FOLDER_ID" \
            --checksum \
            --verbose \
            --transfers 4
    done
else
    echo "❌ ERROR: GDRIVE_FOLDER_ID missing" && exit 1
fi

# 3. PUSH TO REPOSITORY
echo "📤 Committing changes..."
rm ~/.config/rclone/service_account.json 

git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"

git add .
git commit -m "Automated Warehouse Sync [skip ci]" || echo "No changes to commit"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git push origin "$CURRENT_BRANCH"

echo "✅ Custom path sync complete!"
