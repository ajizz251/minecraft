#!/bin/bash

# --- Deteksi Path Dinamis ---
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SELF_DIR/.." && pwd)"
SERVERS_DIR="${SERVERS_DIR:-$BASE_DIR/servers}"

# Folder sementara untuk backup lokal sebelum diunggah
LOCAL_BACKUP_TEMP_DIR="/tmp/mc_panel_mega_backups"

# Fungsi untuk memastikan pengguna sudah login ke Mega
function ensureMegaLogin() {
    local MEGA_CMD_BIN="$(command -v mega-cmd)"
    if [ -z "$MEGA_CMD_BIN" ]; then
        # Jika tidak ditemukan di PATH, coba jalur snap default
        MEGA_CMD_BIN="/snap/bin/mega-cmd"
        if [ ! -x "$MEGA_CMD_BIN" ]; then
            echo -e "${RED}ERROR: mega-cmd tidak ditemukan di PATH maupun di /snap/bin/.${NC}"
            return 1
        fi
    fi

    # Cek login dengan whoami
    local whoami_output; whoami_output="$("$MEGA_CMD_BIN" whoami 2>&1)"
    local whoami_exit_code=$?

    if [ "$whoami_exit_code" -eq 0 ] && [[ "$whoami_output" == *"@"* ]]; then
        # Sudah login
        return 0 
    else
        clear
        echo -e "${YELLOW}Anda belum login ke akun MEGA Anda.${NC}"
        echo "Harap login sekarang untuk menggunakan fitur backup/restore MEGA."
        echo
        read -rp "Masukkan Email MEGA Anda: " mega_email
        read -rsp "Masukkan Password MEGA Anda: " mega_password
        echo

        if [ -z "$mega_email" ] || [ -z "$mega_password" ]; then
            echo -e "${RED}Email dan Password tidak boleh kosong. Login dibatalkan.${NC}"
            sleep 2
            return 1
        fi

        echo -e "${BLUE}Mencoba login ke MEGA...${NC}"
        if "$MEGA_CMD_BIN" login "$mega_email" "$mega_password"; then
            echo -e "${GREEN}✅ Login MEGA berhasil!${NC}"
            sleep 2
            return 0
        else
            echo -e "${RED}Login MEGA gagal. Periksa kembali kredensial Anda.${NC}"
            sleep 2
            return 1
        fi
    fi
}

