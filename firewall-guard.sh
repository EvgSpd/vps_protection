#!/bin/bash
#
# Universal Server Protection Script
# Based on AntiZapret-VPN protection mechanisms
#
# Provides lightweight protection against:
# - Port scanning
# - DDoS attacks
# - SSH brute-force
# - Network reconnaissance
#
# Much lighter than fail2ban, uses iptables hashlimit module
#

#set -e

VERSION="1.0.0"
SCRIPT_NAME="FirewallGuard"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration file
CONFIG_FILE="/etc/firewall-guard/config"
WHITELIST_FILE="/etc/firewall-guard/whitelist.txt"

# Default configuration
PROTECTION_NAME="fwguard"
ENABLE_SCAN_PROTECTION=true
ENABLE_DDOS_PROTECTION=true
ENABLE_SSH_PROTECTION=true
ENABLE_STEALTH_MODE=true
ENABLE_IPV6=false

# Scan protection settings
SCAN_LIMIT=10              # Max different ports per hour
SCAN_BURST=10              # Burst allowance
SCAN_BLOCK_TIME=600        # Block for 10 minutes

# DDoS protection settings
DDOS_LIMIT=100000          # Max connections per hour
DDOS_BURST=100000          # Burst allowance
DDOS_BLOCK_TIME=600        # Block for 10 minutes

# SSH protection settings
SSH_LIMIT=3                # Max attempts per hour
SSH_BURST=3                # Burst allowance
SSH_BLOCK_TIME=60          # Block for 1 minute

# Network settings
DEFAULT_INTERFACE=""
SUBNET_MASK_V4=24          # Track by /24 subnet for IPv4
SUBNET_MASK_V6=64          # Track by /64 subnet for IPv6

print_colored() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
    ╔═══════════════════════════════════════════════════════╗
    ║                                                       ║
    ║              FirewallGuard Protection                ║
    ║                                                       ║
    ║     Lightweight Server Protection System             ║
    ║     Based on AntiZapret-VPN Architecture             ║
    ║                                                       ║
    ╚═══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "  Version: ${VERSION}"
    echo
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_colored "$RED" "Error: This script must be run as root!"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    
    for cmd in iptables ipset ip6tables; do
        if ! command -v $cmd &> /dev/null; then
            missing+=($cmd)
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_colored "$RED" "Error: Missing dependencies: ${missing[*]}"
        print_colored "$YELLOW" "Install with: apt install iptables ipset"
        exit 1
    fi
}

detect_interface() {
    if [[ -z "$DEFAULT_INTERFACE" ]]; then
        DEFAULT_INTERFACE=$(ip route get 1.2.3.4 2>/dev/null | awk '{print $5; exit}')
    fi
    
    if [[ -z "$DEFAULT_INTERFACE" ]]; then
        print_colored "$RED" "Error: Cannot detect default network interface!"
        exit 1
    fi
    
    print_colored "$GREEN" "✓ Network interface: $DEFAULT_INTERFACE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        print_colored "$GREEN" "✓ Configuration loaded from $CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$(dirname $CONFIG_FILE)"
    
    cat > "$CONFIG_FILE" << EOF
# FirewallGuard Configuration
# Generated: $(date)

PROTECTION_NAME="$PROTECTION_NAME"
ENABLE_SCAN_PROTECTION=$ENABLE_SCAN_PROTECTION
ENABLE_DDOS_PROTECTION=$ENABLE_DDOS_PROTECTION
ENABLE_SSH_PROTECTION=$ENABLE_SSH_PROTECTION
ENABLE_STEALTH_MODE=$ENABLE_STEALTH_MODE
ENABLE_IPV6=$ENABLE_IPV6

SCAN_LIMIT=$SCAN_LIMIT
SCAN_BURST=$SCAN_BURST
SCAN_BLOCK_TIME=$SCAN_BLOCK_TIME

DDOS_LIMIT=$DDOS_LIMIT
DDOS_BURST=$DDOS_BURST
DDOS_BLOCK_TIME=$DDOS_BLOCK_TIME

SSH_LIMIT=$SSH_LIMIT
SSH_BURST=$SSH_BURST
SSH_BLOCK_TIME=$SSH_BLOCK_TIME

DEFAULT_INTERFACE="$DEFAULT_INTERFACE"
SUBNET_MASK_V4=$SUBNET_MASK_V4
SUBNET_MASK_V6=$SUBNET_MASK_V6
EOF
    
    print_colored "$GREEN" "✓ Configuration saved to $CONFIG_FILE"
}

