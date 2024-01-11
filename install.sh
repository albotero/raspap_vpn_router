#!/bin/bash

# Initializes a fresh raspbian OS system to be used
# either as the router or one of the access points

#########################################################
#                      Variables                        #
#########################################################

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
INSTALL_ROUTER=true

while getopts ":a:n:c:" option; do
    case $option in
        a) # Install software for access point
            INSTALL_ROUTER=false
            ;;
        n) # Install NordVPN
            INSTALL_NORDVPN=true
            ;;
        c) # Install Argon One Case script
            INSTALL_ARGON_CASE=true
            ;;
        \?) # Invalid option
            echo "Error: Invalid option"
            ;;
    esac
done

#########################################################
#                       Functions                       #
#########################################################

## From RaspAP
function _install_divider() {
    echo -e "\n\033[1;32m***************************************************************$*\033[m\n"
}
function _setup_colors() {
    ANSI_RED="\033[0;31m"
    ANSI_GREEN="\033[0;32m"
    ANSI_YELLOW="\033[0;33m"
    ANSI_RASPBERRY="\033[0;35m"
    ANSI_ERROR="\033[1;37;41m"
    ANSI_RESET="\033[m"
}
function _install_status() {
    case $1 in
        0)
            echo -e "[$ANSI_GREEN \U2713 ok $ANSI_RESET] $2"
            ;;
        1)
            echo -e "[$ANSI_RED \U2718 error $ANSI_RESET] $ANSI_ERROR $2 $ANSI_RESET"
            ;;
        2)
            echo -e "[$ANSI_YELLOW \U26A0 warning $ANSI_RESET] $2"
            ;;
        3)
            echo -e "[$ANSI_RASPBERRY ! important $ANSI_RESET] $2"
    esac
}
##

StepSelection() {
    log=$1
    func=$2
    arg=$3
    # Ask if user wants to retry, continue or exit
    if [ "$arg" == "optional" ] ; then
        read -p "Retry [r], skip [s] or exit [e]: " selection
        case $selection in
            r)
                Step $log $func $arg
                ;;
            s)
                return 0
                ;;
            e)
                exit 1
                ;;
            \?)
                echo "Invalid option. Try again."
                StepSelection $log $func $arg
                ;;
        esac
    else
        read -p "Retry [r], or exit [e]: " selection
        case $selection in
            r)
                Step $log $func $arg
                ;;
            e)
                exit 1
                ;;
            \?)
                echo "Invalid option. Try again."
                StepSelection $log $func $arg
                ;;
        esac
    fi
}

Step() {
    log=$1
    func=$2
    arg=$3
    # Output message
    _install_divider
    echo "$log"
    # Run the function and check for errors
    if [ "${!func}" == "0" ] ; then
        # No errors ocurred
        _install_status 0
    else
        _install_status 1 "What to do next?"
        StepSelection $log $func $arg
    fi
}

SetTTL() {
    echo "net.ipv4.ip_default_ttl = 128" | sudo tee -a /etc/sysctl.conf
}

CheckConnection() {
    ping -c 1 google.com
}

UpdateSystem() {
    sudo apt update -y
    sudo apt full-upgrade -y
}

ArgonOneScript() {
    chmod +x argon1.sh
    ./argon1.sh
    sudo tee /etc/argononed.conf <<EOF
#
# Argon Fan Configuration
#
# Min Temp=Fan Speed
53=10
55=25
60=55
65=100
EOF
}

RunAtBoot() {
    script=$1
    (crontab -l 2>/dev/null || true; echo "@reboot $SCRIPT_DIR/$1") | crontab -
}

InstallEasyTether() {
    # Install Driver
    sudo dpkg -i easytether_0.8.9_armhf.deb
    sudo apt install -f
    easytether-usb
    # Run tethercheck at boot
    chmod +x tethercheck
    RunAtBoot tethercheck
}

InstallNordVPN() {
    # Install NordVPN
    sudo dpkg -i nordvpn-release_1.0.0_all.deb
    sudo apt update
    sudo apt install nordvpn -y
    sudo usermod -aG nordvpn $USER
    cat nordvpn_token.txt | sudo nordvpn login --token `xargs`
    sudo nordvpn whitelist add port 22
    sudo nordvpn whitelist add port 80
    sudo nordvpn whitelist add port 443
    sudo nordvpn whitelist add ports 68 69 protocol UDP
    sudo nordvpn whitelist add subnet 10.7.141.0/24
    # Run script at boot
    chmod +x nordvpn_start
    RunAtBoot nordvpn_start
}

