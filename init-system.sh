#!/bin/bash
#脚本用来初始化系统环境，包括验证系统是否为Centos 7,内核版本是否支持overlay模块(没有的话无法安装启动docker)，内核版本建议3.10.0,安装必要软件以及docker的19.03.15版本
#设置主机名和网卡配置文件设置为DHCP自动获取IP
#用法: bash init-system.sh -n ${替换为租户名称} ，如果不用-n参数提供租户名称默认为default
#Author: Lancelot
#Date: August , 2023
set -eu
set -o noglob
set -o pipefail


info()
{
    echo -e '\e[32m[INFO]\e[0m ' "$@"
}
warn()
{
    echo -e '\e[1;33m[WARN]\e[0m ' "$@" >&2
}
fatal()
{
    echo -e '\e[1;31m[ERROR]\e[0m ' "$@" >&2
    exit 1
}

#验证系统是否是Centos7,CPU架构是否是X86_64
verify_system() {
    if [ -f /etc/os-release ];then
        OS_NAME=`cat /etc/os-release|grep ^NAME=|awk -F= '{print $2}'|sed 's/\"//g'`
        info "osname is $OS_NAME"
        if [ "${OS_NAME}" != "CentOS Linux" ];then
            fatal "$OS_NAME is not CentOS, please switch to CentOS"
        fi
        VERSION_ID=`cat /etc/os-release|grep ^VERSION_ID=|awk -F= '{print $2}'|sed 's/\"//g'`
        info "os version is $VERSION_ID"
        if [ "$VERSION_ID" -ne 7 ];then
            warn "CentOS is using VERSION $VERSION_ID, which not tested, better use Centos7"
        fi
        CPU_ARCH=`uname -m`
        if [ $CPU_ARCH != "x86_64" ];then
            fatal "CPU architecture is not x86_64,please use x86_64 cpu"
        fi
        if [ -x /bin/systemctl ] || type systemctl > /dev/null 2>&1; then
            info "systemctl exists"
        else
            fatal 'Can not find systemctl!'
        fi
    else
        fatal 'Can not find /etc/os-release to tell which Linux it is'
    fi
    
    if modprobe overlay;then
        info "overlay kernel module is added"
    else
        fatal "overlay kernel module can't be added, make sure $(uname -r) this kernel support overlay moudle"
    fi
}

init_system() {
    info "disable swap..."
    swapoff -a && if [ "`grep swap  /etc/fstab |grep -v "^#"`" != ""  ];then sed -ri 's/.*swap.*/#&/' /etc/fstab; fi
    info "add nf_conntrack module to kernel"
    echo  "nf_conntrack" > /etc/modules-load.d/k8s.conf
    echo "export TZ='Asia/Shanghai'" >> /etc/profile
    echo "ulimit -n 65535" >> /etc/profile
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1
vm.swappiness = 0
EOF
}

init_software() {
    info "init softeware..."
    yum install wget -y
    info "change yum repo to aliyun.."
    mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak$(date +%Y%m%d%H%M%S) || warn "file /etc/yum.repos.d/CentOS-Base.repo doesn't exist or can't be moved"
    wget -O /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
    sed -i -e '/mirrors.cloud.aliyuncs.com/d' -e '/mirrors.aliyuncs.com/d' /etc/yum.repos.d/CentOS-Base.repo
    yum makecache
    yum install -y vim nc bind-utils zip unzip curl tree lsof ethtool tcpdump pciutils chrony dstat tar bash-completion yum-utils net-tools lshw
    info "Stop and disable firewalld"
    systemctl stop firewalld
    systemctl disable firewalld
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
}

install_docker() {
    if rpm -q docker-ce >/dev/null 2>&1;then
        if [ `systemctl is-active docker` == "active" ];then
            warn "docker is already installed, remove all containers and docker..."
            docker kill $(docker ps -a -q) || info "no containers exist"
            docker rm -f $(docker ps -a -q) || info "no containers exist"
            docker rmi -f $(docker images -q) || info "no images exist"
            systemctl stop docker
        fi
        docker_version=`rpm -q --queryformat "%{VERSION}" docker-ce`
        if [ $docker_version != "19.03.15" ];then
            warn "remove docker $docker_version already installed"
            yum remove -y docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin docker-buildx-plugin containerd.io
            rm -rf /var/lib/docker
            rm -rf /etc/docker
            rm -rf /usr/bin/docker* /usr/bin/containerd*
        fi
    else
        info "docker-ce is not installed"
    fi
    yum install -y yum-utils
    # yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    info "install docker version 19.03.15"
    yum install -y docker-ce-19.03.15 docker-ce-cli-19.03.15 containerd.io
    mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF
{
    "oom-score-adjust": -1000,
    "exec-opts":["native.cgroupdriver=cgroupfs"],
    "log-driver": "json-file",
    "log-opts": {
    "max-size": "100m",
    "max-file": "3"
    },
    "max-concurrent-downloads": 10,
    "max-concurrent-uploads": 10,
    "insecure-registries": ["127.0.0.0/8"],
    "storage-driver": "overlay2",
    "storage-opts": [
    "overlay2.override_kernel_check=true"
    ]
}
EOF
    info "add docker container and image clean scripts"
cat > /etc/cron.weekly/docker-cleaner.sh << EOF
#!/bin/bash
docker container prune -f
docker image prune -a -f
exit 0
EOF
    chmod +x /etc/cron.weekly/docker-cleaner.sh
    systemctl start docker && info "docker is running " || warn "something wrong with docker,please check docker status"
    systemctl enable docker
    
}

#设置主机名称
init_hostname() {
    hostname_opt=""
    # 使用getopts解析长选项
    while getopts ":n:" opt; do
        case "$opt" in
            n)
                hostname_opt="$OPTARG"
            ;;
            \?)
                fatal "Invalid option -$OPTARG, usage bash init-system.sh -n \${replace with tenant name}"
            ;;
            :)
                fatal "option -$OPTARG requires a parameter"
            ;;
        esac
    done
    if [ ! -z $hostname_opt ];then
        if [[ "$hostname_opt" =~ ^[a-zA-Z0-9]{1,10}$ ]]; then
            info "Hostname custom part  $hostname_opt is valid"
            HOSTNAME_SELF=$hostname_opt
        else
            fatal "Hostname custom part \e[1;31m$hostname_opt\e[0m is invalid, please use ONLY LETTERS OR NUMBERS within 10 characters"
        fi
    else
        HOSTNAME_SELF="default"
    fi
    DATE=`date +%Y%m%d%H%M%S`
    RANDOM_STR=`cat /proc/sys/kernel/random/uuid  | md5sum |cut -c 1-6`
    HOSTNAME=matrix-$HOSTNAME_SELF-$DATE-$RANDOM_STR
    info "set HOSTNAME to $HOSTNAME"
    hostnamectl set-hostname $HOSTNAME
}