load_whitelist() {
    if [[ ! -f "$WHITELIST_FILE" ]]; then
        mkdir -p "$(dirname $WHITELIST_FILE)"
        cat > "$WHITELIST_FILE" << EOF
# FirewallGuard Whitelist
# Add trusted IP addresses or subnets here (one per line)
# Examples:
# 1.2.3.4
# 10.0.0.0/8
# 192.168.1.0/24

# Localhost
127.0.0.1
::1
EOF
    fi
}

apply_whitelist() {
    if [[ ! -f "$WHITELIST_FILE" ]]; then
        return
    fi
    
    # Create whitelist ipsets
    ipset create ${PROTECTION_NAME}-allow hash:net -exist
    ipset flush ${PROTECTION_NAME}-allow
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ipset create ${PROTECTION_NAME}-allow6 hash:net family inet6 -exist
        ipset flush ${PROTECTION_NAME}-allow6
    fi
    
    # Load whitelist
    local count=0
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Add to appropriate ipset
        if [[ "$line" =~ : ]]; then
            # IPv6
            if [[ "$ENABLE_IPV6" == "true" ]]; then
                ipset add ${PROTECTION_NAME}-allow6 "$line" 2>/dev/null && ((count++))
            fi
        else
            # IPv4
            ipset add ${PROTECTION_NAME}-allow "$line" 2>/dev/null && ((count++))
        fi
    done < "$WHITELIST_FILE"
    
    if [[ $count -gt 0 ]]; then
        print_colored "$GREEN" "✓ Loaded $count whitelisted IPs/subnets"
    fi
}

