#!/bin/bash
set -e

# --- 1. CONFIGURATION ---
TMP=$(mktemp -d)
INPUT_DIR="./reels"
LYRICAL_DIR="./lyrical-reel"
LOGO_PATH="./assets/spotify.png"
OUTPUT_DIR="./output"

mkdir -p "$OUTPUT_DIR"

# --- 2. ASSET PICKING (WITH MEMORY TRACKER) ---
# Background videos: remain purely random
FILES=($(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \) | shuf -n 20))
if [ ${#FILES[@]} -eq 0 ]; then echo "❌ No background videos found"; exit 1; fi

# Lyrical reels: Random without replacement
PLAYED_FILE="./assets/played_lyrics.txt"
mkdir -p ./assets
touch "$PLAYED_FILE"

# Get all lyrical reels safely handling spaces in filenames
mapfile -t ALL_LYRICS < <(find "$LYRICAL_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \))
if [ ${#ALL_LYRICS[@]} -eq 0 ]; then echo "❌ No lyrical reel found"; exit 1; fi

# Filter out files that have already been played
UNPLAYED=()
for f in "${ALL_LYRICS[@]}"; do
    bname=$(basename "$f")
    if ! grep -qFx "$bname" "$PLAYED_FILE"; then
        UNPLAYED+=("$f")
    fi
done

# If all files have been played, reset the tracker to start a new cycle
if [ ${#UNPLAYED[@]} -eq 0 ]; then
    echo "🔄 All lyrical reels have been used! Starting a new cycle..."
    > "$PLAYED_FILE"
    UNPLAYED=("${ALL_LYRICS[@]}")
fi

# Pick a random file from the UNPLAYED list
RAND_IDX=$((RANDOM % ${#UNPLAYED[@]}))
LYRICS_FILE="${UNPLAYED[$RAND_IDX]}"

# Save the chosen file to the tracker so it doesn't get picked again
basename "$LYRICS_FILE" >> "$PLAYED_FILE"
echo "🎶 Selected Lyrical Reel: $(basename "$LYRICS_FILE")"


# --- 3. MERGE CLIPS ---
echo "🎬 Step 1: Processing Background Clips..."
i=1
for f in "${FILES[@]}"; do
  ffmpeg -i "$f" -t 1 -vf "scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black,fps=30" \
    -c:v libx264 -preset superfast -pix_fmt yuv420p -an "$TMP/clip_$i.mp4" -y -loglevel error
  echo "file '$TMP/clip_$i.mp4'" >> "$TMP/list.txt"
  i=$((i+1))
done

MERGED_RAW="$TMP/merged_raw.mp4"
ffmpeg -f concat -safe 0 -i "$TMP/list.txt" -c copy "$MERGED_RAW" -y -loglevel error

# Set a strict target duration for the final reel
TARGET_DUR=20

# --- 4. APPLY LYRICS, LOGO & AUDIO ---
echo "🎨 Step 2: Applying Lyrics & Visuals (Target Duration: ${TARGET_DUR}s)..."

# Safe fade calculations for the logo based on the 20s target
logo_start=$(echo "$TARGET_DUR" | awk '{print $1 / 2}')
logo_fade_out=$(echo "$TARGET_DUR" | awk '{print $1 - 0.5}')

# Generate file name based on the chosen lyrical reel
safe_name=$(basename "$LYRICS_FILE" | sed 's/\.[^.]*$//' | tr -cd '[:alnum:] ' | cut -c1-50 | xargs)
url_filename="${safe_name// /_}.mp4"
out_file="$OUTPUT_DIR/$url_filename"

# Filter Explanation:
# [2:v] prepares the logo
# [1:v] prepares the lyrics video. colorkey=black removes the black background. 
# [bg_lyric] overlays the transparent lyrics onto the background clips
# [v_f] overlays the logo onto the combined video
# [1:a] adds a 2-second audio fade out starting at 18s so the music doesn't end abruptly
FILTER="[2:v]scale=180:-1,format=rgba,fade=t=in:st=${logo_start}:d=0.5:alpha=1,fade=t=out:st=${logo_fade_out}:d=0.5:alpha=1[logo_p]; \
[1:v]scale=1080:1920:force_original_aspect_ratio=decrease,colorkey=black:0.1:0.2[lyrics]; \
[0:v][lyrics]overlay=x=(W-w)/2:y=(H-h)/2[bg_lyric]; \
[bg_lyric][logo_p]overlay=x=(W-w)/2:y=H-h-80[v_f]; \
[1:a]afade=t=out:st=18:d=2[aud]"

# Execute the final combined render
# -stream_loop -1 on MERGED_RAW loops the background video so it never freezes
# -t $TARGET_DUR forces the exact 20 second cutoff
ffmpeg -stream_loop -1 -i "$MERGED_RAW" -i "$LYRICS_FILE" -loop 1 -i "$LOGO_PATH" \
  -filter_complex "$FILTER" \
  -map "[v_f]" -map "[aud]" -t $TARGET_DUR \
  -c:v libx264 -preset veryslow -crf 24 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart "$out_file" -y -loglevel warning

# --- 5. GITHUB UPLOAD (FORCE PUSH TO SAVE SPACE) ---
if [ -f "$out_file" ]; then
    echo "-----------------------------------------------"
    echo "📤 UPLOADING TO PUBLIC REPO..."

    git config --global user.name "github-actions[bot]"
    git config --global user.email "github-actions[bot]@users.noreply.github.com"

    # Detect branch
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    echo "🌿 Detected branch: $CURRENT_BRANCH"

    # Cleanup old videos in output folder
    find "$OUTPUT_DIR" -type f ! -name "$url_filename" -delete
    
    # This automatically adds the new output video AND the updated played_lyrics.txt
    git add .
    git add "$out_file"

    RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${CURRENT_BRANCH}/output/${url_filename}"

    if [ -n "$GITHUB_ACTIONS" ]; then
        echo "⚙️ Force pushing to $CURRENT_BRANCH..."
        git commit -m "Refresh Reel: $safe_name" || git commit --amend --no-edit
        git push origin "$CURRENT_BRANCH" --force
    fi

    # --- 6. WEBHOOK CALL ---
    if [ -n "$WEBHOOK_URL" ]; then
        echo "📡 Sending Webhook..."
        PAYLOAD=$(cat <<EOF
{
  "fileUrl": "$RAW_URL",
  "fileName": "$safe_name"
}
EOF
)
        curl -L -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL"
        echo -e "\n✨ Process Complete."
    fi
    echo "-----------------------------------------------"
else
    echo "❌ Error: Final video file was not created."
    exit 1
fi
