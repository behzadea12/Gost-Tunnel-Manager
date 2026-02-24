#!/bin/bash

# ==============================================================================
# Project: Gost-Manager
# Description: Advanced encrypted tunnel management with anti-DPI capabilities
# Version: 1.3.0
# GitHub: https://github.com/behzadea12/Gost-Tunnel-Manager
# ==============================================================================

# ==============================================================================
# 1. CONFIGURATION DEFAULTS
# ==============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly ORANGE='\033[0;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="1.3.0"
readonly MANAGER_NAME="gost-manager"
readonly MANAGER_PATH="/usr/local/bin/$MANAGER_NAME"

readonly CONFIG_DIR="/etc/gost"
readonly SERVICE_DIR="/etc/systemd/system"
readonly BIN_DIR="/usr/local/bin"
readonly LOG_DIR="/var/log/gost"
readonly TLS_DIR="${CONFIG_DIR}/tls"
readonly BACKUP_DIR="/root/gost-backups"
readonly WATCHDOG_PATH="${BIN_DIR}/gost-watchdog"
readonly BIN_PATH="${BIN_DIR}/gost"

# IP detection services
readonly IP_SERVICES=(
    "ifconfig.me"
    "icanhazip.com"
    "api.ipify.org"
    "checkip.amazonaws.com"
    "ipinfo.io/ip"
)

# ==============================================================================
# 2. UTILITY FUNCTIONS
# ==============================================================================

print_step() { echo -e "${BLUE}[•]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }

# Special input function that keeps cursor on same line
prompt_input() {
    echo -ne "${YELLOW}[•]${NC} $1 "
}

pause() {
    echo ""
    read -p "$(echo -e "${YELLOW}Press Enter to continue...${NC}")" </dev/tty
}

show_banner() {
    clear
    echo -e "${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║      ██████╗  ██████╗ ███████╗████████╗                      ║"
    echo "║     ██╔════╝ ██╔═══██╗██╔════╝╚══██╔══╝                      ║"
    echo "║     ██║  ███╗██║   ██║███████╗   ██║                         ║"
    echo "║     ██║   ██║██║   ██║╚════██║   ██║                         ║"
    echo "║     ╚██████╔╝╚██████╔╝███████║   ██║                         ║"
    echo "║      ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝                         ║"
    echo "║                                                              ║"
    echo "║           Encrypted Tunnel Manager - Anti-DPI                ║"
    echo "║                      Version ${SCRIPT_VERSION}                           ║"
    echo "║                                                              ║"
    echo "║          https://t.me/behzad_developer                       ║"
    echo "║          https://t.me/BehzadEa12                             ║"
    echo "║          https://github.com/behzadea12                       ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "linux"
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) 
            print_warning "Unknown architecture: $arch, assuming amd64"
            echo "amd64" 
            ;;
    esac
}

get_public_ip() {
    for service in "${IP_SERVICES[@]}"; do
        local ip=$(curl -4 -s --max-time 2 "$service" 2>/dev/null)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "Unknown"
}

validate_ip() {
    local ip=$1
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

clean_port_list() {
    local ports="$1"
    ports=$(echo "$ports" | tr -d ' ')
    local cleaned=""
    
    IFS=',' read -ra port_array <<< "$ports"
    for port in "${port_array[@]}"; do
        if validate_port "$port"; then
            cleaned="${cleaned:+$cleaned,}$port"
        else
            print_warning "Invalid port '$port' ignored" >&2
        fi
    done
    echo "$cleaned"
}

check_crontab() {
    if ! command -v crontab &>/dev/null; then
        print_warning "crontab not found, watchdog disabled"
        return 1
    fi
    return 0
}

check_module() {
    local module=$1
    if ! lsmod | grep -q "^$module"; then
        print_warning "Kernel module $module not loaded"
        prompt_input "Load now? (y/N):"
        read -p "" choice </dev/tty
        echo ""
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            modprobe "$module" 2>/dev/null
            if [ $? -eq 0 ]; then
                print_success "Module $module loaded"
            else
                print_error "Failed to load $module"
                return 1
            fi
        else
            return 1
        fi
    fi
    return 0
}

# ==============================================================================
# 3. SYSTEM SETUP
# ==============================================================================

setup_environment() {
    print_step "Initializing environment..."
    
    local packages=("wget" "curl" "cron" "openssl" "nano" "jq")
    local missing=()
    
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y "${missing[@]}" -qq >/dev/null 2>&1
    fi
    
    mkdir -p "$LOG_DIR" "$TLS_DIR" "$BACKUP_DIR"
    print_success "Environment ready"
}

configure_firewall() {
    local port=$1
    if ! validate_port "$port"; then return 1; fi
    
    if command -v ufw &>/dev/null; then
        ufw allow "$port"/tcp &>/dev/null
        ufw allow "$port"/udp &>/dev/null
        print_success "Firewall rule added for port $port (UFW)"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
        print_success "Firewall rule added for port $port (iptables)"
    fi
}

configure_firewall_protocol() {
    local port=$1
    local protocol=$2
    if ! validate_port "$port"; then return 1; fi
    
    if command -v ufw &>/dev/null; then
        case $protocol in
            tcp) ufw allow "$port"/tcp &>/dev/null ;;
            udp) ufw allow "$port"/udp &>/dev/null ;;
            both) 
                ufw allow "$port"/tcp &>/dev/null
                ufw allow "$port"/udp &>/dev/null
                ;;
        esac
        print_success "Firewall rule added for port $port ($protocol) - UFW"
    elif command -v iptables &>/dev/null; then
        case $protocol in
            tcp) iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null ;;
            udp) iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null ;;
            both)
                iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
                iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
                ;;
        esac
        print_success "Firewall rule added for port $port ($protocol) - iptables"
    fi
}

# ==============================================================================
# 4. CORE INSTALLATION
# ==============================================================================

