#!/bin/bash

IPOP_HOME="/home/ubuntu/ipop"
IPOP_TINCAN="$IPOP_HOME/ipop-tincan"
IPOP_CONTROLLER="controller.Controller"
DEFAULTS_FILE="./scale_test_defaults.txt"
OVERRIDES_FILE="./auto_config_scale.txt"
TINCAN="./ipop-tincan"
CONTROLLER="./Controllers"
VISUALIZER="./Network-Visualizer"
DEFAULT_LXC_PACKAGES=$(cat $DEFAULTS_FILE 2>/dev/null | grep LXC_PACKAGES | cut -d ' ' -f 1 --complement)
DEFAULT_LXC_CONFIG=$(cat $DEFAULTS_FILE 2>/dev/null | grep LXC_CONFIG | awk '{print $2}')
DEFAULT_TINCAN_REPO=$(cat $DEFAULTS_FILE 2>/dev/null | grep TINCAN_REPO | awk '{print $2}')
DEFAULT_TINCAN_BRANCH=$(cat $DEFAULTS_FILE 2>/dev/null | grep TINCAN_REPO | awk '{print $3}')
DEFAULT_3RD_PARTY_REPO=$(cat $DEFAULTS_FILE 2>/dev/null | grep 3RD_PARTY_REPO | awk '{print $2}')
DEFAULT_3RD_PARTY_BRANCH=$(cat $DEFAULTS_FILE 2>/dev/null | grep 3RD_PARTY_REPO | awk '{print $3}')
DEFAULT_CONTROLLERS_REPO=$(cat $DEFAULTS_FILE 2>/dev/null | grep CONTROLLERS_REPO | awk '{print $2}')
DEFAULT_CONTROLLERS_BRANCH=$(cat $DEFAULTS_FILE 2>/dev/null | grep CONTROLLERS_REPO | awk '{print $3}')
DEFAULT_VISUALIZER_REPO=$(cat $DEFAULTS_FILE 2>/dev/null | grep VISUALIZER_REPO | awk '{print $2}')
DEFAULT_VISUALIZER_BRANCH=$(cat $DEFAULTS_FILE 2>/dev/null | grep VISUALIZER_REPO | awk '{print $3}')
DEFAULT_VISUALIZER_ENABLED=$(cat $DEFAULTS_FILE 2>/dev/null | grep VISUALIZER_ENABLED | awk '{print $2}')
OS_VERSION=$(lsb_release -r -s)
VPNMODE=$(cat $OVERRIDES_FILE 2>/dev/null | grep MODE | awk '{print $2}')
min=$(cat $OVERRIDES_FILE 2>/dev/null | grep MIN | awk '{print $2}')
max=$(cat $OVERRIDES_FILE 2>/dev/null | grep MAX | awk '{print $2}')
NET_TEST=$(ip route get 8.8.8.8)
NET_DEV=$(echo $NET_TEST | awk '{print $5}')
NET_IP4=$(echo $NET_TEST | awk '{print $7}')

function help()
{
    echo 'Enter from the following options:
    install-support-serv           : install critical services used in both, classic and switch modes
    prep-def-container             : prepare default container (what goes in depends on the mode)
    containers-create              : create and start containers
    containers-update              : restart containers adding IPOP src changes
    containers-start               : start stopped containers
    containers-stop                : stop containers
    containers-del                 : delete containers
    ipop-start                     : to start IPOP processes
    ipop-stop                      : to stop IPOP processes
    ipop-tests                     : open scale test shell to test ipop
    ipop-status                    : show statuses of IPOP processes
    visualizer-start               : install and start up visualizer
    visualizer-stop                : stop visualizer processes
    visualizer-status              : show statuses of visualizer processes
    logs                           : aggregate ipop logs under ./logs
    mode                           : show or change ipop mode to test
    help                           : show this menu
    quit                           : quit
    '
}

