#!/bin/bash

# ==============================================================================
#   BOT LISTENER SERVICE (Non-Root Compatible)
# ==============================================================================

# --- Deteksi Direktori Panel Secara Dinamis ---
# Menggunakan lokasi script ini sebagai patokan BASE_DIR
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR" || { echo "Gagal masuk ke direktori $BASE_DIR"; exit 1; }

# --- Konfigurasi Log ---
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/bot.log"
mkdir -p "$LOG_DIR"

# Mengarahkan output (stdout & stderr) ke file log
exec &> "$LOG_FILE"

echo "=========================================="
echo "   Bot Listener Dinamis Dimulai pada $(date)"
echo "   Mode: Non-Root / Generic User"
echo "   Base Dir: $BASE_DIR"
echo "=========================================="

# --- Memuat Konfigurasi ---
CONFIG_FILE="$BASE_DIR/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] File konfigurasi utama ($CONFIG_FILE) tidak ditemukan. Keluar."
    exit 1
fi
source "$CONFIG_FILE"

# Memastikan variabel penting terisi (fallback jika config.sh kosong/gagal)
SERVERS_DIR="${SERVERS_DIR:-$BASE_DIR/servers}"

TELEGRAM_CONF="$BASE_DIR/telegram.conf"
if [ -f "$TELEGRAM_CONF" ]; then
    source "$TELEGRAM_CONF"
fi

if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then 
    echo "[ERROR] Konfigurasi bot tidak lengkap (TOKEN atau CHAT_ID kosong)."
    echo "Silakan jalankan menu 'Setup Bot API' di panel terlebih dahulu."
    exit 1
fi

STATE_FILE="/tmp/bot_plugin_state_$USER.json"
echo "{}" > "$STATE_FILE"

# --- FUNGSI-FUNGSI BOT ---

sendMessage() {
    local target_chat_id="$1"
    local text="$2"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$target_chat_id" \
        -d text="$text" > /dev/null
}