deploy_gost_binary() {
    if [[ -f "$BIN_PATH" ]]; then
        print_success "GOST binary already installed"
        return 0
    fi
    
    local arch=$(detect_arch)
    local version="v2.12.0"
    local base_url="https://github.com/ginuerzh/gost/releases/download/${version}"
    local filename="gost-linux-${arch}-${version}.gz"
    
    if [[ "$arch" == "arm64" ]]; then
        filename="gost-linux-armv8-${version}.gz"
    elif [[ "$arch" == "amd64" ]]; then
        filename="gost-linux-amd64-${version}.gz"
    fi
    
    print_step "Downloading GOST ${version} for ${arch}..."
    
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if wget -q --timeout=10 --tries=2 "${base_url}/${filename}" -O /tmp/gost.gz; then
            if [[ -s "/tmp/gost.gz" ]]; then
                gzip -d -f /tmp/gost.gz
                mv /tmp/gost "$BIN_PATH"
                chmod +x "$BIN_PATH"
                
                if [[ -x "$BIN_PATH" ]]; then
                    print_success "GOST installed successfully"
                    return 0
                fi
            fi
        fi
        print_warning "Attempt $attempt failed, retrying..."
        ((attempt++))
        sleep 2
    done
    
    print_error "Failed to download GOST after $max_attempts attempts"
    exit 1
}

# ==============================================================================
# 5. SECURITY COMPONENTS
# ==============================================================================

generate_tunnel_key() {
    openssl rand -hex 12
}

function generate_tls_certificate() {
    mkdir -p "$TLS_DIR"

    if [[ ! -f "$TLS_DIR/server.crt" ]]; then
        print_step "Generating stealth TLS certificate..."
        openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
            -subj "/C=US/ST=CA/L=Los Angeles/O=Speedtest Inc/CN=www.speedtest.net" \
            -keyout "$TLS_DIR/server.key" \
            -out "$TLS_DIR/server.crt" 2>/dev/null
    fi

    if [[ -f "$TLS_DIR/server.crt" && -f "$TLS_DIR/server.key" ]]; then
        print_success "Stealth TLS certificate created (with SAN) for $server_ip"
    else
        print_error "Failed to generate TLS certificate"
        return 1
    fi
}

