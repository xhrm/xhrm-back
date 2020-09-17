# xhrm-back
自用Trojan一键搭建脚本</br></br>

使用命令</br></br>
curl -O https://raw.githubusercontent.com/xhrm/xhrm-back/master/trojan_mult.sh && chmod +x trojan_mult.sh && ./trojan_mult.sh</br></br>
配置文件目录</br></br>
/usr/src/trojan/</br></br>
重启加载Trojan</br></br>
systemctl restart trojan</br></br>
开启NGINX服务</br></br>
systemctl start nginx</br></br>
BBR加速等</br></br>
cd /usr/src && wget -N --no-check-certificate "https://raw.githubusercontent.com/dajiangfu/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh</br>