enable_protection() {
    print_colored "$BLUE" "Enabling server protection..."
    
    detect_interface
    load_whitelist
    apply_whitelist
    
    # Create ipsets for blocking
    ipset create ${PROTECTION_NAME}-block hash:ip timeout $SCAN_BLOCK_TIME -exist
    ipset create ${PROTECTION_NAME}-watch hash:ip,port timeout 60 -exist
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ipset create ${PROTECTION_NAME}-block6 hash:ip timeout $SCAN_BLOCK_TIME family inet6 -exist
        ipset create ${PROTECTION_NAME}-watch6 hash:ip,port timeout 60 family inet6 -exist
    fi
    
    # Connection tracking
    iptables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ip6tables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
    fi
    
    # Stealth mode
    if [[ "$ENABLE_STEALTH_MODE" == "true" ]]; then
        # Block ping
        iptables -w -I INPUT 2 -i "$DEFAULT_INTERFACE" -p icmp --icmp-type echo-request -j DROP 2>/dev/null || true
        
        # Hide RST packets
        iptables -w -I OUTPUT 2 -o "$DEFAULT_INTERFACE" -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || true
        
        # Hide ICMP unreachable
        iptables -w -I OUTPUT 3 -o "$DEFAULT_INTERFACE" -p icmp --icmp-type destination-unreachable -j DROP 2>/dev/null || true
        
        if [[ "$ENABLE_IPV6" == "true" ]]; then
            ip6tables -w -I INPUT 2 -i "$DEFAULT_INTERFACE" -p icmpv6 --icmpv6-type echo-request -j DROP 2>/dev/null || true
            ip6tables -w -I OUTPUT 2 -o "$DEFAULT_INTERFACE" -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || true
            ip6tables -w -I OUTPUT 3 -o "$DEFAULT_INTERFACE" -p icmpv6 --icmpv6-type destination-unreachable -j DROP 2>/dev/null || true
        fi
        
        print_colored "$GREEN" "✓ Stealth mode enabled"
    fi
    
    # Whitelist bypass
    iptables -w -I INPUT 3 -i "$DEFAULT_INTERFACE" -m set --match-set ${PROTECTION_NAME}-allow src -j ACCEPT 2>/dev/null || true
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ip6tables -w -I INPUT 3 -i "$DEFAULT_INTERFACE" -m set --match-set ${PROTECTION_NAME}-allow6 src -j ACCEPT 2>/dev/null || true
    fi
    
    # Port scan protection
    if [[ "$ENABLE_SCAN_PROTECTION" == "true" ]]; then
        # Track connections
        iptables -w -I INPUT 7 -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW \
            -j SET --add-set ${PROTECTION_NAME}-watch src,dst --exist 2>/dev/null || true
        
        # Detect port scanning (>10 different ports per hour from /24 subnet)
        iptables -w -I INPUT 4 -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW \
            -m set ! --match-set ${PROTECTION_NAME}-watch src,dst \
            -m hashlimit --hashlimit-above ${SCAN_LIMIT}/hour --hashlimit-burst ${SCAN_BURST} \
            --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V4} \
            --hashlimit-name ${PROTECTION_NAME}-scan --hashlimit-htable-expire 60000 \
            -j SET --add-set ${PROTECTION_NAME}-block src --exist 2>/dev/null || true
        
        if [[ "$ENABLE_IPV6" == "true" ]]; then
            ip6tables -w -I INPUT 7 -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW \
                -j SET --add-set ${PROTECTION_NAME}-watch6 src,dst --exist 2>/dev/null || true
            
            ip6tables -w -I INPUT 4 -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW \
                -m set ! --match-set ${PROTECTION_NAME}-watch6 src,dst \
                -m hashlimit --hashlimit-above ${SCAN_LIMIT}/hour --hashlimit-burst ${SCAN_BURST} \
                --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V6} \
                --hashlimit-name ${PROTECTION_NAME}-scan6 --hashlimit-htable-expire 60000 \
                -j SET --add-set ${PROTECTION_NAME}-block6 src --exist 2>/dev/null || true
        fi
        
        print_colored "$GREEN" "✓ Port scan protection enabled (limit: ${SCAN_LIMIT}/hour)"
    fi
    
    # DDoS protection
    if [[ "$ENABLE_DDOS_PROTECTION" == "true" ]]; then
        # Detect DDoS (>100k connections per hour from /24 subnet)
        iptables -w -I INPUT 5 -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW \
            -m hashlimit --hashlimit-above ${DDOS_LIMIT}/hour --hashlimit-burst ${DDOS_BURST} \
            --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V4} \
            --hashlimit-name ${PROTECTION_NAME}-ddos --hashlimit-htable-expire 10000 \
            -j SET --add-set ${PROTECTION_NAME}-block src --exist 2>/dev/null || true
        
        if [[ "$ENABLE_IPV6" == "true" ]]; then
            ip6tables -w -I INPUT 5 -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW \
                -m hashlimit --hashlimit-above ${DDOS_LIMIT}/hour --hashlimit-burst ${DDOS_BURST} \
                --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V6} \
                --hashlimit-name ${PROTECTION_NAME}-ddos6 --hashlimit-htable-expire 10000 \
                -j SET --add-set ${PROTECTION_NAME}-block6 src --exist 2>/dev/null || true
        fi
        
        print_colored "$GREEN" "✓ DDoS protection enabled (limit: ${DDOS_LIMIT}/hour)"
    fi
    
    # Drop blocked IPs
    iptables -w -I INPUT 6 -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW \
        -m set --match-set ${PROTECTION_NAME}-block src -j DROP 2>/dev/null || true
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ip6tables -w -I INPUT 6 -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW \
            -m set --match-set ${PROTECTION_NAME}-block6 src -j DROP 2>/dev/null || true
    fi
    
    # SSH protection
    if [[ "$ENABLE_SSH_PROTECTION" == "true" ]]; then
        iptables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW \
            -m hashlimit --hashlimit-above ${SSH_LIMIT}/hour --hashlimit-burst ${SSH_BURST} \
            --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V4} \
            --hashlimit-name ${PROTECTION_NAME}-ssh --hashlimit-htable-expire 60000 \
            -j DROP 2>/dev/null || true
        
        if [[ "$ENABLE_IPV6" == "true" ]]; then
            ip6tables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW \
                -m hashlimit --hashlimit-above ${SSH_LIMIT}/hour --hashlimit-burst ${SSH_BURST} \
                --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V6} \
                --hashlimit-name ${PROTECTION_NAME}-ssh6 --hashlimit-htable-expire 60000 \
                -j DROP 2>/dev/null || true
        fi
        
        print_colored "$GREEN" "✓ SSH brute-force protection enabled (limit: ${SSH_LIMIT}/hour)"
    fi
    
    save_config
    
    print_colored "$GREEN" "✓ Protection enabled successfully!"
}