sendServerList() {
    local target_chat_id="$1"
    local keyboard_json="{\"inline_keyboard\":["
    
    # Mengambil daftar folder di dalam SERVERS_DIR
    shopt -s nullglob
    local servers=("$SERVERS_DIR"/*/)
    shopt -u nullglob

    if [ ${#servers[@]} -eq 0 ]; then
        sendMessage "$target_chat_id" "⚠️ Tidak ada server yang ditemukan di folder '$SERVERS_DIR'."
        return
    fi
    
    for server_path in "${servers[@]}"; do
        # Hapus trailing slash
        server_path=${server_path%/}
        local server_name
        server_name=$(basename "$server_path")
        
        # Tambahkan tombol untuk server ini
        keyboard_json+="[{\"text\":\"$server_name\",\"callback_data\":\"select_server_$server_name\"}],"
    done
    
    # Menghapus koma terakhir dan menutup JSON
    keyboard_json=${keyboard_json%?} 
    keyboard_json+="]}"

    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
         -d chat_id="$target_chat_id" \
         -d text="📂 Silakan pilih server tujuan untuk upload plugin:" \
         -d reply_markup="$keyboard_json" > /dev/null
}

# --- LOGIKA UTAMA LISTENER ---
echo "[INFO] Membersihkan antrian pesan lama..."
initial_updates=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?timeout=1")

# Menggunakan jq untuk parsing JSON dengan aman
last_update_id=$(echo "$initial_updates" | jq -r ".result[-1].update_id // 0")
if [ "$last_update_id" -ne 0 ]; then 
    last_update_id=$((last_update_id + 1))
fi

echo "[INFO] Listener aktif dan siap menerima perintah..."

while true; do
    # Long polling (timeout 30 detik) untuk efisiensi resource
    updates=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$last_update_id&timeout=30")
    
    # Jika curl gagal atau kosong, tunggu sebentar sebelum retry
    if [ -z "$updates" ]; then
        sleep 5
        continue
    fi

    # Loop setiap update yang masuk
    for row in $(echo "${updates}" | jq -r '.result[] | @base64'); do
        _jq() { 
            echo "${row}" | base64 --decode | jq -r "${1}"
        }

        update_type="message"
        callback_id=$(_jq '.callback_query.id')
        if [ "$callback_id" != "null" ] && [ -n "$callback_id" ]; then
            update_type="callback_query"
        fi

        current_chat_id=""
        if [ "$update_type" == "message" ]; then
            current_chat_id=$(_jq '.message.chat.id')
        else
            current_chat_id=$(_jq '.callback_query.message.chat.id')
        fi
        
        # Keamanan: Hanya merespon CHAT_ID milik Admin
        # Konversi ke string untuk perbandingan yang aman
        if [ "$current_chat_id" == "$CHAT_ID" ]; then
            
            # 1. Handle Command /add
            if [ "$update_type" == "message" ] && [ "$(_jq '.message.text')" == "/add" ]; then
                echo "[INFO] Perintah /add diterima. Mengirim daftar server..."
                sendServerList "$current_chat_id"

            # 2. Handle Callback (Pilih Server)
            elif [ "$update_type" == "callback_query" ]; then
                data=$(_jq '.callback_query.data')
                if [[ "$data" == "select_server_"* ]]; then
                    selected_server=${data#select_server_} # String manipulation bash murni
                    echo "[INFO] Server '$selected_server' dipilih."
                    
                    # Simpan state pilihan user ke file sementara
                    # Kita baca file dulu, update, lalu simpan balik
                    if [ -f "$STATE_FILE" ]; then
                        tmp_json=$(cat "$STATE_FILE")
                    else
                        tmp_json="{}"
                    fi
                    
                    # Update JSON state
                    echo "$tmp_json" | jq ".[\"$current_chat_id\"] = \"$selected_server\"" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
                    
                    sendMessage "$current_chat_id" "✅ Server terpilih: '$selected_server'.\nSilakan kirim file plugin (.jar) sekarang."
                    
                    # Acknowledge callback agar loading di Telegram berhenti
                    query_id=$(_jq '.callback_query.id')
                    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" -d callback_query_id="$query_id" > /dev/null
                fi

            # 3. Handle File Upload (.jar)
            elif [ "$update_type" == "message" ]; then
                is_jar=$(_jq '.message.document.file_name | endswith(".jar")')
                
                if [ "$is_jar" == "true" ]; then
                    # Cek apakah user sudah memilih server sebelumnya
                    target_server=$(jq -r ".[\"$current_chat_id\"] // empty" "$STATE_FILE")
                    
                    if [ -n "$target_server" ] && [ "$target_server" != "null" ]; then
                        file_id=$(_jq '.message.document.file_id')
                        file_name=$(_jq '.message.document.file_name')
                        echo "[INFO] Menerima file '$file_name' untuk server '$target_server'."
                        
                        plugins_dir="$SERVERS_DIR/$target_server/plugins"
                        
                        # Cek apakah folder server valid
                        if [ ! -d "$SERVERS_DIR/$target_server" ]; then
                             sendMessage "$current_chat_id" "❌ Error: Server '$target_server' tidak ditemukan di penyimpanan."
                        else
                            mkdir -p "$plugins_dir"
                            
                            # Dapatkan Path File dari Telegram API
                            file_info=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getFile?file_id=$file_id")
                            file_path=$(echo "$file_info" | jq -r ".result.file_path")

                            if [ -n "$file_path" ] && [ "$file_path" != "null" ]; then
                                echo "[INFO] Mengunduh..."
                                wget -q -O "$plugins_dir/$file_name" "https://api.telegram.org/file/bot$BOT_TOKEN/$file_path"
                                
                                if [ $? -eq 0 ]; then
                                    sendMessage "$current_chat_id" "✅ Plugin '$file_name' berhasil diinstal ke server '$target_server'."
                                else
                                    sendMessage "$current_chat_id" "❌ Gagal mengunduh file."
                                fi
                            else
                                sendMessage "$current_chat_id" "❌ Gagal mendapatkan info file dari Telegram."
                            fi
                        fi
                        
                        # Reset pilihan server setelah upload
                        jq "del(.[\"$current_chat_id\"])" "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
                    else
                        sendMessage "$current_chat_id" "⚠️ Silakan ketik /add dan pilih server terlebih dahulu sebelum mengirim file."
                    fi
                fi
            fi
        fi
    done

    # Update offset untuk polling berikutnya
    last_update_id=$(echo "$updates" | jq -r ".result[-1].update_id // $last_update_id")
    if [ "$last_update_id" -ne 0 ]; then 
        last_update_id=$((last_update_id + 1))
    fi
    
    sleep 1
done