# ==============================================================================
# 6. TUNNEL PROFILES (FIXED: sends menu to stderr, returns only data)
# ==============================================================================
select_tunnel_profile() {
    echo "" >&2
    print_step "Select tunnel profile" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    
    echo -e "${CYAN}► KCP FAMILY (UDP - Anti Packet Loss):${NC}" >&2
    echo -e "${WHITE}[1]${NC} KCP-Normal   (mode=normal - Balanced)       ${YELLOW}★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[2]${NC} KCP-Fast     (mode=fast - High speed)       ${YELLOW}★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[3]${NC} KCP-Fast2    (mode=fast2 - Very high speed) ${YELLOW}★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[4]${NC} KCP-Fast3    (mode=fast3 - Maximum speed)   ${YELLOW}★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[5]${NC} KCP-Manual   (Advanced config)              ${YELLOW}★ ★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[6]${NC} KCP+obfs4-Fast3 (KCP fast3 + obfs4 stealth)  ${YELLOW}★ ★ ★ ★ ★${NC}" >&2
    
    echo -e "\n${GREEN}► TLS/SSL FAMILY (TCP - Enterprise Security):${NC}" >&2
    echo -e "${WHITE}[7]${NC} TLS-Standard   (Raw TLS encryption)         ${YELLOW}★ ★ ★${NC}" >&2
    echo -e "${WHITE}[8]${NC} MTLS-Multiplex (TLS + multiplexing)         ${YELLOW}★ ★ ★${NC}" >&2
    
    echo -e "\n${YELLOW}► WEBSOCKET FAMILY (TCP - Web Compatible):${NC}" >&2
    echo -e "${WHITE}[9]${NC} WS-Simple      (WebSocket - plain)          ${YELLOW}★ ★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[10]${NC} MWS-Multiplex  (WebSocket + multiplex)      ${YELLOW}★ ★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[11]${NC} WSS-Secure     (WebSocket Secure)          ${YELLOW}★ ★ ★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[12]${NC} MWSS-Multiplex (WSS + multiplex)           ${YELLOW}★ ★ ★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[13]${NC} MW-Bind       (Multiplex WS + bind mode)   ${YELLOW}★ ★ ★ ★${NC}" >&2
    
    echo -e "\n${BLUE}► gRPC FAMILY (Modern RPC - High Performance):${NC}" >&2
    echo -e "${WHITE}[14]${NC} gRPC-Gun  (Plain gRPC)                ${YELLOW}★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[15]${NC} gRPC+TLS       (gRPC with TLS)             ${YELLOW}★ ★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[16]${NC} gRPC+Keepalive (gRPC with keepalive)       ${YELLOW}★ ★ ★ ★${NC}" >&2
    
    echo -e "\n${BLUE}► MODERN UDP FAMILY (UDP - Low Latency):${NC}" >&2
    echo -e "${WHITE}[17]${NC} QUIC-Standard (HTTP/3-like transport)      ${YELLOW}★ ★ ★ ★ ★${NC}" >&2
    
    echo -e "\n${MAGENTA}► HTTP2 FAMILY (Modern Protocols):${NC}" >&2
    echo -e "${WHITE}[18]${NC} HTTP2-Standard (HTTP/2 with TLS)           ${YELLOW}★ ★ ★ ★ ★ ★${NC}" >&2
    echo -e "${WHITE}[19]${NC} H2C-Cleartext (HTTP/2 without TLS)         ${YELLOW}★ ★ ★ ★${NC}" >&2
    
    echo -e "\n${ORANGE}► SSH FAMILY (Secure Shell):${NC}" >&2
    echo -e "${WHITE}[20]${NC} SSH-Tunnel (SSH protocol forwarding)       ${YELLOW}★ ★ ★${NC}" >&2
    
    echo -e "\n${PURPLE}► OBFUSCATION FAMILY (Maximum Stealth):${NC}" >&2
    echo -e "${WHITE}[21]${NC} obfs4 (Tor bridges - strongest)            ${YELLOW}★ ★ ★${NC}" >&2
    
    echo -e "\n${CYAN}► SHADOWSOCKS FAMILY (Standard Encryption):${NC}" >&2
    echo -e "${WHITE}[22]${NC} SS-TCP (Shadowsocks TCP)                   ${YELLOW}★ ★ ★${NC}" >&2
    echo -e "${WHITE}[23]${NC} SSU-UDP (Shadowsocks UDP relay)            ${YELLOW}★ ★ ★${NC}" >&2
    echo -e "${WHITE}[24]${NC} SS+TLS (Shadowsocks over TLS)              ${YELLOW}★ ★ ★${NC}" >&2
    echo -e "${WHITE}[25]${NC} SS+WS (Shadowsocks over WebSocket)         ${YELLOW}★ ★ ★${NC}" >&2
    
    echo -e "\n${GREEN}► COMBINED PROFILES (Ready-to-use recipes):${NC}" >&2
    echo -e "${WHITE}[26]${NC} Ultimate-Stealth (obfs4 + TLS + relay)     ${YELLOW}★ ★ ★${NC}" >&2
    echo -e "${WHITE}[27]${NC} Web-Tunnel (HTTP + MWSS + Multiplex)       ${YELLOW}★ ★ ★${NC}" >&2
    echo -e "${WHITE}[28]${NC} Gaming-Optimized (SOCKS5 + KCP)            ${YELLOW}★ ★ ★${NC}" >&2
    echo -e "${WHITE}[29]${NC} Forward-SSH (Forward + SSH)                ${YELLOW}★ ★ ★${NC}" >&2
    echo -e "${WHITE}[30]${NC} QUIC + SOCKS5 (QUIC first + SOCKS5)        ${YELLOW}★ ★ ★${NC}" >&2
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    
    local choice=""
    while true; do
        prompt_input "Select profile [1-30] (default: 12 - MWSS-Multiplex):" >&2
        read -p "" choice </dev/tty
        echo "" >&2
        
        choice=${choice:-12}

        case $choice in
            1) 
                echo "relay+kcp|mode=normal&crypt=aes-128-gcm&mtu=1350&sndwnd=2048&rcvwnd=2048&keepalive=true"
                return 0
                ;;
            2) 
                echo "relay+kcp|mode=fast&crypt=aes-128-gcm&mtu=1350&sndwnd=2048&rcvwnd=2048&keepalive=true"
                return 0
                ;;
            3) 
                echo "relay+kcp|mode=fast2&crypt=aes-128-gcm&mtu=1350&sndwnd=2048&rcvwnd=2048&keepalive=true"
                return 0
                ;;
            4) 
                echo "relay+kcp|mode=fast3&crypt=aes-128-gcm&mtu=1350&sndwnd=2048&rcvwnd=2048&keepalive=true"
                return 0
                ;;
            5) 
                echo "relay+kcp|mode=manual&resend=0&nc=1&dshard=10&pshard=3&mtu=1350&sndwnd=1024&rcvwnd=1024&keepalive=true&crypt=aes-128-gcm"
                return 0
                ;;
            6)
                echo "relay+kcp+obfs4|mode=fast3&crypt=chacha20&mtu=1350&sndwnd=2048&rcvwnd=2048&iat-mode=0"
                return 0
                ;;
            7) 
                echo "relay+tls|keepalive=true"
                return 0
                ;;
            8) 
                echo "relay+mtls|keepalive=true"
                return 0
                ;;
            9) 
                echo "relay+ws|keepalive=true"
                return 0
                ;;
            10) 
                echo "relay+mws|keepalive=true&ping=30"
                return 0
                ;;
            11) 
                echo "relay+wss|keepalive=true"
                return 0
                ;;
            12) 
                echo "relay+mwss|keepalive=true&ping=30"
                return 0
                ;;
            13)
                echo "relay+mw|keepalive=true&bind=true"
                return 0
                ;;
            14)
                echo "relay+grpc|keepalive=true&ping=30"
                return 0
                ;;
            15)
                echo "relay+grpc+tls|keepalive=true"
                return 0
                ;;
            16)
                echo "relay+grpc|keepalive=true"
                return 0
                ;;
            17) 
                echo "relay+quic|keepalive=true&timeout=30"
                return 0
                ;;
            18) 
                echo "relay+h2|keepalive=true"
                return 0
                ;;
            19) 
                echo "relay+h2c|keepalive=true"
                return 0
                ;;
            20) 
                echo "forward+ssh|ping=60"
                return 0
                ;;
            21) 
                echo "relay+obfs4|iat-mode=0"
                return 0
                ;;
            22) 
                echo "ss|aes-256-gcm"
                return 0
                ;;
            23)
                echo "ssu|aes-256-gcm"
                return 0
                ;;
            24)
                echo "ss+tls|aes-256-gcm"
                return 0
                ;;
            25)
                echo "ss+ws|aes-256-gcm"
                return 0
                ;;
            26) 
                echo "relay+obfs4+tls|iat-mode=0"
                return 0
                ;;
            27) 
                echo "http+mwss|keepalive=true&ping=30&path=/ws"
                return 0
                ;;
            28) 
                echo "socks5+kcp|mode=fast3&crypt=aes-128-gcm"
                return 0
                ;;
            29) 
                echo "forward+ssh|ping=60"
                return 0
                ;;
            30) 
                echo "socks5+quic|keepalive=true&timeout=60"
                return 0
                ;;
            *) 
                print_warning "Invalid selection (1-30 only)" >&2
                ;;
        esac
    done
}

