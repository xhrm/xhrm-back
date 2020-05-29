# xhrm-back
自用Trojan一键搭建脚本</br>
使用命令</br>
curl -O https://raw.githubusercontent.com/xhrm/xhrm-back/master/trojan_mult.sh && chmod +x trojan_mult.sh && ./trojan_mult.sh</br>
配置文件目录</br>
/usr/src/trojan/</br>
重启加载Trojan</br>
systemctl restart trojan</br>
开启NGINX服务</br>
systemctl start nginx</br>
BBR加速等</br>
cd /usr/src && wget -N --no-check-certificate "https://raw.githubusercontent.com/dajiangfu/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