function setup-python
{
    #Python dependencies for visualizer and ipop python tests
    sudo apt-get install -y python3 python3-pip python3-lxc
    sudo pip3 install --upgrade pip
    sudo pip3 install pymongo sleekxmpp psutil
}

function setup-mongo
{
    sudo apt-get -y install mongodb
}

function setup-build-deps
{
    sudo apt install -y software-properties-common git make libssl-dev g++-5
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-5 10
}

function setup-base-container
{

    # Install lxc
    sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
    sudo apt-get update -y
    sudo apt-get -y install lxc

    # Install ubuntu OS in the lxc-container
    sudo lxc-create -n default -t ubuntu
    sudo chroot /var/lib/lxc/default/rootfs apt-get -y update
    sudo chroot /var/lib/lxc/default/rootfs apt-get -y install $DEFAULT_LXC_PACKAGES
    sudo chroot /var/lib/lxc/default/rootfs apt-get -y install software-properties-common python3-software-properties

    # install controller dependencies
    if [ $VPNMODE = "switch" ]; then
        sudo pip3 install sleekxmpp psutil requests
    else
        sudo chroot /var/lib/lxc/default/rootfs apt-get -y install python3-pip
        sudo chroot /var/lib/lxc/default/rootfs pip3 install sleekxmpp psutil requests
    fi

    config_grep=$(sudo grep "lxc.cgroup.devices.allow = c 10:200 rwm" "$DEFAULT_LXC_CONFIG")
    if [ -z "$config_grep" ]; then
        echo 'lxc.cgroup.devices.allow = c 10:200 rwm' | sudo tee --append $DEFAULT_LXC_CONFIG
    fi

}

function setup-ejabberd
{
    # Install local ejabberd server
    sudo apt-get -y install ejabberd
    echo "ejabberd has been installed!"
    echo "IMPORTANT!!! Please note that the default configuration file for ejabberd has an issue with
    a memory permission which prevents it from starting up successfully. Do you wish to replace the existing
    configuration file with the one we recommend? This will overwrite ALL your changes (if you have made any)."

    read -p "Replace ejabberd config with recommended one? [y/N] " replace_ejabberd_config
    if [[ $replace_ejabberd_config =~ [Yy](es)* ]]; then
        echo "Copying apparmor profile for ejabberdctl..."
        sudo cp ./config/usr.sbin.ejabberdctl /etc/apparmor.d/usr.sbin.ejabberdctl
        echo "Reloading apparmor profile for ejabberd..."
        sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.ejabberdctl
        echo "Done!"
    fi

    # prepare ejabberd server config file
    # restart ejabberd service
    if [ $OS_VERSION = '14.04' ]; then
        sudo cp ./config/ejabberd.cfg /etc/ejabberd/ejabberd.cfg
        sudo ejabberdctl restart
    else
        sudo apt-get -y install erlang-p1-stun
        sudo cp ./config/ejabberd.yml /etc/ejabberd/ejabberd.yml
        sudo systemctl restart ejabberd.service
    fi
    # Wait for ejabberd service to start
    sleep 15
    # Create admin user
    sudo ejabberdctl register admin ejabberd password
}

function setup-network
{
    # configure network
    #sudo iptables --flush
    read -p "Use symmetric NATS? (Y/n) " use_symmetric_nat
    if [[ $use_symmetric_nat =~ [Nn]([Oo])* ]]; then
        # replace symmetric NATs (MASQUERAGE) with full-cone NATs (SNAT)
        sudo iptables -t nat -A POSTROUTING -o $NET_DEV -j SNAT --to-source $NET_IP4
    #else
    #    sudo iptables -t nat -A POSTROUTING -o $NET_DEV -j MASQUERADE
    fi

    # open TCP ports (for ejabberd)
    for i in 5222 5269 5280; do
        sudo iptables -A INPUT -p tcp --dport $i -j ACCEPT
        sudo iptables -A OUTPUT -p tcp --dport $i -j ACCEPT
    done
    # open UDP ports (for STUN and TURN)
    for i in 3478 19302; do
        sudo iptables -A INPUT -p udp --sport $i -j ACCEPT
        sudo iptables -A OUTPUT -p udp --sport $i -j ACCEPT
    done
}