disable_protection() {
    print_colored "$BLUE" "Disabling server protection..."
    
    detect_interface
    
    # Remove iptables rules
    iptables -w -D INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
    iptables -w -D INPUT -i "$DEFAULT_INTERFACE" -p icmp --icmp-type echo-request -j DROP 2>/dev/null || true
    iptables -w -D INPUT -i "$DEFAULT_INTERFACE" -m set --match-set ${PROTECTION_NAME}-allow src -j ACCEPT 2>/dev/null || true
    iptables -w -D INPUT -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW -m set ! --match-set ${PROTECTION_NAME}-watch src,dst -m hashlimit --hashlimit-above ${SCAN_LIMIT}/hour --hashlimit-burst ${SCAN_BURST} --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V4} --hashlimit-name ${PROTECTION_NAME}-scan --hashlimit-htable-expire 60000 -j SET --add-set ${PROTECTION_NAME}-block src --exist 2>/dev/null || true
    iptables -w -D INPUT -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW -m hashlimit --hashlimit-above ${DDOS_LIMIT}/hour --hashlimit-burst ${DDOS_BURST} --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V4} --hashlimit-name ${PROTECTION_NAME}-ddos --hashlimit-htable-expire 10000 -j SET --add-set ${PROTECTION_NAME}-block src --exist 2>/dev/null || true
    iptables -w -D INPUT -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW -m set --match-set ${PROTECTION_NAME}-block src -j DROP 2>/dev/null || true
    iptables -w -D INPUT -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW -j SET --add-set ${PROTECTION_NAME}-watch src,dst --exist 2>/dev/null || true
    iptables -w -D INPUT -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above ${SSH_LIMIT}/hour --hashlimit-burst ${SSH_BURST} --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V4} --hashlimit-name ${PROTECTION_NAME}-ssh --hashlimit-htable-expire 60000 -j DROP 2>/dev/null || true
    iptables -w -D OUTPUT -o "$DEFAULT_INTERFACE" -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables -w -D OUTPUT -o "$DEFAULT_INTERFACE" -p icmp --icmp-type destination-unreachable -j DROP 2>/dev/null || true
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ip6tables -w -D INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
        ip6tables -w -D INPUT -i "$DEFAULT_INTERFACE" -p icmpv6 --icmpv6-type echo-request -j DROP 2>/dev/null || true
        ip6tables -w -D INPUT -i "$DEFAULT_INTERFACE" -m set --match-set ${PROTECTION_NAME}-allow6 src -j ACCEPT 2>/dev/null || true
        ip6tables -w -D INPUT -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW -m set ! --match-set ${PROTECTION_NAME}-watch6 src,dst -m hashlimit --hashlimit-above ${SCAN_LIMIT}/hour --hashlimit-burst ${SCAN_BURST} --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V6} --hashlimit-name ${PROTECTION_NAME}-scan6 --hashlimit-htable-expire 60000 -j SET --add-set ${PROTECTION_NAME}-block6 src --exist 2>/dev/null || true
        ip6tables -w -D INPUT -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW -m hashlimit --hashlimit-above ${DDOS_LIMIT}/hour --hashlimit-burst ${DDOS_BURST} --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V6} --hashlimit-name ${PROTECTION_NAME}-ddos6 --hashlimit-htable-expire 10000 -j SET --add-set ${PROTECTION_NAME}-block6 src --exist 2>/dev/null || true
        ip6tables -w -D INPUT -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW -m set --match-set ${PROTECTION_NAME}-block6 src -j DROP 2>/dev/null || true
        ip6tables -w -D INPUT -i "$DEFAULT_INTERFACE" -m conntrack --ctstate NEW -j SET --add-set ${PROTECTION_NAME}-watch6 src,dst --exist 2>/dev/null || true
        ip6tables -w -D INPUT -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above ${SSH_LIMIT}/hour --hashlimit-burst ${SSH_BURST} --hashlimit-mode srcip --hashlimit-srcmask ${SUBNET_MASK_V6} --hashlimit-name ${PROTECTION_NAME}-ssh6 --hashlimit-htable-expire 60000 -j DROP 2>/dev/null || true
        ip6tables -w -D OUTPUT -o "$DEFAULT_INTERFACE" -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || true
        ip6tables -w -D OUTPUT -o "$DEFAULT_INTERFACE" -p icmpv6 --icmpv6-type destination-unreachable -j DROP 2>/dev/null || true
    fi
    
    # Destroy ipsets
    ipset destroy ${PROTECTION_NAME}-allow 2>/dev/null || true
    ipset destroy ${PROTECTION_NAME}-block 2>/dev/null || true
    ipset destroy ${PROTECTION_NAME}-watch 2>/dev/null || true
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ipset destroy ${PROTECTION_NAME}-allow6 2>/dev/null || true
        ipset destroy ${PROTECTION_NAME}-block6 2>/dev/null || true
        ipset destroy ${PROTECTION_NAME}-watch6 2>/dev/null || true
    fi
    
    print_colored "$GREEN" "✓ Protection disabled successfully!"
}