# ==============================================================================
# 7. WATCHDOG SYSTEM
# ==============================================================================

create_watchdog() {
    if [[ -f "$WATCHDOG_PATH" ]]; then
        return 0
    fi
    
    cat > "$WATCHDOG_PATH" <<'EOF'
#!/bin/bash
SERVICE="$1"
TARGET="$2"
LOG="/var/log/gost-watchdog.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

check_service() {
    if ! systemctl is-active --quiet "$SERVICE"; then
        log "Service $SERVICE is down, restarting..."
        systemctl restart "$SERVICE"
        return 1
    fi
    return 0
}

check_connectivity() {
    if command -v curl &>/dev/null; then
        curl -s --max-time 5 "http://$TARGET" >/dev/null 2>&1 && return 0
    fi
    if command -v nc &>/dev/null; then
        nc -z -w 5 "$TARGET" 80 >/dev/null 2>&1 && return 0
    fi
    if command -v ping &>/dev/null; then
        ping -c 2 -W 3 "$TARGET" >/dev/null 2>&1 && return 0
    fi
    return 1
}

log "Checking $SERVICE..."
if ! check_service; then
    exit 0
fi

if [[ -n "$TARGET" ]] && ! check_connectivity; then
    log "Connection lost to $TARGET, restarting $SERVICE..."
    systemctl restart "$SERVICE"
fi
EOF
    
    chmod +x "$WATCHDOG_PATH"
    print_success "Watchdog created"
}

register_monitoring() {
    local service=$1
    local target=$2
    
    if ! check_crontab; then
        return 1
    fi
    
    if crontab -l 2>/dev/null | grep -q "$service"; then
        return 0
    fi
    
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null > "$temp_cron" || true
    echo "*/2 * * * * $WATCHDOG_PATH $service $target" >> "$temp_cron"
    
    if crontab "$temp_cron" 2>/dev/null; then
        print_success "Monitoring enabled for $service"
        rm -f "$temp_cron"
    else
        print_error "Failed to setup monitoring"
        rm -f "$temp_cron"
        return 1
    fi
}

# ==============================================================================
# 8. CLIENT CONFIGURATION
# ==============================================================================

