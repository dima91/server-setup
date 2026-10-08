#!/bin/bash

SWAP_SIZE="$(free -m | grep Mem: | awk '{print $2}')M"
SWAP_FILE="/swapfile"

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 
   exit 1
fi

echo "Creating ${SWAP_SIZE} swap file at ${SWAP_FILE}..."

# Create the swap file
fallocate -l ${SWAP_SIZE} ${SWAP_FILE} || dd if=/dev/zero of=${SWAP_FILE} bs=1M count=4096
# Secure permissions
chmod 600 ${SWAP_FILE}
# Setup swap area
mkswap ${SWAP_FILE}
# Enable swap
swapon ${SWAP_FILE}
# Make it permanent (if not already in fstab)
if ! grep -q "${SWAP_FILE}" /etc/fstab; then
    echo "${SWAP_FILE} swap swap defaults 0 0" >> /etc/fstab
    echo "Added to /etc/fstab"
else
    echo "Already in /etc/fstab"
fi

echo "Swap setup complete. Current swap status:"
swapon --show
free -h