setup_network() {
    info "setup network scripts change network card to get ip address use dhcp..."
    systemctl disable network && info "network service has been disabled" || warn "disable network service failed"
    systemctl start NetworkManager && systemctl enable NetworkManager && info "NetworkManager has been started" || warn "NetworkManager failed,please check"
    nic_list=`lshw -class network -short|grep -E enp[0-9]s[0-9]|awk '{print $2}'`
    network_scripts_dir=/etc/sysconfig/network-scripts
    cd $network_scripts_dir
    for nic in $nic_list;do
        if [ -f "ifcfg-$nic" ];then
            info "backup old file $network_scripts_dir/ifcfg-$nic"
            cp $network_scripts_dir/ifcfg-$nic $network_scripts_dir/ifcfg-$nic.bak$(date +%Y%m%d%H%M%S)
            info "change config file $network_scripts_dir/ifcfg-$nic"
            sed -i '/^BOOTPROTO=/s/=.*$/=dhcp/' ifcfg-$nic
            sed -i '/^IPADDR=/s/^/#/' ifcfg-$nic
            sed -i '/^PREFIX=/s/^/#/' ifcfg-$nic
            sed -i '/^NETMASK=/s/^/#/' ifcfg-$nic
            sed -i '/^GATEWAY=/s/^/#/' ifcfg-$nic
            sed -i '/^ONBOOT=/s/=.*$/=yes/' ifcfg-$nic
            sed -i '/^DNS/s/^/#/' ifcfg-$nic
            echo "DNS1=114.114.114.114" >> ifcfg-$nic
        else
            info "$network_scripts_dir/ifcfg-$nic doesn't exist, create a default config for $nic"
cat > ifcfg-$nic << EOF
TYPE=Ethernet
PROXY_METHOD=none
BROWSER_ONLY=no
BOOTPROTO=dhcp
DEFROUTE=yes
IPV4_FAILURE_FATAL=no
NAME=$nic
DEVICE=$nic
ONBOOT=yes
EOF
        fi
    done
}

courter_to_reboot() {
    info "Starting reboot countdown..."
    countdown=$1
    while [ $countdown -gt 0 ]; do
        echo -ne "Sever will be reboot in \e[1;31m$countdown\e[0m seconds\033[0K\r"
        sleep 1
        ((countdown--))
    done
    
    warn "Time's up! Restarting the host..."
    reboot
}

{
    verify_system
    init_system
    init_software
    install_docker
    init_hostname "$@"
    setup_network
    courter_to_reboot 10
}