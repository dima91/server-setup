#!/bin/bash

# Dimensione in MB: quanta RAM ha la macchina (usata sia da fallocate che dal fallback dd)
SWAP_MB="$(free -m | grep Mem: | awk '{print $2}')"
SWAP_FILE="/swapfile"

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)"
   exit 1
fi

if [[ ! "$SWAP_MB" =~ ^[0-9]+$ ]] || [[ "$SWAP_MB" -eq 0 ]]; then
    echo "Cannot read the amount of RAM from 'free -m' (got '${SWAP_MB}')" >&2
    exit 1
fi

# Already active (script launched twice): fallocate and dd would fail with "Text file busy"
if swapon --show=NAME --noheadings | grep -qx "${SWAP_FILE}"; then
    echo "Swap already active on ${SWAP_FILE}: nothing to do."
    swapon --show
    exit 0
fi

echo "Creating ${SWAP_MB}M swap file at ${SWAP_FILE}..."

# Leftover of a previous failed attempt (not active, see above): start over
rm -f "${SWAP_FILE}"

# Create the swap file (dd fallback writes the same size as fallocate)
if ! { fallocate -l "${SWAP_MB}M" "${SWAP_FILE}" || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${SWAP_MB}"; }; then
    echo "Cannot allocate ${SWAP_MB}M for ${SWAP_FILE} (disk full?)" >&2
    rm -f "${SWAP_FILE}"
    exit 1
fi
# Secure permissions
chmod 600 "${SWAP_FILE}"
# Setup swap area
if ! mkswap "${SWAP_FILE}"; then
    echo "mkswap failed on ${SWAP_FILE}" >&2
    rm -f "${SWAP_FILE}"
    exit 1
fi
# Enable swap
if ! swapon "${SWAP_FILE}"; then
    echo "swapon failed on ${SWAP_FILE}" >&2
    exit 1
fi
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

