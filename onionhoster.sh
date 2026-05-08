#!/bin/bash

# OnionHoster - Tor Hidden Service Hosting Script
# Works for any project (Next.js, Flask, static, etc.)
# Version: 2.5
# Author: BlackHatDevX
# GitHub: https://github.com/BlackHatDevX/onionhoster

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' 


SERVICE_DIR="/var/lib/tor"
SERVICE_NAME="my_hidden_service"
SERVICE_PATH="$SERVICE_DIR/$SERVICE_NAME"
BACKUP_DIR="$HOME/onion_backups"
SCRIPT_VERSION="2.5"
TOR_CONFIG="/etc/tor/torrc"
GITHUB_REPO="https://github.com/BlackHatDevX/onionhoster"
GITHUB_RELEASES="https://github.com/BlackHatDevX/onionhoster/releases/tag/"
SCRIPT_PATH="$(readlink -f "$0")"

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}================================${NC}"
    echo -e "${PURPLE}     OnionHoster v$SCRIPT_VERSION${NC}"
    echo -e "${PURPLE}================================${NC}"
    echo -e "${CYAN}GitHub: $GITHUB_REPO${NC}"
}


check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}


install_dependencies() {
    print_info "Detecting operating system..."

    if command -v apt-get &> /dev/null; then
        print_info "Detected Debian/Ubuntu system"
        apt-get update -y
        apt-get install -y tor unzip zip curl wget apache2
        TOR_USER="debian-tor"
        TOR_GROUP="debian-tor"
        WEB_SERVER="apache2"
    elif command -v yum &> /dev/null; then
        print_info "Detected CentOS/RHEL/Fedora system"
        yum install -y tor unzip zip curl wget httpd
        TOR_USER="tor"
        TOR_GROUP="tor"
        WEB_SERVER="httpd"
    elif command -v pacman &> /dev/null; then
        print_info "Detected Arch Linux system"
        pacman -S --noconfirm tor unzip zip curl wget apache
        TOR_USER="tor"
        TOR_GROUP="tor"
        WEB_SERVER="apache"
    elif command -v brew &> /dev/null; then
        print_info "Detected macOS system"
        BREW_PREFIX=$(brew --prefix 2>/dev/null)
        if [ -z "$BREW_PREFIX" ]; then
            BREW_PREFIX="/usr/local"
        fi
        print_info "Homebrew prefix: $BREW_PREFIX"

        if [[ $EUID -eq 0 ]]; then
            print_info "Running as root - using Homebrew as regular user"
            sudo -u "$SUDO_USER" brew install tor unzip zip curl wget httpd 2>/dev/null || {
                print_warning "Could not use sudo for brew, trying direct install..."
                brew install tor unzip zip curl wget httpd 2>/dev/null || true
            }
        else
            brew install tor unzip zip curl wget httpd
        fi
        TOR_USER="$SUDO_USER"
        if [ -z "$TOR_USER" ]; then
            TOR_USER="$(whoami)"
        fi
        TOR_GROUP="staff"
        TOR_CONFIG="$BREW_PREFIX/etc/tor/torrc"
        SERVICE_DIR="$BREW_PREFIX/var/lib/tor"
        SERVICE_PATH="$SERVICE_DIR/$SERVICE_NAME"
        WEB_SERVER="httpd"
    else
        print_error "Unsupported operating system. Please install Tor and Apache manually."
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"

    print_status "Dependencies installed successfully"
}

check_tor_service() {
    if ! command -v tor &> /dev/null; then
        print_error "Tor is not installed. Installing dependencies..."
        install_dependencies
    fi

    if command -v systemctl &> /dev/null; then
        if ! systemctl is-active --quiet tor 2>/dev/null; then
            print_warning "Tor service is not running. Starting it..."
            systemctl start tor 2>/dev/null || {
                print_error "Failed to start Tor service. Please check your installation."
                exit 1
            }
        fi
        systemctl enable tor 2>/dev/null
    elif command -v brew &> /dev/null; then
        print_info "Detected macOS - checking Tor process..."

        BREW_PREFIX=$(brew --prefix 2>/dev/null)
        if [ -z "$BREW_PREFIX" ]; then
            BREW_PREFIX="/usr/local"
        fi

        TOR_CONFIG="$BREW_PREFIX/etc/tor/torrc"
        TOR_DATA="$BREW_PREFIX/var/lib/tor"
        TOR_USER="$SUDO_USER"
        if [ -z "$TOR_USER" ]; then
            TOR_USER=$(whoami)
        fi

        print_info "Cleaning up old Tor configuration..."
        if [ -f "$TOR_CONFIG" ]; then
            sed -i '/^HiddenServiceDir\|^HiddenServicePort/d' "$TOR_CONFIG" 2>/dev/null || true
        fi
        rm -rf "$TOR_DATA/my_hidden_service" 2>/dev/null || true
        mkdir -p "$TOR_DATA"
        chown "$TOR_USER:staff" "$TOR_DATA"
        chmod 700 "$TOR_DATA"
        mkdir -p "$BREW_PREFIX/var/log/tor"
        chown "$TOR_USER:staff" "$BREW_PREFIX/var/log/tor"
        chmod 755 "$BREW_PREFIX/var/log/tor"
        TOR_BIN="$BREW_PREFIX/opt/tor/bin/tor"

        print_info "Using Tor binary: $TOR_BIN"
        print_info "Using Tor config: $TOR_CONFIG"
        print_info "Running Tor as user: $TOR_USER"

        if ! pgrep -u "$TOR_USER" -x "tor" > /dev/null 2>&1; then
            print_warning "Tor is not running. Starting it..."

            rm -f /tmp/tor.log

            if [ -f "$TOR_BIN" ]; then
                if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                    su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup $TOR_BIN --defaults-torrc $TOR_CONFIG > /tmp/tor.log 2>&1 &"
                else
                    touch /tmp/tor.log
                    nohup "$TOR_BIN" --defaults-torrc "$TOR_CONFIG" > /tmp/tor.log 2>&1 &
                fi
                sleep 3
            else
                if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                    su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup tor --defaults-torrc $TOR_CONFIG > /tmp/tor.log 2>&1 &"
                else
                    touch /tmp/tor.log
                    nohup tor --defaults-torrc "$TOR_CONFIG" > /tmp/tor.log 2>&1 &
                fi
                sleep 3
            fi

            if pgrep -u "$TOR_USER" -x "tor" > /dev/null 2>&1; then
                print_status "Tor started successfully"
            else
                print_error "Failed to start Tor. Check /tmp/tor.log for details."
                cat /tmp/tor.log 2>/dev/null | tail -10
                exit 1
            fi
        else
            print_status "Tor is already running"
        fi
    else
        if ! pgrep -x "tor" > /dev/null 2>&1; then
            print_warning "Tor is not running. Starting it..."
            nohup tor > /tmp/tor.log 2>&1 &
            sleep 3
            if pgrep -x "tor" > /dev/null 2>&1; then
                print_status "Tor started successfully"
            else
                print_error "Failed to start Tor. Check /tmp/tor.log for details."
                exit 1
            fi
        else
            print_status "Tor is already running"
        fi
    fi

    print_status "Tor service is running"
}


