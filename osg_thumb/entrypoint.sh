#!/bin/bash
set -e

# Start Xvfb virtual frame buffer directly in the background on display :99
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!

# Export DISPLAY variable so OSG connects directly to :99
export DISPLAY=:99

# Wait a brief moment for Xvfb socket to initialize
sleep 1

# Execute the osgthumb binary passing all arguments
osgthumb "$@"

# Clean up Xvfb background process on exit
kill $XVFB_PID 2>/dev/null || true