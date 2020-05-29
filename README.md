# xhrm-back
自用Trojan一键搭建脚本
使用命令
curl -O https://raw.githubusercontent.com/xhrm/xhrm-back/master/trojan_mult.sh && chmod +x trojan_mult.sh && ./trojan_mult.sh
配置文件目录
/usr/src/trojan/
重启加载Trojan
systemctl restart trojan
开启NGINX服务
systemctl start nginx
BBR加速等
cd /usr/src && wget -N --no-check-certificate "https://raw.githubusercontent.com/dajiangfu/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
