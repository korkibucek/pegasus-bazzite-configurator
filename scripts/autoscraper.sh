#!/bin/bash
# Pegasus Auto-Scraper for Bazzite (Using Podman & Local Build)

echo "========================================"
echo "   Pegasus Auto-Scraper for Bazzite     "
echo "========================================"

# Create the cache directory so it inherits proper user permissions
mkdir -p "$HOME/.skyscraper"

# First time setup: Build the image locally if it doesn't exist
if ! podman image exists localhost/bazzite-skyscraper; then
    echo ""
    echo "First time setup detected!"
    echo "The pre-built remote image is offline, so we will build our own."
    echo "Building a local Skyscraper container. This will take a few minutes but only happens once..."
    
    # Create a temporary Dockerfile
    cat << 'EOF' > /tmp/Dockerfile.skyscraper
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y build-essential qtbase5-dev qt5-qmake git wget && \
    git clone https://github.com/gemba/skyscraper.git /usr/src/skyscraper && \
    cd /usr/src/skyscraper && \
    qmake && \
    make -j$(nproc) && \
    make install && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /usr/src/skyscraper
ENTRYPOINT ["Skyscraper"]
EOF

    # Build the image safely on the host
    podman build -t localhost/bazzite-skyscraper -f /tmp/Dockerfile.skyscraper /tmp
    rm -f /tmp/Dockerfile.skyscraper
    
    echo "Container build complete!"
    echo "========================================"
fi

DEFAULT_ROMS="/home/hugo/ROMs"

read -p "Enter your ROMs path [Default: $DEFAULT_ROMS]: " ROM_DIR
ROM_DIR=${ROM_DIR:-$DEFAULT_ROMS}

if [ ! -d "$ROM_DIR" ]; then
    echo "Error: Could not find ROM directory at $ROM_DIR"
    exit 1
fi

read -p "Enter the system folder to scrape (e.g., snes), or type 'all' to scrape everything: " SYSTEM

if [ -z "$SYSTEM" ]; then
    echo "Error: System cannot be empty."
    exit 1
fi

echo ""
echo "ScreenScraper.fr often blocks anonymous scraping during peak hours."
read -p "ScreenScraper Username (Leave blank to try anonymously): " SS_USER
read -s -p "ScreenScraper Password (Leave blank if anonymous): " SS_PASS
echo ""

# Safely handle authentication arguments
AUTH_ARGS=()
if [ -n "$SS_USER" ] && [ -n "$SS_PASS" ]; then
    AUTH_ARGS=("-u" "$SS_USER:$SS_PASS")
fi

# Build the list of systems to scrape
SYSTEMS=()
if [ "$SYSTEM" = "all" ] || [ "$SYSTEM" = "ALL" ]; then
    echo ""
    echo "Detected 'all'. Generating a list of systems from $ROM_DIR..."
    
    # Loop through every folder in the ROM directory
    for dir in "$ROM_DIR"/*/; do
        [ -d "$dir" ] || continue
        SYS_NAME=$(basename "$dir")
        SYSTEMS+=("$SYS_NAME")
    done
else
    SYSTEMS=("$SYSTEM")
fi

echo ""
echo "Starting the Skyscraper container..."

# Loop through each system and scrape
for SYS in "${SYSTEMS[@]}"; do
    echo ""
    echo "========================================"
    echo " Processing: $SYS "
    echo "========================================"

    # Step 1: Gather the artwork and metadata from ScreenScraper
    podman run --rm -it \
      -v "$ROM_DIR:/roms:Z" \
      -v "$HOME/.skyscraper:/root/.skyscraper:Z" \
      localhost/bazzite-skyscraper \
      -p "$SYS" -s screenscraper -i "/roms/$SYS" "${AUTH_ARGS[@]}"

    # Step 2: Generate the metadata.pegasus.txt file
    podman run --rm -it \
      -v "$ROM_DIR:/roms:Z" \
      -v "$HOME/.skyscraper:/root/.skyscraper:Z" \
      localhost/bazzite-skyscraper \
      -p "$SYS" -f pegasus -i "/roms/$SYS" -g "/roms/$SYS"
done

echo ""
echo "========================================"
echo " Success! Scraping operations complete."
echo " Launch Pegasus to view your updated library."
echo "========================================"