create_tor_config() {
    if [ ! -f "$TOR_CONFIG" ]; then
        print_warning "Tor configuration file not found. Creating default config..."
        mkdir -p "$(dirname "$TOR_CONFIG")"

        if command -v brew &> /dev/null; then
            BREW_PREFIX=$(brew --prefix 2>/dev/null)
            if [ -z "$BREW_PREFIX" ]; then
                BREW_PREFIX="/usr/local"
            fi
            cat > "$TOR_CONFIG" << EOF
# Tor configuration file
# Generated by OnionHoster

# Basic Tor settings
SocksPort 9050
DataDirectory $BREW_PREFIX/var/lib/tor
PidFile $BREW_PREFIX/var/lib/tor/tor.pid

# Network settings
AutomapHostsOnResolve 1
AvoidDiskWrites 1

# Hidden service settings
HiddenServiceVersion 3

# Logging
Log notice file $BREW_PREFIX/var/log/tor/notices.log
Log info file $BREW_PREFIX/var/log/tor/info.log

# Hidden service configurations will be added here
EOF
        else
            cat > "$TOR_CONFIG" << EOF
# Tor configuration file
# Generated by OnionHoster

# Basic Tor settings
SocksPort 9050
DataDirectory /var/lib/tor
PidFile /var/run/tor/tor.pid

# Network settings
AutomapHostsOnResolve 1
AvoidDiskWrites 1

# Hidden service settings
HiddenServiceVersion 3

# Logging
Log notice file /var/log/tor/notices.log
Log info file /var/log/tor/info.log

# Hidden service configurations will be added here
EOF
        fi
    fi

    if command -v getent &> /dev/null; then
        TOR_USER_ID=$(getent passwd "$TOR_USER" | cut -d: -f3 2>/dev/null)
        TOR_GROUP_ID=$(getent group "$TOR_GROUP" | cut -d: -f3 2>/dev/null)

        if [ -n "$TOR_USER_ID" ] && [ -n "$TOR_GROUP_ID" ]; then
            chown "$TOR_USER_ID:$TOR_GROUP_ID" "$TOR_CONFIG" 2>/dev/null || true
        fi
    fi
    chmod 644 "$TOR_CONFIG"

    if command -v brew &> /dev/null; then
        BREW_PREFIX=$(brew --prefix 2>/dev/null)
        if [ -z "$BREW_PREFIX" ]; then
            BREW_PREFIX="/usr/local"
        fi
        mkdir -p "$BREW_PREFIX/var/log/tor"
        if command -v getent &> /dev/null; then
            TOR_USER_ID=$(getent passwd "$TOR_USER" | cut -d: -f3 2>/dev/null)
            TOR_GROUP_ID=$(getent group "$TOR_GROUP" | cut -d: -f3 2>/dev/null)

            if [ -n "$TOR_USER_ID" ] && [ -n "$TOR_GROUP_ID" ]; then
                chown "$TOR_USER_ID:$TOR_GROUP_ID" "$BREW_PREFIX/var/log/tor" 2>/dev/null || true
            fi
        fi
        chmod 755 "$BREW_PREFIX/var/log/tor"

        mkdir -p "$SERVICE_DIR"
        if command -v getent &> /dev/null; then
            TOR_USER_ID=$(getent passwd "$TOR_USER" | cut -d: -f3 2>/dev/null)
            TOR_GROUP_ID=$(getent group "$TOR_GROUP" | cut -d: -f3 2>/dev/null)

            if [ -n "$TOR_USER_ID" ] && [ -n "$TOR_GROUP_ID" ]; then
                chown "$TOR_USER_ID:$TOR_GROUP_ID" "$SERVICE_DIR" 2>/dev/null || true
                chmod 700 "$SERVICE_DIR" 2>/dev/null || true
            fi
        fi
    else
        mkdir -p /var/log/tor
        if command -v getent &> /dev/null; then
            TOR_USER_ID=$(getent passwd "$TOR_USER" | cut -d: -f3 2>/dev/null)
            TOR_GROUP_ID=$(getent group "$TOR_GROUP" | cut -d: -f3 2>/dev/null)

            if [ -n "$TOR_USER_ID" ] && [ -n "$TOR_GROUP_ID" ]; then
                chown "$TOR_USER_ID:$TOR_GROUP_ID" /var/log/tor 2>/dev/null || true
            fi
        fi
        chmod 755 /var/log/tor

        mkdir -p "$SERVICE_DIR"
        if command -v getent &> /dev/null; then
            TOR_USER_ID=$(getent passwd "$TOR_USER" | cut -d: -f3 2>/dev/null)
            TOR_GROUP_ID=$(getent group "$TOR_GROUP" | cut -d: -f3 2>/dev/null)

            if [ -n "$TOR_USER_ID" ] && [ -n "$TOR_GROUP_ID" ]; then
                chown "$TOR_USER_ID:$TOR_GROUP_ID" "$SERVICE_DIR" 2>/dev/null || true
                chmod 700 "$SERVICE_DIR" 2>/dev/null || true
            fi
        fi
    fi

    print_status "Tor configuration created successfully"
}

