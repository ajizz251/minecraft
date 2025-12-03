#!/bin/bash

# --- KONFIGURASI PATH DINAMIS ---
# Menggunakan BASH_SOURCE agar aman saat di-source oleh script lain
# Ini mendeteksi lokasi file config.sh ini berada.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mendefinisikan sub-direktori penting
# Menggunakan syntax :- untuk fallback jika variabel sudah diset sebelumnya
SERVERS_DIR="${SERVERS_DIR:-$BASE_DIR/servers}"
EGGS_DIR="${EGGS_DIR:-$BASE_DIR/eggs}"
FUNCTIONS_DIR="${FUNCTIONS_DIR:-$BASE_DIR/functions}"

# --- KONFIGURASI WARNA ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color