InstallWifiDongle() {
    sudo apt install -y git dnsmasq hostapd bc build-essential dkms raspberrypi-kernel-headers
    cd rtl88x2bu/
    sed -i 's/I386_PC = y/I386_PC = n/' Makefile
    sed -i 's/ARM_RPI = n/ARM_RPI = y/' Makefile
    VER=$(sed -n 's/\PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
    sudo rsync -rvhP ./ /usr/src/rtl88x2bu-${VER}
    sudo dkms add -m rtl88x2bu -v ${VER}
    sudo dkms build -m rtl88x2bu -v ${VER} # Takes ~3-minutes on a 3B+
    sudo dkms install -m rtl88x2bu -v ${VER}
    cd ..
}

SetTxPower() {
    # Set txpower 30 dBm at boot
    chmod +x set_txpower
    RunAtBoot set_txpower
}

InstallRaspAP() {
    chmod +x raspap.sh
    ./raspap.sh --yes --openvpn 0 --adblock 0 --wireguard 0
}

ConfigureRaspAP_Router() {
    sudo tee /etc/dhcpcd.conf <<EOF
# RaspAP default configuration
hostname
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, host_name
option classless_static_routes
option ntp_servers
require dhcp_server_identifier
slaac private
nohook lookup-hostname

# RaspAP eth0 configuration
interface eth0
static ip_address=10.7.141.1/24
static routers=10.7.141.1
static domain_name_server=103.86.96.100 103.86.99.100
metric 105
EOF

    echo "DNSStubListener=no" | sudo tee -a /etc/systemd/resolved.conf
}

ConfigureRaspAP_AP() {
    sudo tee /etc/hostapd/hostapd.conf <<EOF
driver=nl80211
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
auth_algs=1
wpa_key_mgmt=WPA-PSK
beacon_int=100
ssid=CasaP_Rpi
channel=149
hw_mode=a

# N
ieee80211n=1
require_ht=1
ht_capab=[MAX-AMSDU-3839][HT40+][SHORT-GI-20][SHORT-GI-40][DSSS_CCK-40]

# AC
ieee80211ac=1
require_vht=1
ieee80211d=0
ieee80211h=0
vht_capab=[MAX-AMSDU-3839][SHORT-GI-80]
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=155

wpa_passphrase=20082021
interface=wlan1
bridge=br0
wpa=2
wpa_pairwise=CCMP
country_code=CO
ignore_broadcast_ssid=0
EOF

    sudo tee /etc/dhcpcd.conf <<EOF
# RaspAP default configuration
hostname
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, host_name
option classless_static_routes
option ntp_servers
require dhcp_server_identifier
slaac private
nohook lookup-hostname

# RaspAP br0 configuration
denyinterfaces eth0 wlan0
interface br0
EOF

}

#########################################################
#                Install the software                   #
#########################################################

Step "Set TTL to avoid throttling" SetTTL optional
Step "Checking internet connection" CheckConnection
Step "Updating the system" UpdateSystem optional

if $INSTALL_ARGON_CASE then; do
    Step "Installing Argon One case script" ArgonOneScript optional
fi

if $INSTALL_ROUTER then ; do
    # Router
    Step "Installing EasyTether driver" InstallEasyTether optional
    if $INSTALL_NORDVPN then ; do
        Step "Installing NordVPN" InstallNordVPN optional
    fi
else
    # Access point
    Step "Installing USB Wifi Dongle" InstallWifiDongle optional
    Step "Set TxPower to 30 dBm" SetTxPower optional
fi

Step "Installing RaspAP" InstallRaspAP
if $INSTALL_ROUTER then ; do
    Step "Configuring RaspAP" ConfigureRaspAP_Router
else
    Step "Configuring RaspAP" ConfigureRaspAP_AP
fi

#########################################################
#                        Finish                         #
#########################################################

_install_divider
echo "Installation finished."
read "Do you want to reboot now? y/n" res_reboot
case $res_reboot in
    y|Y)
        sudo reboot
        ;;
    \?)
        exit
        ;;
esac