setup_client() {
    show_banner
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${WHITE}           CLIENT TUNNEL SETUP              ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}\n"
    
    # Step 1: Profile Selection
    echo -e "${CYAN}Step 1: Select Tunnel Profile${NC}"
    local profile_output=$(select_tunnel_profile)
    local transport=$(echo "$profile_output" | cut -d'|' -f1)
    local params=$(echo "$profile_output" | cut -d'|' -f2)
    
    # Extract clean profile name from transport
    local profile_name=""
    if [[ "$transport" == *"kcp"* ]]; then
        profile_name="kcp"
    elif [[ "$transport" == *"tls"* ]]; then
        profile_name="tls"
    elif [[ "$transport" == *"ws"* || "$transport" == *"mws"* ]]; then
        profile_name="ws"
    elif [[ "$transport" == *"quic"* ]]; then
        profile_name="quic"
    elif [[ "$transport" == *"h2"* ]]; then
        profile_name="h2"
    elif [[ "$transport" == *"ssh"* ]]; then
        profile_name="ssh"
    elif [[ "$transport" == *"obfs4"* ]]; then
        profile_name="obfs4"
    elif [[ "$transport" == *"ss"* ]]; then
        profile_name="ss"
    else
        profile_name="custom"
    fi    
    print_success "Selected: $transport"
    
    # Step 2: Server IP
    echo ""
    echo -e "${CYAN}Step 2: Remote Server Configuration${NC}"
    local remote_ip=""
    while true; do
        prompt_input "Remote server IP:"
        read -p "" remote_ip </dev/tty
        if validate_ip "$remote_ip"; then
            print_success "Remote IP: $remote_ip"
            break
        else
            print_warning "Invalid IP format, try again"
        fi
    done
    
    # Step 3: Tunnel Port
    echo ""
    echo -e "${CYAN}Step 3: Tunnel port${NC}"
    prompt_input "Tunnel port [8443]:"
    read -p "" tunnel_port </dev/tty
    tunnel_port=${tunnel_port:-8443}
    while ! validate_port "$tunnel_port"; do
        prompt_input "Invalid port, try again:"
        read -p "" tunnel_port </dev/tty
    done
    print_success "Tunnel port: $tunnel_port"
    
    # Step 4: Password
    echo ""
    echo -e "${CYAN}Step 4: Authentication${NC}"
    local password=""
    prompt_input "Password (same as server):"
    read -p "" password </dev/tty

    while [[ -z "$password" ]]; do
        prompt_input "Password cannot be empty:"
        read -p "" password </dev/tty
    done
    print_success "Password: [hidden]"
    
    # Step 5: Forward Ports (Multi-Port with Protocol Selection)
    echo ""
    echo -e "${CYAN}Step 5: Port Forwarding Configuration${NC}"
    echo -e "${WHITE}Enter ports to forward (comma-separated, e.g., 443,8080,20022):${NC}"
    prompt_input "Ports:"
    read -p "" forward_ports </dev/tty
    
    # Clean and validate ports
    forward_ports=$(clean_port_list "$forward_ports")
    
    if [[ -z "$forward_ports" ]]; then
        print_warning "No ports to forward"
        # Build command without port forwarding
        local cmd=("$BIN_PATH")
    else
        # Split ports into array
        IFS=',' read -ra ports_array <<< "$forward_ports"
        local total_ports=${#ports_array[@]}
        
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${WHITE}Configure protocol for each port:${NC}"
        echo -e "${WHITE}  [1] TCP only${NC}"
        echo -e "${WHITE}  [2] UDP only${NC}"
        echo -e "${WHITE}  [3] Both TCP and UDP${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # Arrays to store protocol selections
        declare -a port_protocols
        
        for i in "${!ports_array[@]}"; do
            local port="${ports_array[$i]}"
            local port_num=$((i+1))
            
            echo ""
            while true; do
                prompt_input "Protocol for port $port [${port_num}/$total_ports] (1=TCP, 2=UDP, 3=Both):"
                read -p "" protocol_choice </dev/tty
                
                case $protocol_choice in
                    1|2|3)
                        port_protocols[$i]=$protocol_choice
                        case $protocol_choice in
                            1) echo "  → TCP only selected for port $port" ;;
                            2) echo "  → UDP only selected for port $port" ;;
                            3) echo "  → TCP and UDP selected for port $port" ;;
                        esac
                        break
                        ;;
                    *)
                        print_warning "Please select 1, 2, or 3"
                        ;;
                esac
            done
        done
        
        # Build command with selected protocols
        local cmd=("$BIN_PATH")
        echo ""
        echo -e "${CYAN}Configuring firewall and port forwarding:${NC}"
        for i in "${!ports_array[@]}"; do
            local port="${ports_array[$i]}"
            local protocol="${port_protocols[$i]}"
            
            case $protocol in
                1)  # TCP only
                    configure_firewall_protocol "$port" "tcp"
                    cmd+=(-L "tcp://:$port/127.0.0.1:$port")
                    echo -e "  ${GREEN}✓${NC} Port $port: TCP"
                    ;;
                2)  # UDP only
                    configure_firewall_protocol "$port" "udp"
                    cmd+=(-L "udp://:$port/127.0.0.1:$port")
                    echo -e "  ${GREEN}✓${NC} Port $port: UDP"
                    ;;
                3)  # Both
                    configure_firewall_protocol "$port" "both"
                    cmd+=(-L "tcp://:$port/127.0.0.1:$port")
                    cmd+=(-L "udp://:$port/127.0.0.1:$port")
                    echo -e "  ${GREEN}✓${NC} Port $port: TCP + UDP"
                    ;;
            esac
        done
    fi
    
    # Build forward URL with authentication
    local forward_url=""
    local auth_part=""
    local extra_params=""

    if [[ "$transport" == *wss* || "$transport" == *mws* || "$transport" == *mwss* || "$transport" == *tls* || "$transport" == *mtls* || "$transport" == *quic* || "$transport" == *h2* || "$transport" == *ss+tls* ]]; then
        extra_params="&secure=false"
    fi

    if [[ "$transport" == "relay+mws" || "$transport" == "relay+mwss" ]]; then
        auth_part="admin:$password@"
        forward_url="${transport}://${auth_part}${remote_ip}:${tunnel_port}"
    else
        forward_url="${transport}://${remote_ip}:${tunnel_port}"
        auth_part="&key=$password"
    fi

    local query_params=""
    if [[ -n "$params" ]]; then
        query_params="${params}"
    fi

    if [[ -n "$auth_part" && "$auth_part" == "&key="* ]]; then
        query_params="${query_params:+$query_params&}${auth_part:1}"
    fi

    if [[ -n "$extra_params" ]]; then
        query_params="${query_params:+$query_params}${extra_params}"
    fi

    if [[ -n "$query_params" ]]; then
        forward_url="${forward_url}?${query_params}"
    fi

    cmd+=(-F "$forward_url")
    
    # Build clean service name
    local service_name="gost-client-${profile_name}-${tunnel_port}"
    service_name=$(echo "$service_name" | tr -cd '[:alnum:]-' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    
    # Create service
    cat > "${SERVICE_DIR}/${service_name}.service" <<EOF
[Unit]
Description=Gost Client - ${profile_name} to ${remote_ip}:${tunnel_port}
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${cmd[*]}
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
SyslogIdentifier=gost-client

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$service_name" &>/dev/null
    systemctl start "$service_name"
    
    if systemctl is-active --quiet "$service_name"; then
        print_success "Client tunnel created: $service_name"
        register_monitoring "$service_name" "$remote_ip"
        
        echo ""
        echo -e "${GREEN}════════════════════════════════════════════${NC}"
        echo -e "${WHITE}        CONNECTION DETAILS${NC}"
        echo -e "${GREEN}════════════════════════════════════════════${NC}"
        echo -e "${WHITE}Service:${NC}     $service_name"
        echo -e "${WHITE}Remote:${NC}      $remote_ip:$tunnel_port"
        echo -e "${WHITE}Profile:${NC}     $transport"
        
        if [[ -n "$forward_ports" ]]; then
            echo -e "${WHITE}Forwarding:${NC}"
            for i in "${!ports_array[@]}"; do
                local port="${ports_array[$i]}"
                local protocol="${port_protocols[$i]}"
                case $protocol in
                    1) echo -e "  - Port $port: ${CYAN}TCP${NC}" ;;
                    2) echo -e "  - Port $port: ${CYAN}UDP${NC}" ;;
                    3) echo -e "  - Port $port: ${CYAN}TCP+UDP${NC}" ;;
                esac
            done
        fi
        echo -e "${GREEN}════════════════════════════════════════════${NC}"
    else
        print_error "Failed to start tunnel"
        journalctl -u "$service_name" -n 20 --no-pager
    fi
    
    pause
}

# Add this helper function for protocol-specific firewall rules
configure_firewall_protocol() {
    local port=$1
    local protocol=$2
    if ! validate_port "$port"; then return 1; fi
    
    if command -v ufw &>/dev/null; then
        case $protocol in
            tcp) ufw allow "$port"/tcp &>/dev/null ;;
            udp) ufw allow "$port"/udp &>/dev/null ;;
            both) 
                ufw allow "$port"/tcp &>/dev/null
                ufw allow "$port"/udp &>/dev/null
                ;;
        esac
        print_success "Firewall rule added for port $port ($protocol) - UFW"
    elif command -v iptables &>/dev/null; then
        case $protocol in
            tcp) iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null ;;
            udp) iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null ;;
            both)
                iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
                iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
                ;;
        esac
        print_success "Firewall rule added for port $port ($protocol) - iptables"
    fi
}