# Fungsi untuk membuat backup dan mengunggahnya ke Mega
function runBackupToMega() {
    clear
    echo -e "${BLUE}--- Backup Server ke MEGA Cloud Storage ---${NC}"

    # Pastikan MEGAcmd terinstal
    if ! command -v mega-cmd &> /dev/null; then
        echo -e "${RED}ERROR: MEGAcmd tidak ditemukan. Harap instal MEGAcmd terlebih dahulu.${NC}"
        read -p "Tekan [Enter] untuk kembali."
        return
    fi

    # Pastikan pengguna sudah login ke Mega
    if ! ensureMegaLogin; then
        echo -e "${RED}Login MEGA gagal atau dibatalkan. Backup tidak dapat dilanjutkan.${NC}"
        read -p "Tekan [Enter] untuk kembali."
        return
    fi

    mapfile -t servers < <(find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d)
    if [ ${#servers[@]} -eq 0 ]; then echo -e "${YELLOW}Belum ada server untuk dibackup.${NC}\n"; read -p "Tekan [Enter] untuk kembali."; return; fi

    echo -e "${BLUE}Pilih Server untuk di-Backup:${NC}"; i=1
    for server_path in "${servers[@]}"; do echo "$i. $(basename "$server_path")"; i=$((i+1)); done
    read -p "Masukkan nomor server [1-${#servers[@]}] (atau 0 untuk kembali): " server_choice

    if ! [[ "$server_choice" =~ ^[0-9]+$ ]] || [ "$server_choice" -lt 0 ] || [ "$server_choice" -gt ${#servers[@]} ]; then echo -e "${RED}Pilihan tidak valid.${NC}"; sleep 2; return; fi
    if [ "$server_choice" -eq 0 ]; then return; fi

    local server_path="${servers[$server_choice-1]}"
    local server_name; server_name=$(basename "$server_path")
    
    read -p "Lanjutkan backup untuk '$server_name' ke MEGA? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then echo "Dibatalkan."; sleep 2; return; fi

    clear
    echo -e "${BLUE}Memulai proses backup untuk: ${YELLOW}$server_name${NC}"

    mkdir -p "$LOCAL_BACKUP_TEMP_DIR"
    local backup_file="backup-${server_name}-$(date +%F-%H%M).tar.gz"
    local temp_archive_path="$LOCAL_BACKUP_TEMP_DIR/$backup_file"

    echo "-> Mengarsipkan data server ke $temp_archive_path..."
    # Tar akan dijalankan sebagai user saat ini, pastikan user punya akses baca ke SERVERS_DIR
    tar -czf "$temp_archive_path" -C "$SERVERS_DIR" "$server_name"
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Gagal membuat arsip backup. Periksa izin file.${NC}"
        rm -f "$temp_archive_path"
        read -p "Tekan [Enter] untuk kembali."
        return
    fi

    echo "-> Mengunggah backup ke MEGA..."
    # Buat folder di MEGA jika belum ada
    mega-mkdir -p /Root/mc-panel-backups &> /dev/null
    if mega-put "$temp_archive_path" "/Root/mc-panel-backups/$backup_file"; then
        echo -e "${GREEN}✅ Backup berhasil diunggah ke MEGA!${NC}"
        echo -e "\nFile tersedia di MEGA Anda: ${GREEN}/Root/mc-panel-backups/$backup_file${NC}\n"
    else
        echo -e "${RED}Gagal mengunggah backup ke MEGA.${NC}"
    fi

    echo "-> Membersihkan file lokal sementara..."
    rm -f "$temp_archive_path"
    read -p "Tekan [Enter] untuk kembali."
}

# Fungsi untuk restore server dari Mega
function runRestoreFromMega() {
    clear
    echo -e "${BLUE}--- Restore Server dari MEGA Cloud Storage ---${NC}"

    if ! command -v mega-cmd &> /dev/null; then
        echo -e "${RED}ERROR: MEGAcmd tidak ditemukan.${NC}"
        read -p "Tekan [Enter] untuk kembali."
        return
    fi

    if ! ensureMegaLogin; then return; fi

    echo "Masukkan path file backup di MEGA atau Direct Link Publik."
    echo
    read -p "Masukkan path/link backup: " restore_source

    if [ -z "$restore_source" ]; then
        echo "Dibatalkan."
        sleep 2; return
    fi

    local temp_download_path="/tmp/mega_restore_download.tar.gz"
    echo -e "\n${YELLOW}Mencoba mengunduh...${NC}"

    if [[ "$restore_source" == /Root/* ]] || [[ "$restore_source" == /* ]]; then
        if mega-get "$restore_source" "$temp_download_path"; then
            echo -e "${GREEN}✅ Download dari MEGA berhasil.${NC}"
        else
            echo -e "${RED}GAGAL: Cek path MEGA Anda.${NC}"
            rm -f "$temp_download_path"
            read -p "Tekan [Enter]..."
            return
        fi
    else
        if wget -O "$temp_download_path" "$restore_source"; then
            echo -e "${GREEN}✅ Download dari URL berhasil.${NC}"
        else
            echo -e "${RED}GAGAL: Cek URL Anda.${NC}"
            rm -f "$temp_download_path"
            read -p "Tekan [Enter]..."
            return
        fi
    fi

    if [ -f "$temp_download_path" ]; then
        echo -e "\n${YELLOW}PERINGATAN: Data akan diekstrak ke $SERVERS_DIR.${NC}"
        read -p "Lanjutkan? (y/n): " confirm_extract

        if [[ "$confirm_extract" == "y" ]]; then
            echo "-> Mengekstrak..."
            mkdir -p "$SERVERS_DIR"
            tar -xzf "$temp_download_path" -C "$SERVERS_DIR/"
            if [ $? -eq 0 ]; then
                echo -e "\n${GREEN}✅ Restore selesai!${NC}"
            else
                echo -e "${RED}ERROR: Gagal mengekstrak. Cek izin folder servers/.${NC}"
            fi
        else
            echo "Dibatalkan."
        fi
        rm -f "$temp_download_path"
    fi

    read -p "Tekan [Enter] untuk kembali."
}

# Fungsi migrasi server ke VPS lain via rsync
function runMigrateViaRsync() {
    clear
    echo -e "${BLUE}--- Migrasi Server ke VPS Lain (via rsync SSH) ---${NC}"

    mapfile -t servers < <(find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d)
    if [ ${#servers[@]} -eq 0 ]; then echo -e "${YELLOW}Belum ada server yang bisa dimigrasi.${NC}\n"; read -p "Tekan [Enter] untuk kembali."; return; fi

    echo -e "${BLUE}Pilih Server yang ingin di-migrate:${NC}"; i=1
    for server_path in "${servers[@]}"; do echo "$i. $(basename "$server_path")"; i=$((i+1)); done
    read -p "Masukkan nomor server [1-${#servers[@]}] (atau 0 untuk batal): " server_choice

    if ! [[ "$server_choice" =~ ^[0-9]+$ ]] || [ "$server_choice" -lt 0 ] || [ "$server_choice" -gt ${#servers[@]} ]; then echo -e "${RED}Pilihan tidak valid.${NC}"; sleep 2; return; fi
    if [ "$server_choice" -eq 0 ]; then return; fi

    local server_name; server_name=$(basename "${servers[$server_choice-1]}")

    # Default values disesuaikan untuk non-root friendly
    read -p "Masukkan user VPS tujuan      [default: $USER]: " vps_user
    vps_user=${vps_user:-$USER}
    
    read -p "Masukkan IP VPS tujuan        : " vps_ip
    if [ -z "$vps_ip" ]; then echo -e "${RED}IP tidak boleh kosong!${NC}"; sleep 2; return; fi
    
    read -p "Masukkan port SSH [default: 22]: " vps_port
    vps_port=${vps_port:-22}
    
    read -p "Masukkan path folder panel di VPS tujuan [default: ~/mc-panel]: " vps_panel_dir
    vps_panel_dir=${vps_panel_dir:-~/mc-panel}

    echo -e "${BLUE}Mengirim folder server menggunakan rsync...${NC}"
    echo "Pastikan user '$vps_user' di '$vps_ip' memiliki akses tulis ke '$vps_panel_dir/servers'."
    
    # Menjalankan rsync
    rsync -avz --progress -e "ssh -p $vps_port" "$SERVERS_DIR/$server_name/" "$vps_user@$vps_ip:$vps_panel_dir/servers/$server_name/"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Migrasi selesai!${NC}"
    else
        echo -e "${RED}Gagal melakukan migrasi. Pastikan SSH key sudah di-copy atau password benar.${NC}"
    fi
    read -p "Tekan [Enter] untuk kembali."
}

# Menu utama backup
function backupMenu() {
    while true; do
        clear
        echo -e "${BLUE}--- Manajemen Backup & Migrasi Server ---${NC}"
        echo "1. Backup ke MEGA Cloud Storage"
        echo "2. Restore dari MEGA Cloud Storage"
        echo "3. Transfer Data Server Via SSH (rsync)"
        echo "0. Kembali ke Menu Utama"
        echo "-----------------------------------------------------"
        read -p "Masukkan pilihan: " choice
        case $choice in
            1) runBackupToMega ;; 
            2) runRestoreFromMega ;; 
            3) runMigrateViaRsync ;; 
            0) return ;; 
            *) echo -e "${RED}Pilihan tidak valid.${NC}"; sleep 1 ;; 
        esac
    done
}