show_status() {
    print_colored "$BLUE" "=== FirewallGuard Status ==="
    echo
    
    # Check if protection is active
    if ipset list ${PROTECTION_NAME}-block &>/dev/null; then
        print_colored "$GREEN" "Status: ACTIVE"
    else
        print_colored "$YELLOW" "Status: INACTIVE"
        return
    fi
    
    echo
    print_colored "$BLUE" "=== Configuration ==="
    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE" | grep -v "^#" | grep -v "^$"
    else
        print_colored "$YELLOW" "No configuration file found"
    fi
    
    echo
    print_colored "$BLUE" "=== Blocked IPs (IPv4) ==="
    local blocked_count=$(ipset list ${PROTECTION_NAME}-block 2>/dev/null | grep -c "^[0-9]" || echo 0)
    echo "Total: $blocked_count"
    if [[ $blocked_count -gt 0 ]]; then
        echo "Last 10:"
        ipset list ${PROTECTION_NAME}-block | grep "^[0-9]" | tail -10
    fi
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        echo
        print_colored "$BLUE" "=== Blocked IPs (IPv6) ==="
        local blocked_count6=$(ipset list ${PROTECTION_NAME}-block6 2>/dev/null | grep -c ":" || echo 0)
        echo "Total: $blocked_count6"
        if [[ $blocked_count6 -gt 0 ]]; then
            echo "Last 10:"
            ipset list ${PROTECTION_NAME}-block6 | grep ":" | tail -10
        fi
    fi
    
    echo
    print_colored "$BLUE" "=== Whitelisted IPs/Subnets ==="
    local whitelist_count=$(ipset list ${PROTECTION_NAME}-allow 2>/dev/null | grep -c "^[0-9]" || echo 0)
    echo "Total: $whitelist_count"
    if [[ $whitelist_count -gt 0 ]]; then
        ipset list ${PROTECTION_NAME}-allow | grep "^[0-9]"
    fi
}