# ==============================================================================
# 9. SERVER CONFIGURATION
# ==============================================================================

setup_server() {
    show_banner
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${WHITE}           SERVER TUNNEL SETUP              ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}\n"
    
    # Step 1: Profile Selection
    echo -e "${CYAN}Step 1: Select Tunnel Profile${NC}"
    local profile_output=$(select_tunnel_profile)
    local transport=$(echo "$profile_output" | cut -d'|' -f1)
    local params=$(echo "$profile_output" | cut -d'|' -f2)
    
    # Extract clean profile name from transport
    local profile_name=""
    if [[ "$transport" == *"kcp"* ]]; then
        profile_name="kcp"
    elif [[ "$transport" == *"tls"* ]]; then
        profile_name="tls"
    elif [[ "$transport" == *"ws"* || "$transport" == *"mws"* ]]; then
        profile_name="ws"
    elif [[ "$transport" == *"quic"* ]]; then
        profile_name="quic"
    elif [[ "$transport" == *"h2"* ]]; then
        profile_name="h2"
    elif [[ "$transport" == *"ssh"* ]]; then
        profile_name="ssh"
    elif [[ "$transport" == *"obfs4"* ]]; then
        profile_name="obfs4"
    elif [[ "$transport" == *"ss"* ]]; then
        profile_name="ss"
    else
        profile_name="custom"
    fi
    
    print_success "Selected: $transport"
    
    # Step 2: Listen Port
    echo ""
    echo -e "${CYAN}Step 2: Tunnel port${NC}"
    local tunnel_port=""
    prompt_input "Listen port [8443]:"
    read -p "" tunnel_port </dev/tty
    tunnel_port=${tunnel_port:-8443}
    while ! validate_port "$tunnel_port"; do
        prompt_input "Invalid port, try again:"
        read -p "" tunnel_port </dev/tty
    done
    print_success "Listen port: $tunnel_port"
    
    # Step 3: Password
    echo ""
    echo -e "${CYAN}Step 3: Authentication${NC}"
    local auto_pass=$(generate_tunnel_key)
    echo -e "${WHITE}Generated password:${NC} $auto_pass"
    prompt_input "Use this password? (Y/n):"
    read -p "" use_gen </dev/tty
    
    local password="$auto_pass"
    if [[ "$use_gen" =~ ^[Nn]$ ]]; then
        prompt_input "Enter custom password:"
        read -p "" password </dev/tty
        while [[ -z "$password" ]]; do
            prompt_input "Password cannot be empty:"
            read -p "" password </dev/tty
        done
    fi
    print_success "Password: [hidden]"
    
    # Build clean service name
    local service_name="gost-server-${profile_name}-${tunnel_port}"
    service_name=$(echo "$service_name" | tr -cd '[:alnum:]-' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    
    # Configure firewall
    configure_firewall "$tunnel_port"
    
    # Build command
    local cmd=("$BIN_PATH" -L)
    
    if [[ "$transport" == *tls* || "$transport" == *wss* || "$transport" == *mws* || "$transport" == *mwss* || "$transport" == *quic* || "$transport" == *h2* || "$transport" == *ss+tls* ]]; then
        generate_tls_certificate
        local tls_params="cert=$TLS_DIR/server.crt&key=$TLS_DIR/server.key"
        if [[ -n "$params" ]]; then
            params="${params}&${tls_params}"
        else
            params="${tls_params}"
        fi
    fi    
    
    local listen_url="$transport://:$tunnel_port"
    if [[ -n "$params" ]]; then
        listen_url="${listen_url}?$params&key=$password"
    else
        listen_url="${listen_url}?key=$password"
    fi
    cmd+=("$listen_url")
    
    # Create service
    cat > "${SERVICE_DIR}/${service_name}.service" <<EOF
[Unit]
Description=Gost Server - ${profile_name} on port ${tunnel_port}
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${cmd[*]}
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
SyslogIdentifier=gost-server

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$service_name" &>/dev/null
    systemctl start "$service_name"
    
    if systemctl is-active --quiet "$service_name"; then
        print_success "Server tunnel created: $service_name"
        
        local public_ip=$(get_public_ip)
        echo ""
        echo -e "${GREEN}════════════════════════════════════════════${NC}"
        echo -e "${WHITE}        SERVER CONFIGURATION${NC}"
        echo -e "${GREEN}════════════════════════════════════════════${NC}"
        echo -e "${WHITE}Service:${NC}     $service_name"
        echo -e "${WHITE}Listen:${NC}      0.0.0.0:$tunnel_port"
        echo -e "${WHITE}Public IP:${NC}   $public_ip"
        echo -e "${WHITE}Profile:${NC}     $transport"
        echo -e "${WHITE}Password:${NC}    $password"
        echo -e "${YELLOW}  [!] Save this password - client needs it${NC}"
        echo -e "${GREEN}════════════════════════════════════════════${NC}"
    else
        print_error "Failed to start server"
        journalctl -u "$service_name" -n 20 --no-pager
    fi
    
    pause
}

# ==============================================================================
# 10. TUNNEL MANAGEMENT MENU
# ==============================================================================