cleanup_torrc() {
    print_info "Cleaning up torrc configuration..."
    
    if [ ! -f "$TOR_CONFIG" ]; then
        return
    fi
    
    cp "$TOR_CONFIG" "$TOR_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
    
    TEMP_TORRC="/tmp/torrc_clean_$$"
    
    awk '/^HiddenServiceDir/ || /^#PublishServerDescriptor/ {exit} {print}' "$TOR_CONFIG" > "$TEMP_TORRC"
    
    mv "$TEMP_TORRC" "$TOR_CONFIG"
    
    print_status "Torrc cleaned up successfully"
}

add_hidden_service_to_torrc() {
    local PORT="$1"
    
    print_info "Adding hidden service configuration to torrc..."
    
    sed -i "/HiddenServiceDir $SERVICE_PATH/,+1d" "$TOR_CONFIG" 2>/dev/null || true
    
    echo "" >> "$TOR_CONFIG"
    echo "HiddenServiceDir $SERVICE_PATH" >> "$TOR_CONFIG"
    echo "HiddenServicePort 80 127.0.0.1:$PORT" >> "$TOR_CONFIG"
    
    print_status "Hidden service configuration added to torrc"
}

start_service() {
    clear
    print_header
    echo -e "${CYAN}=== Host index.html ===${NC}"
    
    if [ ! -f "index.html" ]; then
        print_error "index.html not found in current directory"
        print_info "Please make sure index.html exists in: $(pwd)"
        read -p "Press Enter to continue..."
        return
    fi
    
    print_info "index.html found. Setting up hosting service..."
    
    print_info "Finding available port..."
    PORT=0
    MAX_ATTEMPTS=100
    
    for attempt in $(seq 1 $MAX_ATTEMPTS); do
        RANDOM_PORT=$((8000 + RANDOM % 57535))
        
        if ! netstat -tlnp 2>/dev/null | grep -q ":$RANDOM_PORT " && \
           ! ss -tlnp 2>/dev/null | grep -q ":$RANDOM_PORT "; then
            PORT=$RANDOM_PORT
            break
        fi
    done
    
    if [ $PORT -eq 0 ]; then
        print_error "Could not find a free port after $MAX_ATTEMPTS attempts"
        read -p "Press Enter to continue..."
        return
    fi
    
    print_status "Selected port: $PORT"
    
    print_info "Starting web server on port $PORT..."
    
    if command -v apache2 &> /dev/null || command -v httpd &> /dev/null; then
        print_info "Using Apache web server..."
        
        APACHE_CONF="/tmp/apache_onionhoster_$PORT.conf"
        APACHE_PID="/tmp/apache_onionhoster_$PORT.pid"
        
        cat > "$APACHE_CONF" << EOF
Listen $PORT
<VirtualHost *:$PORT>
    DocumentRoot $(pwd)
    ServerName localhost
    <Directory $(pwd)>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog /tmp/apache_error_$PORT.log
    CustomLog /tmp/apache_access_$PORT.log combined
    PidFile $APACHE_PID
</VirtualHost>
EOF
        
        if command -v apache2 &> /dev/null; then
            apache2 -f "$APACHE_CONF" -k start 2>/dev/null
            HTTP_PID=$(cat "$APACHE_PID" 2>/dev/null || echo "")
        elif command -v httpd &> /dev/null; then
            httpd -f "$APACHE_CONF" -k start 2>/dev/null
            HTTP_PID=$(cat "$APACHE_PID" 2>/dev/null || echo "")
        fi
        
        if [ -n "$HTTP_PID" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
            print_status "Apache started successfully with PID: $HTTP_PID"
            print_info "Apache config: $APACHE_CONF"
            print_info "Apache logs: /tmp/apache_error_$PORT.log, /tmp/apache_access_$PORT.log"
        else
            print_warning "Apache failed to start, trying alternative servers..."
            HTTP_PID=""
        fi
    fi
    
    if [ -z "$HTTP_PID" ]; then
        if command -v nginx &> /dev/null; then
            print_info "Using Nginx web server..."
            NGINX_CONF="/tmp/nginx_onionhoster_$PORT.conf"
            cat > "$NGINX_CONF" << EOF
events {
    worker_connections 1024;
}
http {
    server {
        listen $PORT;
        root $(pwd);
        index index.html;
        location / {
            try_files \$uri \$uri/ =404;
        }
    }
}
EOF
            nginx -c "$NGINX_CONF" -p /tmp/nginx_$PORT/ 2>/dev/null
            HTTP_PID=$(pgrep -f "nginx.*$PORT" | head -1)
            if [ -n "$HTTP_PID" ]; then
                print_status "Nginx started successfully with PID: $HTTP_PID"
                print_info "Nginx config: $NGINX_CONF"
            fi
        elif command -v python3 &> /dev/null; then
            print_info "Using Python3 HTTP server..."
            nohup python3 -m http.server $PORT > /tmp/http_server.log 2>&1 &
            HTTP_PID=$!
        elif command -v python &> /dev/null; then
            print_info "Using Python HTTP server..."
            nohup python -m SimpleHTTPServer $PORT > /tmp/http_server.log 2>&1 &
            HTTP_PID=$!
        elif command -v php &> /dev/null; then
            print_info "Using PHP built-in server..."
            nohup php -S 127.0.0.1:$PORT > /tmp/http_server.log 2>&1 &
            HTTP_PID=$!
        elif command -v node &> /dev/null; then
            print_info "Using Node.js HTTP server..."
            nohup node -e "require('http').createServer((req,res)=>{require('fs').readFile('index.html',(e,d)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end(d)})}).listen($PORT)" > /tmp/http_server.log 2>&1 &
            HTTP_PID=$!
        else
            print_error "No suitable web server found. Please install Apache, Nginx, Python, PHP, or Node.js"
            read -p "Press Enter to continue..."
            return
        fi
    fi
    
    sleep 2
    
    if kill -0 $HTTP_PID 2>/dev/null; then
        print_status "HTTP server started successfully with PID: $HTTP_PID"
        print_info "Server log: /tmp/http_server.log"
    else
        print_error "Failed to start HTTP server"
        if [ -f "/tmp/http_server.log" ]; then
            print_info "Server error log:"
            tail -5 /tmp/http_server.log
        fi
        read -p "Press Enter to continue..."
        return
    fi
    
    print_info "Creating Tor hidden service directory: $SERVICE_PATH"

    if command -v brew &> /dev/null; then
        BREW_PREFIX=$(brew --prefix 2>/dev/null)
        if [ -z "$BREW_PREFIX" ]; then
            BREW_PREFIX="/usr/local"
        fi
        TOR_USER="$SUDO_USER"
        if [ -z "$TOR_USER" ]; then
            TOR_USER=$(whoami)
        fi

        rm -rf "$SERVICE_PATH"
        if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
            su - "$SUDO_USER" -c "mkdir -p '$SERVICE_PATH' && chmod 700 '$SERVICE_PATH'"
        else
            mkdir -p "$SERVICE_PATH"
            chmod 700 "$SERVICE_PATH"
        fi
    else
        mkdir -p "$SERVICE_PATH"

        if command -v getent &> /dev/null; then
            TOR_USER_ID=$(getent passwd "$TOR_USER" | cut -d: -f3 2>/dev/null)
            TOR_GROUP_ID=$(getent group "$TOR_GROUP" | cut -d: -f3 2>/dev/null)

            if [ -n "$TOR_USER_ID" ] && [ -n "$TOR_GROUP_ID" ]; then
                chown "$TOR_USER_ID:$TOR_GROUP_ID" "$SERVICE_PATH"
                chmod 700 "$SERVICE_PATH"
            fi
        fi
    fi
    
    cleanup_torrc
    add_hidden_service_to_torrc "$PORT"
    
    print_info "Restarting Tor service..."
    if command -v systemctl &> /dev/null; then
        systemctl restart tor 2>/dev/null || {
            print_error "Failed to restart Tor service"
            kill $HTTP_PID 2>/dev/null || true
            read -p "Press Enter to continue..."
            return
        }
    else
        BREW_PREFIX=$(brew --prefix 2>/dev/null)
        if [ -z "$BREW_PREFIX" ]; then
            BREW_PREFIX="/usr/local"
        fi
        TOR_USER="$SUDO_USER"
        if [ -z "$TOR_USER" ]; then
            TOR_USER=$(whoami)
        fi

        pkill -u "$TOR_USER" -x tor 2>/dev/null || true
        sleep 1
        rm -f /tmp/tor.log
        if [ -f "$BREW_PREFIX/opt/tor/bin/tor" ]; then
            if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup $BREW_PREFIX/opt/tor/bin/tor --defaults-torrc $BREW_PREFIX/etc/tor/torrc > /tmp/tor.log 2>&1 &"
            else
                touch /tmp/tor.log
                nohup "$BREW_PREFIX/opt/tor/bin/tor" --defaults-torrc "$BREW_PREFIX/etc/tor/torrc" > /tmp/tor.log 2>&1 &
            fi
        else
            if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup tor --defaults-torrc $BREW_PREFIX/etc/tor/torrc > /tmp/tor.log 2>&1 &"
            else
                touch /tmp/tor.log
                nohup tor --defaults-torrc "$BREW_PREFIX/etc/tor/torrc" > /tmp/tor.log 2>&1 &
            fi
        fi
        sleep 3
    fi
    
    print_info "Waiting for Tor hidden service to initialize and generate hostname..."
    
    HOSTNAME_FILE="$SERVICE_PATH/hostname"
    MAX_WAIT=60
    WAIT_COUNT=0
    
    while [ ! -f "$HOSTNAME_FILE" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        print_info "Waiting for hostname file... ($WAIT_COUNT/$MAX_WAIT seconds)"
    done
    
    if [ -f "$HOSTNAME_FILE" ]; then
        ONION_ADDR=$(cat "$HOSTNAME_FILE")
        print_status "index.html Hosted Successfully!"
        echo ""
        echo -e "${GREEN}🔗 Onion Address: ${NC}$ONION_ADDR"
        echo -e "${GREEN}📍 Local Port: ${NC}$PORT"
        echo -e "${GREEN}📁 Service Path: ${NC}$SERVICE_PATH"
        echo -e "${GREEN}🌐 HTTP Server PID: ${NC}$HTTP_PID"
        echo ""
        echo -e "${YELLOW}Your index.html is now accessible via:${NC}"
        echo -e "${CYAN}http://$ONION_ADDR${NC}"
        echo ""
        echo -e "${YELLOW}Note:${NC} The HTTP server will continue running in the background."
        echo -e "${YELLOW}To stop it later, use:${NC} kill $HTTP_PID"
    else
        print_error "Failed to create Tor hidden service. Hostname file not generated."
        kill $HTTP_PID 2>/dev/null || true
    fi
    
    read -p "Press Enter to continue..."
}

stop_service() {
    clear
    print_header
    echo -e "${CYAN}=== Stop Hidden Service ===${NC}"
    
    if [ ! -d "$SERVICE_PATH" ]; then
        print_error "Service not found"
        read -p "Press Enter to continue..."
        return
    fi
    
    print_info "Stopping hidden service..."

    print_info "Stopping web servers..."
    
    APACHE_PIDS=$(pgrep -f "apache.*onionhoster" 2>/dev/null)
    if [ -n "$APACHE_PIDS" ]; then
        for pid in $APACHE_PIDS; do
            print_info "Stopping Apache server PID: $pid"
            kill $pid 2>/dev/null || true
        done
        print_status "Apache servers stopped"
    fi
    
    NGINX_PIDS=$(pgrep -f "nginx.*onionhoster" 2>/dev/null)
    if [ -n "$NGINX_PIDS" ]; then
        for pid in $NGINX_PIDS; do
            print_info "Stopping Nginx server PID: $pid"
            kill $pid 2>/dev/null || true
        done
        print_status "Nginx servers stopped"
    fi
    
    HTTP_PIDS=$(pgrep -f "python.*http.server\|python.*SimpleHTTPServer\|php.*-S\|node.*http.server" 2>/dev/null)
    if [ -n "$HTTP_PIDS" ]; then
        for pid in $HTTP_PIDS; do
            print_info "Stopping HTTP server PID: $pid"
            kill $pid 2>/dev/null || true
        done
        print_status "HTTP servers stopped"
    fi
    
    print_info "Cleaning up temporary files..."
    rm -f /tmp/apache_onionhoster_*.conf
    rm -f /tmp/apache_onionhoster_*.pid
    rm -f /tmp/nginx_onionhoster_*.conf
    rm -f /tmp/apache_error_*.log
    rm -f /tmp/apache_access_*.log
    rm -f /tmp/http_server.log
    rm -rf /tmp/nginx_*
    
    print_status "Web servers stopped and cleaned up"

    cleanup_torrc

    rm -rf "$SERVICE_PATH"

    if command -v systemctl &> /dev/null; then
        systemctl restart tor 2>/dev/null || true
    else
        BREW_PREFIX=$(brew --prefix 2>/dev/null)
        if [ -z "$BREW_PREFIX" ]; then
            BREW_PREFIX="/usr/local"
        fi
        TOR_USER="$SUDO_USER"
        if [ -z "$TOR_USER" ]; then
            TOR_USER=$(whoami)
        fi
        pkill -u "$TOR_USER" -x tor 2>/dev/null || true
        sleep 1
        rm -f /tmp/tor.log
        if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
            su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup tor --defaults-torrc $BREW_PREFIX/etc/tor/torrc > /tmp/tor.log 2>&1 &"
        else
            touch /tmp/tor.log
            nohup tor --defaults-torrc "$BREW_PREFIX/etc/tor/torrc" > /tmp/tor.log 2>&1 &
        fi
    fi

    print_status "Hidden service stopped and removed"
    read -p "Press Enter to continue..."
}

forward_port() {
    clear
    print_header
    echo -e "${CYAN}=== Forward the Port ===${NC}"
    
    if [ ! -d "$SERVICE_PATH" ]; then
        print_error "No hidden service found. Please host index.html first."
        read -p "Press Enter to continue..."
        return
    fi
    
    HOSTNAME_FILE="$SERVICE_PATH/hostname"
    if [ ! -f "$HOSTNAME_FILE" ]; then
        print_error "Hidden service not properly configured. Please host index.html first."
        read -p "Press Enter to continue..."
        return
    fi
    
    ONION_ADDR=$(cat "$HOSTNAME_FILE")
    echo -e "${GREEN}Current Onion Address:${NC} $ONION_ADDR"
    echo ""
    
    read -p "Enter port number where your application is running (e.g., 3000 for Next.js): " TARGET_PORT
    
    if [ -z "$TARGET_PORT" ]; then
        print_error "Port number is required"
        read -p "Press Enter to continue..."
        return
    fi
    
    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || [ "$TARGET_PORT" -lt 1 ] || [ "$TARGET_PORT" -gt 65535 ]; then
        print_error "Invalid port number. Must be between 1-65535"
        read -p "Press Enter to continue..."
        return
    fi
    
    print_info "Checking if port $TARGET_PORT is listening..."
    if command -v netstat &> /dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":$TARGET_PORT "; then
            print_status "Port $TARGET_PORT is listening"
        else
            print_warning "Port $TARGET_PORT is not listening"
            print_info "Make sure your application (Next.js, Flask, etc.) is running on port $TARGET_PORT"
            read -p "Press Enter to continue..."
            return
        fi
    elif command -v ss &> /dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":$TARGET_PORT "; then
            print_status "Port $TARGET_PORT is listening"
        else
            print_warning "Port $TARGET_PORT is not listening"
            print_info "Make sure your application (Next.js, Flask, etc.) is running on port $TARGET_PORT"
            read -p "Press Enter to continue..."
            return
        fi
    fi
    
    print_info "Forwarding Tor hidden service traffic to port $TARGET_PORT..."
    
    cleanup_torrc
    add_hidden_service_to_torrc "$TARGET_PORT"
    
    print_info "Restarting Tor service with new port forwarding..."
    if command -v systemctl &> /dev/null; then
        systemctl restart tor 2>/dev/null || {
            print_error "Failed to restart Tor service"
            read -p "Press Enter to continue..."
            return
        }
    else
        BREW_PREFIX=$(brew --prefix 2>/dev/null)
        if [ -z "$BREW_PREFIX" ]; then
            BREW_PREFIX="/usr/local"
        fi
        TOR_USER="$SUDO_USER"
        if [ -z "$TOR_USER" ]; then
            TOR_USER=$(whoami)
        fi

        pkill -u "$TOR_USER" -x tor 2>/dev/null || true
        sleep 1
        rm -f /tmp/tor.log
        if [ -f "$BREW_PREFIX/opt/tor/bin/tor" ]; then
            if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup $BREW_PREFIX/opt/tor/bin/tor --defaults-torrc $BREW_PREFIX/etc/tor/torrc > /tmp/tor.log 2>&1 &"
            else
                touch /tmp/tor.log
                nohup "$BREW_PREFIX/opt/tor/bin/tor" --defaults-torrc "$BREW_PREFIX/etc/tor/torrc" > /tmp/tor.log 2>&1 &
            fi
        else
            if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup tor --defaults-torrc $BREW_PREFIX/etc/tor/torrc > /tmp/tor.log 2>&1 &"
            else
                touch /tmp/tor.log
                nohup tor --defaults-torrc "$BREW_PREFIX/etc/tor/torrc" > /tmp/tor.log 2>&1 &
            fi
        fi
        sleep 3
    fi
    
    print_status "Port forwarding configured successfully!"
    echo ""
    echo -e "${GREEN}🔗 Onion Address: ${NC}$ONION_ADDR"
    echo -e "${GREEN}📍 Forwarding to Port: ${NC}$TARGET_PORT"
    echo -e "${GREEN}📁 Service Path: ${NC}$SERVICE_PATH"
    echo ""
    echo -e "${YELLOW}Your hidden service is now forwarding traffic to:${NC}"
    echo -e "${CYAN}http://localhost:$TARGET_PORT${NC}"
    echo ""
    echo -e "${YELLOW}Accessible via Tor at:${NC}"
    echo -e "${CYAN}http://$ONION_ADDR${NC}"
    echo ""
    echo -e "${GREEN}✓${NC} All traffic from the .onion address will now be forwarded to your application on port $TARGET_PORT"
    
    read -p "Press Enter to continue..."
}


backup_service() {
    clear
    print_header
    echo -e "${CYAN}=== Backup Tor Domain ===${NC}"
    
    if [ ! -d "$SERVICE_PATH" ]; then
        print_error "Service not found"
        read -p "Press Enter to continue..."
        return
    fi
    
    print_info "Backing up tor domain..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/my_hidden_service_$TIMESTAMP.zip"
    
    cd "$SERVICE_DIR"
    zip -r "$BACKUP_FILE" "$SERVICE_NAME"
    
    print_status "Tor domain backed up to: $BACKUP_FILE"
    read -p "Press Enter to continue..."
}


restore_service() {
    clear
    print_header
    echo -e "${CYAN}=== Restore Tor Domain ===${NC}"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "Backup directory not found"
        read -p "Press Enter to continue..."
        return
    fi
    
    BACKUP_FILES=($(ls "$BACKUP_DIR"/my_hidden_service_*.zip 2>/dev/null))
    
    if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
        print_error "No backup files found"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo "Available backup files:"
    for i in "${!BACKUP_FILES[@]}"; do
        echo "$((i+1)). $(basename "${BACKUP_FILES[$i]}")"
    done
    
    read -p "Select backup file to restore: " CHOICE
    
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#BACKUP_FILES[@]} ]; then
        BACKUP_FILE="${BACKUP_FILES[$((CHOICE-1))]}"
        print_info "Restoring from: $(basename "$BACKUP_FILE")"

        
        TEMP_DIR="/tmp/onion_restore_$$"
        mkdir -p "$TEMP_DIR"
        
        unzip -q "$BACKUP_FILE" -d "$TEMP_DIR"

        
        if [ -d "$TEMP_DIR" ]; then
            cp -r "$TEMP_DIR"/* "$SERVICE_DIR/"
            chown -R "$TOR_USER:$TOR_GROUP" "$SERVICE_DIR" 2>/dev/null || true
            chmod -R 700 "$SERVICE_DIR"

            if command -v systemctl &> /dev/null; then
                systemctl restart tor 2>/dev/null || true
            else
                BREW_PREFIX=$(brew --prefix 2>/dev/null)
                if [ -z "$BREW_PREFIX" ]; then
                    BREW_PREFIX="/usr/local"
                fi
                TOR_USER="$SUDO_USER"
                if [ -z "$TOR_USER" ]; then
                    TOR_USER=$(whoami)
                fi
                pkill -u "$TOR_USER" -x tor 2>/dev/null || true
                sleep 1
                rm -f /tmp/tor.log
                if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                    su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup tor --defaults-torrc $BREW_PREFIX/etc/tor/torrc > /tmp/tor.log 2>&1 &"
                else
                    touch /tmp/tor.log
                    nohup tor --defaults-torrc "$BREW_PREFIX/etc/tor/torrc" > /tmp/tor.log 2>&1 &
                fi
            fi

            print_status "Tor domain restored successfully"
        else
            print_error "Failed to extract backup"
        fi

        
        rm -rf "$TEMP_DIR"
    else
        print_error "Invalid choice"
    fi
    
    read -p "Press Enter to continue..."
}


check_web_server_status() {
    clear
    print_header
    echo -e "${CYAN}=== Web Server Status ===${NC}"
    
    echo ""
    echo -e "${YELLOW}Apache Servers:${NC}"
    APACHE_PIDS=$(pgrep -f "apache.*onionhoster" 2>/dev/null)
    if [ -n "$APACHE_PIDS" ]; then
        for pid in $APACHE_PIDS; do
            echo -e "  ${GREEN}✓${NC} Apache PID: $pid"
            PORT=$(grep -l "Listen.*$pid" /tmp/apache_onionhoster_*.conf 2>/dev/null | xargs grep "Listen" | awk '{print $2}')
            if [ -n "$PORT" ]; then
                echo -e "    Port: $PORT"
            fi
        done
    else
        echo -e "  ${RED}✗${NC} No Apache servers running"
    fi
    
    echo ""
    echo -e "${YELLOW}Nginx Servers:${NC}"
    NGINX_PIDS=$(pgrep -f "nginx.*onionhoster" 2>/dev/null)
    if [ -n "$NGINX_PIDS" ]; then
        for pid in $NGINX_PIDS; do
            echo -e "  ${GREEN}✓${NC} Nginx PID: $pid"
        done
    else
        echo -e "  ${RED}✗${NC} No Nginx servers running"
    fi
    
    echo ""
    echo -e "${YELLOW}Other HTTP Servers:${NC}"
    HTTP_PIDS=$(pgrep -f "python.*http.server\|python.*SimpleHTTPServer\|php.*-S\|node.*http.server" 2>/dev/null)
    if [ -n "$HTTP_PIDS" ]; then
        for pid in $HTTP_PIDS; do
            echo -e "  ${GREEN}✓${NC} HTTP Server PID: $pid"
        done
    else
        echo -e "  ${RED}✗${NC} No other HTTP servers running"
    fi
    
    echo ""
    echo -e "${YELLOW}Port Usage:${NC}"
    if command -v netstat &> /dev/null; then
        netstat -tlnp 2>/dev/null | grep -E ":(8000|9000|8080|3000|5000|4000)" | head -10
    elif command -v ss &> /dev/null; then
        ss -tlnp 2>/dev/null | grep -E ":(8000|9000|8080|3000|5000|4000)" | head -10
    fi
    
    echo ""
    echo -e "${YELLOW}Log Files:${NC}"
    if [ -f "/tmp/apache_error_*.log" ]; then
        echo "Apache error logs: /tmp/apache_error_*.log"
    fi
    if [ -f "/tmp/http_server.log" ]; then
        echo "HTTP server log: /tmp/http_server.log"
    fi
    
    read -p "Press Enter to continue..."
}

check_for_updates() {
    clear
    print_header
    echo -e "${CYAN}=== Check for Updates ===${NC}"
    
    print_info "Checking for updates from GitHub..."
    
    if ! command -v curl &> /dev/null; then
        print_error "curl is required to check for updates. Please install curl first."
        read -p "Press Enter to continue..."
        return
    fi

    
    print_info "Fetching latest script from GitHub..."
    TEMP_SCRIPT="/tmp/onionhoster_latest.sh"
    
    if curl -s -L "https://raw.githubusercontent.com/BlackHatDevX/onionhoster/refs/heads/master/onionhoster.sh" -o "$TEMP_SCRIPT" 2>/dev/null; then
        if [ -f "$TEMP_SCRIPT" ] && [ -s "$TEMP_SCRIPT" ]; then
            LATEST_VERSION=$(grep '^SCRIPT_VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2 2>/dev/null)
            
            if [ -z "$LATEST_VERSION" ]; then
                print_error "Failed to parse version from downloaded script"
                rm -f "$TEMP_SCRIPT"
                read -p "Press Enter to continue..."
                return
            fi
            
            print_info "Current version: $SCRIPT_VERSION"
            print_info "Latest version: $LATEST_VERSION"
            
            if [ "$SCRIPT_VERSION" = "$LATEST_VERSION" ]; then
                print_status "You are running the latest version!"
                rm -f "$TEMP_SCRIPT"
                read -p "Press Enter to continue..."
                return
            fi
            
            print_warning "Update available! Latest version: $LATEST_VERSION"
            echo ""
            read -p "Would you like to update now? (yes/no): " UPDATE_CONFIRM
            
            if [[ ! "$UPDATE_CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
                print_info "Update cancelled. You can update later."
                rm -f "$TEMP_SCRIPT"
                read -p "Press Enter to continue..."
                return
            fi
            
            print_info "Updating OnionHoster..."
            
            if cp "$TEMP_SCRIPT" "$SCRIPT_PATH"; then
                chmod +x "$SCRIPT_PATH"
                print_status "Script updated successfully!"
                echo ""
                echo -e "${GREEN}OnionHoster has been updated to version $LATEST_VERSION${NC}"
                echo -e "${YELLOW}The script will now restart to apply the update...${NC}"
                echo ""
                read -p "Press Enter to restart..."

                
                rm -f "$TEMP_SCRIPT"

                
                exec "$SCRIPT_PATH" "$@"
            else
                print_error "Failed to replace current script"
                print_info "Update failed. Please try again later."
                read -p "Press Enter to continue..."
            fi
        else
            print_error "Downloaded script is invalid or empty"
            read -p "Press Enter to continue..."
        fi
    else
        print_error "Failed to download latest script from GitHub"
        read -p "Press Enter to continue..."
    fi
    
    rm -f "$TEMP_SCRIPT"
}


refresh_tor_url() {
    clear
    print_header
    echo -e "${CYAN}=== Refresh Tor URL ===${NC}"
    
    if [ ! -d "$SERVICE_PATH" ]; then
        print_error "Service not found. Please start the service first."
        read -p "Press Enter to continue..."
        return
    fi
    
    HOSTNAME_FILE="$SERVICE_PATH/hostname"
    if [ -f "$HOSTNAME_FILE" ]; then
        OLD_ONION=$(cat "$HOSTNAME_FILE")
        echo -e "${YELLOW}Current Onion Address:${NC} $OLD_ONION"
        echo ""
        echo -e "${RED}⚠️  WARNING: ⚠️${NC}"
        echo "Refreshing the Tor URL will generate a NEW .onion address."
        echo "The OLD address will become INVALID and inaccessible."
        echo ""
        echo -e "${YELLOW}RECOMMENDED:${NC} Backup your current service before proceeding."
        echo ""
        read -p "Are you sure you want to continue? (yes/no): " CONFIRM
        
        if [[ ! "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
            print_info "Operation cancelled. Your current onion address is preserved."
            read -p "Press Enter to continue..."
            return
        fi

        
        echo ""
        read -p "Would you like to backup the current service first? (yes/no): " BACKUP_FIRST
        
        if [[ "$BACKUP_FIRST" =~ ^[Yy][Ee][Ss]$ ]]; then
            print_info "Creating backup of current service..."
            TIMESTAMP=$(date +%Y%m%d_%H%M%S)
            BACKUP_FILE="$BACKUP_DIR/my_hidden_service_before_refresh_$TIMESTAMP.zip"
            
            cd "$SERVICE_DIR"
            zip -r "$BACKUP_FILE" "$SERVICE_NAME"
            print_status "Backup created: $BACKUP_FILE"
            echo ""
        fi

        
        CURRENT_PORT=$(grep -A1 "HiddenServiceDir $SERVICE_PATH" "$TOR_CONFIG" 2>/dev/null | grep "HiddenServicePort" | awk '{print $2}' | cut -d':' -f2)
        if [ -z "$CURRENT_PORT" ]; then
            CURRENT_PORT=80  
        fi
        
        print_info "Refreshing Tor URL..."
        print_info "Using port: $CURRENT_PORT"
        
        print_info "Removing old service configuration..."
        rm -rf "$SERVICE_PATH"

        if command -v brew &> /dev/null; then
            BREW_PREFIX=$(brew --prefix 2>/dev/null)
            if [ -z "$BREW_PREFIX" ]; then
                BREW_PREFIX="/usr/local"
            fi
            TOR_USER="$SUDO_USER"
            if [ -z "$TOR_USER" ]; then
                TOR_USER=$(whoami)
            fi

            if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                su - "$SUDO_USER" -c "mkdir -p '$SERVICE_PATH' && chmod 700 '$SERVICE_PATH'"
            else
                mkdir -p "$SERVICE_PATH"
                chmod 700 "$SERVICE_PATH"
            fi
        else
            mkdir -p "$SERVICE_PATH"

            if command -v getent &> /dev/null; then
                TOR_USER_ID=$(getent passwd "$TOR_USER" | cut -d: -f3 2>/dev/null)
                TOR_GROUP_ID=$(getent group "$TOR_GROUP" | cut -d: -f3 2>/dev/null)

                if [ -n "$TOR_USER_ID" ] && [ -n "$TOR_GROUP_ID" ]; then
                    chown "$TOR_USER_ID:$TOR_GROUP_ID" "$SERVICE_PATH"
                    chmod 700 "$SERVICE_PATH"
                fi
            fi
        fi

        
        print_info "Restarting Tor service to generate new URL..."
        if command -v systemctl &> /dev/null; then
            systemctl restart tor 2>/dev/null || {
                print_error "Failed to restart Tor service"
                read -p "Press Enter to continue..."
                return
            }
        else
            BREW_PREFIX=$(brew --prefix 2>/dev/null)
            if [ -z "$BREW_PREFIX" ]; then
                BREW_PREFIX="/usr/local"
            fi
            TOR_USER="$SUDO_USER"
            if [ -z "$TOR_USER" ]; then
                TOR_USER=$(whoami)
            fi

            pkill -u "$TOR_USER" -x tor 2>/dev/null || true
            sleep 1
            rm -f /tmp/tor.log
            if [ -f "$BREW_PREFIX/opt/tor/bin/tor" ]; then
                if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                    su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup $BREW_PREFIX/opt/tor/bin/tor --defaults-torrc $BREW_PREFIX/etc/tor/torrc > /tmp/tor.log 2>&1 &"
                else
                    touch /tmp/tor.log
                    nohup "$BREW_PREFIX/opt/tor/bin/tor" --defaults-torrc "$BREW_PREFIX/etc/tor/torrc" > /tmp/tor.log 2>&1 &
                fi
            else
                if [[ $EUID -eq 0 ]] && [ -n "$SUDO_USER" ]; then
                    su - "$SUDO_USER" -c "touch /tmp/tor.log && nohup tor --defaults-torrc $BREW_PREFIX/etc/tor/torrc > /tmp/tor.log 2>&1 &"
                else
                    touch /tmp/tor.log
                    nohup tor --defaults-torrc "$BREW_PREFIX/etc/tor/torrc" > /tmp/tor.log 2>&1 &
                fi
            fi
            sleep 3
        fi

        
        print_info "Waiting for new hostname file to be generated..."

        
        MAX_WAIT=60
        WAIT_COUNT=0
        
        while [ ! -f "$HOSTNAME_FILE" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
            sleep 2
            WAIT_COUNT=$((WAIT_COUNT + 2))
            print_info "Waiting for new hostname file... ($WAIT_COUNT/$MAX_WAIT seconds)"
        done

        
        if [ -f "$HOSTNAME_FILE" ]; then
            NEW_ONION=$(cat "$HOSTNAME_FILE")
            print_status "Tor URL Refreshed Successfully!"
            echo ""
            echo -e "${RED}OLD Onion Address:${NC} $OLD_ONION (NO LONGER VALID)"
            echo -e "${GREEN}NEW Onion Address:${NC} $NEW_ONION"
            echo -e "${GREEN}📍 Port: ${NC}$CURRENT_PORT"
            echo -e "${GREEN}📁 Service Path: ${NC}$SERVICE_PATH"
            echo ""
            echo -e "${YELLOW}Note:${NC} Update your applications and bookmarks with the new address!"
        else
            print_error "Failed to generate new hostname file"
            print_error "Service may be in an inconsistent state"
        fi
        
    else
        print_error "No hostname file found. Service may not be properly configured."
    fi
    
    read -p "Press Enter to continue..."
}

view_current_link() {
    clear
    print_header
    echo -e "${CYAN}=== Current Tor Domain Status ===${NC}"
    
    if [ ! -d "$SERVICE_PATH" ]; then
        print_error "Service not found"
        read -p "Press Enter to continue..."
        return
    fi
    
    HOSTNAME_FILE="$SERVICE_PATH/hostname"
    
    if [ -f "$HOSTNAME_FILE" ]; then
        ONION_ADDR=$(cat "$HOSTNAME_FILE")
        print_status "Tor Domain is Active"
        echo -e "${GREEN}🔗 Onion Address: ${NC}$ONION_ADDR"
        echo -e "${GREEN}📁 Service Path: ${NC}$SERVICE_PATH"

        
        PORT=$(grep -A1 "HiddenServiceDir $SERVICE_PATH" "$TOR_CONFIG" 2>/dev/null | grep "HiddenServicePort" | awk '{print $2}' | cut -d':' -f2)
        if [ -n "$PORT" ]; then
            echo -e "${GREEN}📍 Port: ${NC}$PORT"
        fi
    else
        print_warning "Service directory exists but hostname file not found"
        print_info "Service might not be fully initialized"
    fi
    
    read -p "Press Enter to continue..."
}


show_about() {
    clear
    print_header
    echo -e "${CYAN}=== About OnionHoster ===${NC}"
    echo ""
    echo -e "${GREEN}Version:${NC} $SCRIPT_VERSION"
    echo -e "${GREEN}Description:${NC} OnionHoster - Tor Hidden Service Hosting Script"
    echo -e "${GREEN}Features:${NC}"
    echo "  • Works with any project (Next.js, Flask, static, etc.)"
    echo "  • Simple service management (start, stop, backup, restore)"
    echo "  • Single hidden service configuration"
    echo "  • Cross-platform support"
    echo ""
    echo -e "${GREEN}Supported OS:${NC} Debian/Ubuntu, CentOS/RHEL/Fedora, Arch Linux, macOS"
    echo ""
    echo -e "${YELLOW}Note:${NC} This script requires root privileges to manage Tor services"
    echo ""
    read -p "Press Enter to continue..."
}


show_menu() {
    clear
    print_header
    echo ""
    echo -e "${CYAN}Main Menu:${NC}"
    echo "1. Host index.html"
    echo "2. Forward to Application Port"
    echo "3. Backup tor domain"
    echo "4. Restore tor domain"
    echo "5. View current tor domain"
    echo "6. Refresh tor domain"
    echo "7. Check for updates"
    echo "8. Web Server Status"
    echo "9. About OnionHoster"
    echo "10. Exit"
    echo ""
    read -p "Select an option (1-10): " CHOICE
    
    case $CHOICE in
        1) start_service ;;
        2) forward_port ;;
        3) backup_service ;;
        4) restore_service ;;
        5) view_current_link ;;
        6) refresh_tor_url ;;
        7) check_for_updates ;;
        8) check_web_server_status ;;
        9) show_about ;;
        10) 
            print_info "Goodbye!"
            exit 0
            ;;
        *) 
            print_error "Invalid option. Please try again."
            sleep 2
            ;;
    esac
}


main() {
    check_root
    print_header
    print_info "Checking system requirements..."

    
    install_dependencies

    
    check_tor_service

    
    create_tor_config
    
    print_status "System ready! Starting menu..."
    sleep 2

    
    while true; do
        show_menu
    done
}


main "$@"