unblock_ip() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        print_colored "$RED" "Error: IP address required!"
        echo "Usage: $0 unblock <ip_address>"
        exit 1
    fi
    
    if [[ "$ip" =~ : ]]; then
        # IPv6
        ipset del ${PROTECTION_NAME}-block6 "$ip" 2>/dev/null && \
            print_colored "$GREEN" "✓ Unblocked: $ip" || \
            print_colored "$YELLOW" "IP not found in blocklist: $ip"
    else
        # IPv4
        ipset del ${PROTECTION_NAME}-block "$ip" 2>/dev/null && \
            print_colored "$GREEN" "✓ Unblocked: $ip" || \
            print_colored "$YELLOW" "IP not found in blocklist: $ip"
    fi
}

flush_blocked() {
    print_colored "$BLUE" "Flushing all blocked IPs..."
    
    ipset flush ${PROTECTION_NAME}-block 2>/dev/null || true
    
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ipset flush ${PROTECTION_NAME}-block6 2>/dev/null || true
    fi
    
    print_colored "$GREEN" "✓ All blocked IPs cleared!"
}

show_help() {
    cat << EOF
${BOLD}FirewallGuard - Universal Server Protection${NC}
Version: $VERSION

${BOLD}USAGE:${NC}
  $0 <command> [options]

${BOLD}COMMANDS:${NC}
  enable              Enable protection
  disable             Disable protection
  status              Show protection status
  unblock <ip>        Unblock specific IP address
  flush               Clear all blocked IPs
  whitelist           Edit whitelist file
  config              Edit configuration file
  help                Show this help

${BOLD}EXAMPLES:${NC}
  # Enable protection
  $0 enable

  # Check status
  $0 status

  # Unblock IP
  $0 unblock 1.2.3.4

  # Edit whitelist
  $0 whitelist

${BOLD}PROTECTION FEATURES:${NC}
  ✓ Port scan detection (>10 ports/hour → block 10 min)
  ✓ DDoS protection (>100k conn/hour → block 10 min)
  ✓ SSH brute-force protection (>3 attempts/hour → block 1 min)
  ✓ Stealth mode (hide ping, RST, ICMP unreachable)
  ✓ IP whitelist support
  ✓ IPv4 and IPv6 support

${BOLD}FILES:${NC}
  Config:     $CONFIG_FILE
  Whitelist:  $WHITELIST_FILE

${BOLD}COMPARISON WITH FAIL2BAN:${NC}
  FirewallGuard uses iptables hashlimit module directly
  - Lower CPU usage
  - Lower memory usage
  - Faster response time
  - No log parsing needed
  - Simpler configuration

EOF
}

# Main
main() {
    check_root
    check_dependencies
    load_config
    
    local command="${1:-help}"
    
    case "$command" in
        enable)
            print_banner
            enable_protection
            ;;
        disable)
            print_banner
            disable_protection
            ;;
        status)
            print_banner
            show_status
            ;;
        unblock)
            unblock_ip "$2"
            ;;
        flush)
            flush_blocked
            ;;
        whitelist)
            ${EDITOR:-nano} "$WHITELIST_FILE"
            print_colored "$YELLOW" "Run '$0 enable' to apply changes"
            ;;
        config)
            ${EDITOR:-nano} "$CONFIG_FILE"
            print_colored "$YELLOW" "Run '$0 enable' to apply changes"
            ;;
        help|--help|-h)
            print_banner
            show_help
            ;;
        *)
            print_colored "$RED" "Error: Unknown command: $command"
            echo
            show_help
            exit 1
            ;;
    esac
}

main "$@"