function setup-visualizer
{
    if ! [ -z $1 ]; then
        visualizer_repo=$1
    else
        visualizer_repo=$DEFAULT_VISUALIZER_REPO
    fi
    if ! [ -z $2 ]; then
        visualizer_branch=$2
    else
        visualizer_branch=$DEFAULT_VISUALIZER_BRANCH
    fi

    if ! [ -e $VISUALIZER ]; then
        if [ -z "$visualizer_repo" ]; then
            echo -e "\e[1;31mEnter visualizer github URL\e[0m"
            read visualizer_repo
        fi
        git clone $visualizer_repo
        if [ -z "$visualizer_branch" ]; then
           echo -e "Enter git repo branch name:"
           read visualizer_branch
        fi
        cd $VISUALIZER
        git checkout $visualizer_branch
        # Use visualizer setup script
        cd setup && ./setup.sh && cd ../..
    fi
}

function setup-tincan
{
    if [ -e $TINCAN ]; then
        echo "Using existing Tincan binary..."
    else
        if ! [ -e "./Tincan/trunk/build/" ]; then
            if [ -z "$DEFAULT_TINCAN_REPO" ]; then
                echo -e "\e[1;31mEnter github URL for Tincan\e[0m"
                read DEFAULT_TINCAN_REPO
                if [ -z "$DEFAULT_TINCAN_REPO" ] ; then
                    error "A Tincan repo URL is required"
                fi
            fi
            git clone $DEFAULT_TINCAN_REPO Tincan
            if [ -z $DEFAULT_TINCAN_BRANCH ]; then
                echo -e "Enter git repo branch name:"
                read DEFAULT_TINCAN_BRANCH
            fi
            cd Tincan
            git checkout $DEFAULT_TINCAN_BRANCH
            cd ..
        fi

        # Set up 3rd party dependencies for Ubuntu
        cd ./Tincan/external
        if [ -z "$DEFAULT_3RD_PARTY_REPO" ]; then
            echo -e "\e[1;31mEnter github URL for 3rd party Tincan dependencies\e[0m"
            read DEFAULT_3RD_PARTY_REPO
            if [ -z "$DEFAULT_3RD_PARTY_REPO" ] ; then
                error "A 3rd party dependencies repo URL is required"
            fi
        fi
        if [ -z $DEFAULT_3RD_PARTY_BRANCH ]; then
            echo -e "Enter 3rd party dependencies repo branch name:"
            read DEFAULT_3RD_PARTY_BRANCH
        fi
        git clone -b $DEFAULT_3RD_PARTY_BRANCH --single-branch $DEFAULT_3RD_PARTY_REPO

        cd ../trunk/build/
        echo "Building Tincan binary"
        make
        cd ../../..
        cp ./Tincan/trunk/out/release/x86_64/ipop-tincan .
    fi
}

function setup-controller
{
    if ! [ -e $CONTROLLER ]; then
        if [ -z "$DEFAULT_CONTROLLERS_REPO" ]; then
            echo -e "\e[1;31mEnter IPOP Controller github URL\e[0m"
            read DEFAULT_CONTROLLERS_REPO
            if [ -z "$DEFAULT_CONTROLLERS_REPO" ]; then
                error "A controller repo URL is required"
            fi
        fi
        git clone $DEFAULT_CONTROLLERS_REPO
        if [ -z $DEFAULT_CONTROLLERS_BRANCH ]; then
                echo -e "Enter git repo branch name:"
                read DEFAULT_CONTROLLERS_BRANCH
        fi
        cd Controllers
        git checkout $DEFAULT_CONTROLLERS_BRANCH
        cd ..
    else
        echo "Using existing Controller repo..."
    fi
}

