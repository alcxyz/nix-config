#!/usr/bin/env bash

# Start looking-glass-client in the background
exec looking-glass-client >/dev/null 2>&1 &

# Save the PID of the background process
echo $! >~/looking-glass-client.pid