manage_tunnels() {
    while true; do
        show_banner
        echo -e "${BLUE}════════════════════════════════════════════${NC}"
        echo -e "${WHITE}            TUNNEL MANAGEMENT               ${NC}"
        echo -e "${BLUE}════════════════════════════════════════════${NC}\n"
        
        local services=($(systemctl list-units --type=service --all --no-pager --plain 2>/dev/null | grep "gost-" | awk '{print $1}'))
        
        if [ ${#services[@]} -eq 0 ]; then
            echo -e "${YELLOW}No tunnels configured${NC}\n"
            pause
            return
        fi
        
        local count=1
        declare -A service_map
        
        for svc in "${services[@]}"; do
            local status=$(systemctl is-active "$svc" 2>/dev/null)
            local status_color
            
            if [[ "$status" == "active" ]]; then
                status_color="${GREEN}●${NC}"
            elif [[ "$status" == "failed" ]]; then
                status_color="${RED}✗${NC}"
            else
                status_color="${YELLOW}○${NC}"
            fi
            
            echo -e "${WHITE}[$count]${NC} $status_color $svc"
            service_map[$count]="$svc"
            ((count++))
        done
        
        echo -e "\n${WHITE}[0]${NC} Back to Main Menu"
        
        prompt_input "Select tunnel:"
        read -p "" choice </dev/tty
        echo ""
        
        case $choice in
            0) return ;;
            [0-9]*)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ -n "${service_map[$choice]}" ]; then
                    manage_single_tunnel "${service_map[$choice]}"
                else
                    print_warning "Invalid selection"
                    sleep 1
                fi
                ;;
            *) print_warning "Invalid option"; sleep 1 ;;
        esac
    done
}

manage_single_tunnel() {
    local service=$1
    local service_file="${SERVICE_DIR}/${service}"

    while true; do
        show_banner
        echo -e "${BLUE}════════════════════════════════════════════${NC}"
        echo -e "${WHITE}TUNNEL: $service${NC}"
        echo -e "${BLUE}════════════════════════════════════════════${NC}\n"
        
        # Get service status
        local status=$(systemctl is-active "$service" 2>/dev/null)
        local enabled=$(systemctl is-enabled "$service" 2>/dev/null)
        local pid=$(systemctl show -p MainPID "$service" 2>/dev/null | cut -d= -f2)
        local memory=$(systemctl show -p MemoryCurrent "$service" 2>/dev/null | cut -d= -f2)
        
        echo -e "${WHITE}Status:${NC} $(if [[ "$status" == "active" ]]; then echo "${GREEN}● Active${NC}"; elif [[ "$status" == "failed" ]]; then echo "${RED}✗ Failed${NC}"; else echo "${YELLOW}○ Inactive${NC}"; fi)"
        echo -e "${WHITE}Enabled:${NC} $(if [[ "$enabled" == "enabled" ]]; then echo "${GREEN}Yes${NC}"; else echo "${RED}No${NC}"; fi)"
        [ "$pid" != "0" ] && echo -e "${WHITE}PID:${NC} $pid"
        if [[ -n "$memory" && "$memory" != "0" && "$memory" != "[not set]" ]]; then
            echo -e "${WHITE}Memory:${NC} $((memory/1024)) KB"
        fi

        echo -e "\n${CYAN}Actions:${NC}"
        echo -e "${WHITE}[1]${NC} Start Tunnel"
        echo -e "${WHITE}[2]${NC} Stop Tunnel"
        echo -e "${WHITE}[3]${NC} Restart Tunnel"
        echo -e "${WHITE}[4]${NC} View Live Logs"
        echo -e "${WHITE}[5]${NC} View Last 50 Log Lines"
        echo -e "${WHITE}[6]${NC} Edit Service File"
        echo -e "${WHITE}[7]${NC} Show Full Config"
        echo -e "${WHITE}[8]${NC} Enable/Disable Autostart"
        echo -e "${WHITE}[9]${NC} Remove Tunnel"
        echo -e "${WHITE}[0]${NC} Back to Tunnel List"
        prompt_input "Select action:"
        read -p "" action </dev/tty
        echo ""
        
        case $action in
            0) return ;;
            1) 
                systemctl start "$service"
                print_success "Tunnel started"
                sleep 1
                ;;
            2)
                systemctl stop "$service"
                print_success "Tunnel stopped"
                sleep 1
                ;;
            3)
                systemctl restart "$service"
                print_success "Tunnel restarted"
                sleep 2
                ;;
            4)
                print_info "Streaming logs (Ctrl+C to exit)..."
                sleep 1
                journalctl -u "$service" -f
                ;;
            5)
                journalctl -u "$service" -n 50 --no-pager
                pause
                ;;
            6)
                if [[ -f "$service_file" ]]; then
                    nano "$service_file"
                    systemctl daemon-reload
                    print_success "Service file updated"
                else
                    print_error "Service file not found: $service_file"
                fi
                pause
                ;;
            7)
                echo -e "\n${CYAN}Service File:${NC}"
                if [[ -f "$service_file" ]]; then
                    cat "$service_file"
                else
                    print_error "File not found: $service_file"
                fi
                pause
                ;;
            8)
                if systemctl is-enabled "$service" &>/dev/null; then
                    systemctl disable "$service"
                    print_success "Autostart disabled"
                else
                    systemctl enable "$service"
                    print_success "Autostart enabled"
                fi
                sleep 1
                ;;
            9)
                print_warning "This will permanently remove $service"
                prompt_input "Confirm? (y/N):"
                read -p "" confirm </dev/tty
                echo ""
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    systemctl stop "$service" &>/dev/null
                    systemctl disable "$service" &>/dev/null
                    rm -f "$service_file"
                    systemctl daemon-reload
                    
                    if check_crontab; then
                        local temp_cron=$(mktemp)
                        crontab -l 2>/dev/null | grep -v "$service" > "$temp_cron"
                        crontab "$temp_cron" 2>/dev/null
                        rm -f "$temp_cron"
                    fi
                    
                    print_success "Tunnel removed"
                    sleep 1
                    return
                fi
                ;;
            *) print_warning "Invalid option"; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# 11. LOGS VIEWER
# ==============================================================================