function install-support-serv
{
    setup-python

    setup-mongo

    #configure iptables needed for proper network connectivity
    setup-network

    #Install and setup ejabberd with admin user
    setup-ejabberd

    setup-visualizer

    # In switch mode, this node needs to run the vswitch
    if [[ "$VPNMODE" = "switch" ]]; then
        sudo apt-get install -y openvswitch-switch
    fi
}

function prep-def-container
{
    # In classic mode, the containers run IPOP to form a vnet
    # amongst themselves. This machine only hosts the support services

    #Install dependencies required for building tincan
    setup-build-deps

    # Clone and build Tincan
    setup-tincan

    #Install dependencies required for building tincan
    setup-build-deps

    # Clone and build Tincan
    setup-tincan

    # Clone Controller
    setup-controller

    #Create default container that will be duplicated to create nodes
    setup-base-container
}

function containers-create
{
    # obtain network device and ip4 address
    NET_TEST=$(ip route get 8.8.8.8)
    NET_DEV=$(echo $NET_TEST | awk '{print $5}')
    NET_IP4=$(echo $NET_TEST | awk '{print $7}')

    MODELINE=$(cat $OVERRIDES_FILE | grep MODE)

    # function parameters
    if ! [ -z $1 ]; then
        container_count=$1
    fi
    if ! [ -z $2 ]; then
        visualizer_enabled=$2
    else
        visualizer_enabled=$DEFAULT_VISUALIZER_ENABLED
    fi

    if [ -z "$container_count" ]; then
        read -p "No of containers to be created: " max
    else
        max=$container_count
    fi
    min=1
    echo -e "MIN $min\nMAX $max" > $OVERRIDES_FILE
    echo $MODELINE >> $OVERRIDES_FILE



    if [ -z "$visualizer_enabled" ]; then
        echo -e "\e[1;31mEnable visualization? (Y/N): \e[0m"
        read visualizer_enabled
        if [[ "$visualizer_enabled" =~ [Yy](es)* ]]; then
            isvisual=true
        else
            isvisual=false
        fi
    else
        isvisual=$visualizer_enabled
    fi


    echo -e "\e[1;31mStarting containers. Please wait... \e[0m"
    if [[ "$VPNMODE" = "switch" ]]; then
        sudo mkdir -p /dev/net
        sudo rm /dev/net/tun
        sudo mknod /dev/net/tun c 10 200
        sudo chmod 0666 /dev/net/tun
        sudo chmod +x ./ipop-tincan
        sudo chmod +x ./node/node_config.sh
        sudo cp -r ./Controllers/controller/ ./

        sudo ./node/node_config.sh config 1 TUNNEL $NET_IP4 $isvisual
        sudo ejabberdctl register "node1" ejabberd password

        for i in $(seq $min $max); do
            sudo bash -c "
            lxc-copy -n default -N node$i;
            sudo lxc-start -n node$i --daemon;
            "
        done
    else
        # currently unused
        lxc_bridge_address="10.0.3.1"
        for i in $(seq $min $max); do
            sudo bash -c "
            lxc-copy -n default -N node$i;
            sudo lxc-start -n node$i --daemon;
            sudo lxc-attach -n node$i -- bash -c 'sudo mkdir -p $IPOP_HOME; sudo mkdir /dev/net; sudo mknod /dev/net/tun c 10 200; sudo chmod 0666 /dev/net/tun';
            "
            sudo cp -r ./Controllers/controller/ "/var/lib/lxc/node$i/rootfs$IPOP_HOME"
            sudo cp ./ipop-tincan "/var/lib/lxc/node$i/rootfs$IPOP_HOME"
            sudo cp './node/node_config.sh' "/var/lib/lxc/node$i/rootfs$IPOP_HOME"
            sudo lxc-attach -n node$i -- bash -c "sudo chmod +x $IPOP_TINCAN; sudo chmod +x $IPOP_HOME/node_config.sh;"
            sudo lxc-attach -n node$i -- bash -c "sudo $IPOP_HOME/node_config.sh config $i VNET $NET_IP4 $isvisual $lxc_bridge_address"
            echo "Container node$i started."
            sudo ejabberdctl register "node$i" ejabberd password
            for j in $(seq $min $max); do
                if [ "$i" != "$j" ]; then
                    sudo ejabberdctl add_rosteritem "node$i" ejabberd "node$j" ejabberd "node$j" ipop both
                fi
            done
        done
    fi
    #sudo rm -r Controllers
}

