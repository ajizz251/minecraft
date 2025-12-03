#!/bin/bash

# Pastikan BASE_DIR terdefinisi (jika script ini dijalankan terpisah/source)
if [[ -z "${BASE_DIR:-}" ]]; then
    # Deteksi folder parent dari folder 'functions'
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

TELEGRAM_CONF="$BASE_DIR/telegram.conf"
BOT_LOG_FILE="$BASE_DIR/logs/bot.log"
LISTENER_SCRIPT="$BASE_DIR/bot_listener.sh"
LISTENER_SESSION_NAME="BotListener"

function setupBotApi() {
    clear
    echo -e "${BLUE}--- Setup Konfigurasi Bot Telegram ---${NC}"
    
    # Load config lama jika ada
    if [ -f "$TELEGRAM_CONF" ]; then
        source "$TELEGRAM_CONF"
    fi

    echo -e "Lokasi Config: ${YELLOW}$TELEGRAM_CONF${NC}"
    
    # Tampilkan nilai lama jika ada
    local current_token="${BOT_TOKEN:-Belum diset}"
    local current_chatid="${CHAT_ID:-Belum diset}"

    echo -e "Token saat ini   : $current_token"
    echo -e "Chat ID saat ini : $current_chatid"
    echo ""

    read -p "Masukkan BOT TOKEN baru (kosongkan untuk tetap): " bot_token
    read -p "Masukkan CHAT ID Admin baru (kosongkan untuk tetap): " chat_id

    # Gunakan nilai lama jika input kosong
    [ -z "$bot_token" ] && bot_token="${BOT_TOKEN:-}"
    [ -z "$chat_id" ] && chat_id="${CHAT_ID:-}"

    # Simpan ke file config
    echo "BOT_TOKEN=\"$bot_token\"" > "$TELEGRAM_CONF"
    echo "CHAT_ID=\"$chat_id\"" >> "$TELEGRAM_CONF"
    
    chmod 600 "$TELEGRAM_CONF" # Amankan file config agar hanya user ini yang bisa baca
    
    echo -e "\n${GREEN}✅ Konfigurasi berhasil disimpan!${NC}"
    read -p "Tekan [Enter] untuk kembali."
}

function sendTestMessage() {
    if [ ! -f "$TELEGRAM_CONF" ]; then 
        echo -e "${RED}Konfigurasi bot belum diatur.${NC}"
        sleep 2
        return
    fi
    
    source "$TELEGRAM_CONF"
    
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        echo -e "${RED}Token atau Chat ID belum lengkap.${NC}"
        sleep 2
        return
    fi

    echo "Mengirim pesan tes ke $CHAT_ID..."
    local result
    result=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="✅ Pesan tes dari panel VPS ($USER). Konfigurasi berhasil!")
    
    if [[ "$result" == *"\"ok\":true"* ]]; then
        echo -e "${GREEN}Pesan terkirim berhasil.${NC}"
    else
        echo -e "${RED}Gagal mengirim pesan. Respon API:${NC}"
        echo "$result"
    fi
    sleep 3
}

function onOffBotMenu() {
    while true; do
        clear
        echo -e "${BLUE}--- Status Bot Listener ---${NC}"
        
        # Cek session tmux
        if tmux has-session -t "$LISTENER_SESSION_NAME" 2>/dev/null; then
            echo -e "Status: ${GREEN}AKTIF (Berjalan di latar belakang)${NC}"
            echo "PID Session: $(tmux list-sessions | grep $LISTENER_SESSION_NAME | awk '{print $1}' | tr -d ':')"
            echo "--------------------------------"
            echo "1. Matikan Bot Listener"
            echo "0. Kembali"
            read -p "Pilihan: " choice
            if [ "$choice" == "1" ]; then 
                echo -e "${YELLOW}Mematikan listener...${NC}"
                tmux kill-session -t "$LISTENER_SESSION_NAME"
                sleep 1
            elif [ "$choice" == "0" ]; then 
                return
            fi
        else
            echo -e "Status: ${RED}TIDAK AKTIF${NC}"
            echo "--------------------------------"
            echo "1. Aktifkan Bot Listener"
            echo "0. Kembali"
            read -p "Pilihan: " choice
            if [ "$choice" == "1" ]; then
                if [ ! -f "$TELEGRAM_CONF" ]; then 
                    echo -e "${RED}Konfigurasi bot belum diatur. Jalankan setup dulu.${NC}"
                    sleep 2
                    continue
                fi
                
                if [ ! -f "$LISTENER_SCRIPT" ]; then
                    echo -e "${RED}Script bot_listener.sh tidak ditemukan di:${NC}"
                    echo "$LISTENER_SCRIPT"
                    sleep 3
                    return
                fi
                
                chmod +x "$LISTENER_SCRIPT"
                echo -e "${YELLOW}Mengaktifkan listener...${NC}"
                # Jalankan bot_listener.sh menggunakan tmux dengan path yang benar
                tmux new-session -d -s "$LISTENER_SESSION_NAME" "bash '$LISTENER_SCRIPT'"
                sleep 1
                
                if tmux has-session -t "$LISTENER_SESSION_NAME" 2>/dev/null; then
                     echo -e "${GREEN}Bot Listener berhasil dimulai.${NC}"
                else
                     echo -e "${RED}Gagal memulai tmux session. Cek log bot.${NC}"
                fi
                sleep 2
            elif [ "$choice" == "0" ]; then 
                return
            fi
        fi
    done
}

function botMenu() {
    while true; do
        clear
        echo -e "${BLUE}======= MENU BOT TELEGRAM =======${NC}"
        echo "1. Setup Bot API"
        echo "2. Aktifkan / Matikan Bot Listener"
        echo "3. Lihat Log Bot"
        echo "4. Kirim Pesan Tes"
        echo "0. Kembali ke Menu Utama"
        echo "---------------------------------"
        read -p "Pilihan: " choice
        case $choice in
            1) setupBotApi ;; 
            2) onOffBotMenu ;;
            3) 
               clear
               echo -e "${YELLOW}Menampilkan log bot ($BOT_LOG_FILE)...${NC}"
               echo -e "Tekan ${RED}CTRL+C${NC} untuk keluar dari log."
               echo ""
               if [ ! -f "$BOT_LOG_FILE" ]; then 
                   echo "File log belum ada (bot belum pernah dijalankan)."
               else
                   tail -f "$BOT_LOG_FILE"
               fi
               read -p "Tekan [Enter] untuk kembali."; ;;
            4) sendTestMessage ;; 
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}
