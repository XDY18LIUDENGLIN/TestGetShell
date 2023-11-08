#!/bin/bash
#此脚本用来将边缘节点加入云端集群
#用法：bash kubeedge-add-node.sh -c ${替换为云端的控制IP和端口} -t ${替换为加入集群所需token}
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

# 检查IP和端口的有效性和联通性
check_ip_port() {
    ip_port="$1"
    ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    port_regex='^[0-9]+$'
    
    ip=$(echo "$ip_port" | cut -d':' -f1)
    port=$(echo "$ip_port" | cut -d':' -f2)
    info "Input ip is $ip"
    info "Input port is $port"
    
    if [[ ! "$ip" =~ $ip_regex ]]; then
        fatal "$ip is an invalid IP address"
    fi
    
    
    if [[ ! "$port" =~ $port_regex || "$port" -lt 1 || "$port" -gt 65535 ]]; then
        fatal "$port is an invalid port number"
    fi
    
    if nc -z "$ip" "$port"; then
        info "$ip_port is valid and reachable"
    else
        fatal "$ip_port is not reachable, please check network!"
    fi
}

# 定义函数来处理长参数
init_edgecore() {
    # 初始化变量
    cloudcore_ipport=""
    token=""
    
    # 使用getopts解析长选项
    while getopts ":c:t:" opt; do
        case "$opt" in
            c)
                cloudcore_ipport="$OPTARG"
            ;;
            t)
                token="$OPTARG"
            ;;
            \?)
                fatal "Invalid option -$OPTARG"
            ;;
            :)
                fatal "option -$OPTARG requires a parameter"
            ;;
        esac
    done
    
    # 输出选项的值
    info "CloudCore IP/Port: $cloudcore_ipport"
    info "Token: $token"
    if [ -z $cloudcore_ipport ];then
        fatal "cloudcore_ipport can not be empty, usage bash kubeedge-add-node.sh -c \${replace with cloudcore_ipport} -t \${replace with token}"
        elif [ -z $token ];then
        fatal "token can not be empty, usage bash kubeedge-add-node.sh -c \${replace with cloudcore_ipport} -t \${replace with token}"
    fi
    
    check_ip_port $cloudcore_ipport
    
    #判断是否存在keadm
    if [ -z `command -v keadm` ];then
        if [ ! -f keadm-v1.12.1-linux-amd64.tar.gz ];then
            info "keadm does not exist, download from github"
            wget https://github.com/kubeedge/kubeedge/releases/download/v1.12.1/keadm-v1.12.1-linux-amd64.tar.gz
        fi
        tar -zxf keadm-v1.12.1-linux-amd64.tar.gz
        cp keadm-v1.12.1-linux-amd64/keadm/keadm /usr/local/bin/
    else
        info "keadm already exist"
    fi
    
    if [ -f edge_image.tar.gz -a `systemctl is-active docker` == "active" ];then
        info "load image from edge_image.tar.gz"
        tar -zxf edge_image.tar.gz
        docker load -i edge_image.tar
    fi
    HOSTNAME=`hostname`
    info "keadm join --cloudcore-ipport=$cloudcore_ipport --token=$token --runtimetype=docker --remote-runtime-endpoint=unix:///var/run/dockershim.sock --edgenode-name=$HOSTNAME --kubeedge-version=v1.12.1 --cgroupdriver=cgroupfs"
    keadm join --cloudcore-ipport=$cloudcore_ipport --token=$token --runtimetype=docker --remote-runtime-endpoint=unix:///var/run/dockershim.sock --edgenode-name=$HOSTNAME --kubeedge-version=v1.12.1 --cgroupdriver=cgroupfs
}

config_edgecore() {
    if [ -z `command -v yq` ];then
        if [ ! -f yq_linux_amd64.tar.gz ]; then
            info "yq does not exist, download from github"
            wget https://github.com/mikefarah/yq/releases/download/v4.34.2/yq_linux_amd64.tar.gz
        fi
        tar -zxf yq_linux_amd64.tar.gz
        cp yq_linux_amd64 /usr/local/bin/yq
        sh install-man-page.sh
    else
        info "yq command already exist"
    fi
    
    
    if [ -f /etc/kubeedge/config/edgecore.yaml ];then
        info "use yq command to modify /etc/kubeedge/config/edgecore.yaml"
        yq -i '
            .modules.edgeStream.enable = true |
            .modules.metaManager.metaServer.enable = true |
            .modules.metaManager.metaServer.server = "0.0.0.0:10550" |
            .modules.serviceBus.server = "0.0.0.0"|
            .modules.edged.tailoredKubeletConfig.clusterDomain = "cluster.local" |
            .modules.edged.tailoredKubeletConfig.clusterDNS[0] = "169.254.96.16"
        ' /etc/kubeedge/config/edgecore.yaml
        info "restart edgecore..."
        systemctl restart edgecore && info "edgecore has been successfully restarted" || warn "something wrong with edgecore, please check edgecore status"
        info "restart docker..."
        systemctl restart docker && info "docker has been successfully restarted" || warn "something wrong with docker, please check docker status"
        info "work is done,please check edgecore and docker are running, and this edgenode is under cloud k8s cluster"
        # sleep 5
        # systemctl status docker && info "docker is running" || warn "something wrong with docker, please check docker status"
        # systemctl status edgecore && info "edgecore is running" || warn "something wrong with edgecore, please check edgecore status"
    else
        fatal "edgecore configfile /etc/kubeedge/config/edgecore.yaml does not exist, be sure edgecore is installed and running"
    fi
}

{
    # 调用函数来处理参数
    init_edgecore "$@"
    config_edgecore
}

