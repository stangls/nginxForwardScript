nginxForwardScript
==================

Automatic generation of reverse-proxy configurations for complex clusters of web-servers.
The basic idea is to reverse-proxy single domains to a bunch of backend VMs while making use of nginx build in loadbalancing mechanisms.

Probably works on debian only!!!


Usage:
* for complete automation copy everything to /etc/nginx
  * if you don't want to do this, you can also symlink manually from another dir to sites-available
  * if you don't know what you are doing, then don't do it
* look at the example configuration in loadbalancing/example.de
  * the comments in the example should be self-explaining. if not, feel free to tell me.
  * adapt to your needs or create more configs in the loadbalancing directory
* execute ./generateNginxConfigsForLoadbalancing.sh
* take a look at the generated sites-available

If you want to use HTTP-authentication, you may want to install htpasswd from the apache2-utils package, or change the way the htpasswd_* files are created in the script.