function containers-start
{
    echo -e "\e[1;31mStarting containers... \e[0m"
    for i in $(seq $min $max); do
        sudo bash -c "sudo lxc-start -n node$i --daemon;"
        echo "Container node$i started."
    done
}

function containers-del
{
    echo -e "\e[1;31mDeleting containers... \e[0m"
    for i in $(seq $min $max); do
        if [ $VPNMODE = "classic" ]; then
            for j in $(seq $min $max); do
                if [ "$i" != "$j" ]; then
                    sudo ejabberdctl delete_rosteritem "node$i" ejabberd "node$j" ejabberd
                fi
            done
            sudo ejabberdctl unregister "node$i" ejabberd
        fi
        sudo lxc-stop -n "node$i"
        sudo lxc-destroy -n "node$i"
    done
}

function containers-stop
{
    echo -e "\e[1;31mStopping containers... \e[0m"
    for i in $(seq $min $max); do
        sudo lxc-stop -n "node$i"
    done
}

function containers-update
{
    containers-stop
    for i in $(seq $min $max); do
        sudo bash -c "
        lxc-copy -n default -N node$i;
        sudo lxc-start -n node$i --daemon;
        sudo lxc-attach -n node$i -- bash -c 'sudo mkdir -p $IPOP_HOME; sudo mkdir /dev/net; sudo mknod /dev/net/tun c 10 200; sudo chmod 0666 /dev/net/tun';
        "
        sudo cp -r ./Controllers/controller/ "/var/lib/lxc/node$i/rootfs$IPOP_HOME"
        sudo cp ./ipop-tincan "/var/lib/lxc/node$i/rootfs$IPOP_HOME"
        sudo cp './node/node_config.sh' "/var/lib/lxc/node$i/rootfs$IPOP_HOME"
        sudo lxc-attach -n node$i -- bash -c "sudo chmod +x $IPOP_TINCAN; sudo chmod +x $IPOP_HOME/node_config.sh;"
        sudo lxc-attach -n node$i -- bash -c "sudo $IPOP_HOME/node_config.sh config $i GroupVPN $NET_IP4 $isvisual $topology_param containeruser password"
        echo "Container node$i started."
    done
}

function ipop-start
{
   container_to_run=$1

    if [ $VPNMODE = "switch" ]; then
        echo "Running ipop in switch-mode"
        sudo chmod 0666 /dev/net/tun
        mkdir -p logs/
        nohup sudo -b ./ipop-tincan &
        nohup sudo -b python3 -m controller.Controller -c ./node/ipop-config.json &
    else
        if [[ ! ( -z "$container_to_run" ) ]]; then
            if [ "$container_to_run" = '#' ]; then
                for i in $(seq $min $max); do
                    echo "Running node$i"
                    sudo lxc-attach -n "node$i" -- nohup bash -c "cd $IPOP_HOME && ./node_config.sh run"
                    sleep 0.5
                done
            else
                echo "Running node$container_to_run"
                sudo lxc-attach -n "node$container_to_run" -- nohup bash -c "cd $IPOP_HOME && ./node_config.sh run"
            fi
        else
            echo -e "\e[1;31mEnter # To RUN all containers or Enter the container number.  (e.g. Enter 1 to start node1)\e[0m"
            read user_input
            if [ $user_input = '#' ]; then
                for i in $(seq $min $max); do
                    echo "Running node$i"
                    sudo lxc-attach -n "node$i" -- nohup bash -c "cd $IPOP_HOME && ./node_config.sh run"
                    sleep 0.5
                done
            else
                echo "Running node$user_input"
                sudo lxc-attach -n "node$user_input" -- nohup bash -c "cd $IPOP_HOME && ./node_config.sh run"
            fi
        fi
    fi
}