view_logs_menu() {
    while true; do
        show_banner
        echo -e "${BLUE}════════════════════════════════════════════${NC}"
        echo -e "${WHITE}               LOGS VIEWER                  ${NC}"
        echo -e "${BLUE}════════════════════════════════════════════${NC}\n"
        
        local services=($(systemctl list-units --type=service --all --no-pager --plain 2>/dev/null | grep "gost-" | awk '{print $1}'))
        
        if [ ${#services[@]} -eq 0 ]; then
            echo -e "${YELLOW}No tunnels found${NC}\n"
            pause
            return
        fi
        
        local count=1
        declare -A log_map
        
        for svc in "${services[@]}"; do
            echo -e "${WHITE}[$count]${NC} $svc"
            log_map[$count]="$svc"
            ((count++))
        done
        
        echo -e "\n  ${WHITE}[0]${NC} Back to Main Menu"
        
        prompt_input "Select tunnel for logs:"
        read -p "" choice </dev/tty
        echo ""
        
        case $choice in
            0) return ;;
            [0-9]*)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ -n "${log_map[$choice]}" ]; then
                    local svc="${log_map[$choice]}"
                    echo -e "\n${CYAN}Log options for $svc:${NC}"
                    echo -e "${WHITE}[1]${NC} Live logs (follow)"
                    echo -e "${WHITE}[2]${NC} Last 100 lines"
                    echo -e "${WHITE}[3]${NC} Last 50 lines with errors"
                    echo -e "${WHITE}[0]${NC} Back"
                    
                    prompt_input "Select:"
                    read -p "" log_opt </dev/tty
                    echo ""
                    
                    case $log_opt in
                        0) continue ;;
                        1) journalctl -u "$svc" -f ;;
                        2) journalctl -u "$svc" -n 100 --no-pager | less ;;
                        3) journalctl -u "$svc" -n 50 --no-pager | grep -i "error\|fail\|warn" --color=always | less ;;
                        *) print_warning "Invalid option" ;;
                    esac
                else
                    print_warning "Invalid selection"
                    sleep 1
                fi
                ;;
            *) print_warning "Invalid option"; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# 12. SYSTEM INFO
# ==============================================================================

show_system_info() {
    show_banner
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${WHITE}            SYSTEM INFORMATION              ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}\n"
    
    local os=$(detect_os)
    local arch=$(detect_arch)
    local public_ip=$(get_public_ip)
    local hostname=$(hostname)
    local uptime=$(uptime -p | sed 's/up //')
    local cpu_load=$(uptime | awk -F'load average:' '{print $2}')
    local mem_total=$(free -h | awk '/^Mem:/ {print $2}')
    local mem_used=$(free -h | awk '/^Mem:/ {print $3}')
    local disk_used=$(df -h / | awk 'NR==2 {print $3}')
    local disk_total=$(df -h / | awk 'NR==2 {print $2}')
    
    echo -e "${WHITE}Hostname:${NC}    $hostname"
    echo -e "${WHITE}Public IP:${NC}   $public_ip"
    echo -e "${WHITE}OS:${NC}          $os"
    echo -e "${WHITE}Architecture:${NC} $arch"
    echo -e "${WHITE}Uptime:${NC}      $uptime"
    echo -e "${WHITE}Load Avg:${NC}    $cpu_load"
    echo -e "${WHITE}Memory:${NC}      $mem_used / $mem_total"
    echo -e "${WHITE}Disk:${NC}        $disk_used / $disk_total"
    
    if [[ -x "$BIN_PATH" ]]; then
        local gost_version=$("$BIN_PATH" -V 2>&1 | head -1)
        echo -e "${WHITE}GOST Version:${NC} $gost_version"
    fi
    
    echo -e "\n${CYAN}Tunnel Statistics:${NC}"
    local total=$(systemctl list-units --type=service --all --no-pager --plain 2>/dev/null | grep -c "gost-")
    local active=$(systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null | grep -c "gost-")
    
    echo -e "${WHITE}Total Tunnels:${NC}  $total"
    echo -e "${WHITE}Active Tunnels:${NC} $active"
    
    pause
}

# ==============================================================================
# 13. MAIN MENU
# ==============================================================================

main_menu() {
    while true; do
        show_banner
        echo -e "${BLUE}════════════════════════════════════════════${NC}"
        echo -e "${WHITE}                MAIN MENU                   ${NC}"
        echo -e "${BLUE}════════════════════════════════════════════${NC}\n"
        echo -e "${WHITE}[1]${NC} Configure Client Tunnel  (Iran)"
        echo -e "${WHITE}[2]${NC} Configure Server Tunnel  (Kharej)"
        echo -e "${WHITE}[3]${NC} Manage Tunnels           (Start/Stop/Edit)"
        echo -e "${WHITE}[4]${NC} View Logs                (Live/Historical)"
        echo -e "${WHITE}[5]${NC} System Information"
        echo -e "${WHITE}[0]${NC} Exit"
        prompt_input "Select option:"
        read -p "" choice </dev/tty
        echo ""
        
        case $choice in
            1) setup_client ;;
            2) setup_server ;;
            3) manage_tunnels ;;
            4) view_logs_menu ;;
            5) show_system_info ;;
            0) print_success "Goodbye!" && exit 0 ;;
            *) print_warning "Invalid option" && sleep 1 ;;
        esac
    done
}

# ==============================================================================
# 14. INITIALIZATION
# ==============================================================================

init() {
    check_root
    setup_environment
    deploy_gost_binary
    create_watchdog
    
    local bin_path="/usr/local/bin/gost-manager"
    if [[ ! -f "$bin_path" ]] || [[ "$0" != "$bin_path" ]]; then
        cp "$0" "$bin_path" 2>/dev/null
        chmod +x "$bin_path" 2>/dev/null
    fi
    
    main_menu
}

init "$@"