function ipop-stop
{
    container_to_kill=$1
    # kill IPOP tincan and controller
    if [ $VPNMODE = "switch" ]; then
        sudo ./node/node_config.sh kill
    else
        if [[ ! ( -z "$container_to_kill" ) ]]; then
          if [ "$container_to_kill" = '#' ]; then
            for i in $(seq $min $max); do
                sudo lxc-attach -n node$i -- bash -c "sudo $IPOP_HOME/node_config.sh kill"
            done
          else
            sudo lxc-attach -n node$container_to_kill -- bash -c "sudo $IPOP_HOME/node_config.sh kill"
          fi
      else
        echo -e "\e[1;31mEnter # To KILL all containers or Enter the container number.  (e.g. Enter 1 to stop node1)\e[0m"
        read user_input
        if [ $user_input = '#' ]; then
            for i in $(seq $min $max); do
                sudo lxc-attach -n node$i -- bash -c "sudo $IPOP_HOME/node_config.sh kill"
            done
        else
            sudo lxc-attach -n node$user_input -- bash -c "sudo $IPOP_HOME/node_config.sh kill"
        fi
      fi
    fi
}

function visualizer-start
{
    cd $VISUALIZER && ./visualizer start && cd .. && echo "Visualizer started"
}

function visualizer-stop
{
    cd $VISUALIZER && ./visualizer stop && cd .. && echo "Visualizer stopped"
}

function visualizer-status
{
    visualizer_ps_result=$(ps aux | grep "[D]eploymentServer")

    if [ -n "$visualizer_ps_result" ] ; then
           echo 'Visualizer is UP'
    else
           echo 'Visualizer is Down'
    fi
}

function ipop-status
{
    for i in $(seq $min $max); do
        container_status=$(sudo lxc-ls --fancy | grep "node$i" | awk '{ print $2 }')
        if [ "$container_status" = 'RUNNING' ] ; then
            ctrl_process_status=$(sudo lxc-attach -n "node$i" -- bash -c 'ps aux | grep "[c]ontroller.Controller"')
            tin_process_status=$(sudo lxc-attach -n "node$i" -- bash -c 'ps aux | grep "[i]pop-tincan"')

            if [ -n "$ctrl_process_status" ]; then
                    ctrl_real_status="Controller is UP"
            else
                    ctrl_real_status="Controller is DOWN"
            fi

            if [ -n "$tin_process_status" ]; then
                    echo "$ctrl_real_status && Tincan is UP on node$i"
            else
                    echo "$ctrl_real_status && Tincan is DOWN on node$i"
            fi

        else
                echo -e "node$i is not running"
        fi
    done
}


function logs
{
    if [ $VPNMODE = "classic" ]; then
        for i in $(seq $min $max); do
               mkdir -p logs/"node$i"
               sudo lxc-info -n "node$i" > logs/"node$i"/container_status.txt
               container_status=$(sudo lxc-ls --fancy | grep "node$i" | awk '{ print $2 }')
                node_rootfs="/var/lib/lxc/node$i/rootfs"
                node_logs="$node_rootfs/home/ubuntu/ipop/logs/."
                core_file="$node_rootfs/home/ubuntu/ipop/core"

               if [ -e $core_file ] ; then
                   sudo cp $core_file ".logs/node$i"
               fi

               if [ "$container_status" = 'RUNNING' ] ; then
                   sudo cp -r $node_logs "./logs/node$i"
               else
                    echo "node$i is not running"
               fi
        done
    fi
    echo "View ./logs/ to see ctrl and tincan logs"
}

function check-vpn-mode
{
    if [ -z $VPNMODE ] ; then
        echo -e "Select vpn mode to test. Please input 1 for classic or 2 for switch."
        read VPNMODE_CODE
        while [ -z $VPNMODE_CODE ] || ([ "$VPNMODE_CODE" != "1" ] && [ "$VPNMODE_CODE" != "2" ]) ; do
            echo -e "Incorrect input. Please input 1 for classic or 2 for switch."
            read VPNMODE_CODE
        done

        if [ "$VPNMODE_CODE" == "1" ] ; then
            VPNMODE="classic"
        else
            VPNMODE="switch"
        fi
        echo "MODE $VPNMODE" >> $OVERRIDES_FILE
    fi
}
function configure-external-node
{
    username=$1
    hostname=$2
    xmpp_address=$3

    if [ -z "$username" ]; then
        read -p "Enter username: " username
    fi
    if [ -z "$hostname" ]; then
        read -p "Enter hostname: " hostname
    fi
    if [ -z "$xmpp_address" ]; then
        read -p "Enter xmpp server address: " xmpp_address
    fi

    scp ./external/external_setup.sh $username@$hostname:
    ssh "$username@$hostname" -t "sudo ./external_setup.sh $xmpp_address"
}

function ipop-tests
{
    sudo python3 ipoplxcutils/main.py
}

function mode
{
    action=$1
    current_vpn_mode=$(cat $OVERRIDES_FILE 2>/dev/null | grep MODE | awk '{print $2}')
    case $action in
        "change")
            if [[ "$current_vpn_mode" == "classic" ]]; then
                sed -i "s/MODE .*/MODE switch/g" $OVERRIDES_FILE
                echo "Mode changed to switch."
            else
                sed -i "s/MODE .*/MODE classic/g" $OVERRIDES_FILE
                echo "Mode changed to classic."
            fi
        ;;
        *)
            echo "Current mode: $current_vpn_mode"
        ;;
    esac
}

function mode-options
{
    echo -e "Options:\nshow -- view current mode\nchange -- switch between modes"
}

check-vpn-mode

$@

show_help=true
while true ; do
    if "$show_help" = true; then
        echo "$(help)"
    fi
    read -p "`echo $'\n> '`" user_input

    cmd=${user_input[0]}
    case $cmd in
        ("install-support-serv")
            install-support-serv
            show_help=true
        ;;
        ("prep-def-container")
            prep-def-container
            show_help=true
        ;;
        ("containers-create")
            containers-create
            show_help=true
        ;;
        ("containers-start")
            containers-start
            show_help=false
        ;;
        ("containers-del")
            containers-del
            show_help=false
        ;;
        ("containers-stop")
            containers-stop
            show_help=false
        ;;
        ("containers-update")
            containers-update
            show_help=true
        ;;
        ("ipop-start")
            ipop-start
            show_help=false
        ;;
        ("ipop-stop")
            ipop-stop
            show_help=false
        ;;
        ("ipop-status")
            ipop-status
            show_help=false
        ;;
        ("quit")
            exit 0
        ;;
        ("visualizer-start")
            visualizer-start
            show_help=false
        ;;
        ("visualizer-stop")
            visualizer-stop
            show_help=false
        ;;
        ("visualizer-status")
            visualizer-status
            show_help=false
        ;;
        ("ipop-tests")
            ipop-tests
            show_help=true
        ;;
        ("logs")
            logs
            show_help=false
        ;;
        ("mode")
            mode-options
            read -p "`echo $'mode> '`" action
            mode $action
            show_help=false
        ;;
        ("help")
            help
            show_help=false
        ;;
        *)
            echo -n "Please input a valid option."
            show_help=false
        ;;

    esac
    user_input=""
done
