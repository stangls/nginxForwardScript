#!/bin/bash

# this script generates a bunch of sites in sites_enabled and links them from sites_available
# corresponding to the configs in the directory "loadbalancing"
#
# afterwards it tests the configuration if possible ( works on debian/ubuntu as root ), but will not restart nginx.
# you have to do that yourself.
#
# the following prefix will be used for the filenames, all files matching this prefix will be deleted first.

prefix="loadbalancing_"


# start of script

dir=`dirname $0`
cd "$dir"
if ! [ -f "`basename $0`" ]; then
	echo "ERROR: can not find myself in $dir".
	exit 1
fi
if ! [ -d "loadbalancing" ]; then
	echo "ERROR: can not find directory "loadbalancing" in $dir".
	exit 1
fi

rm sites-enabled/${prefix}*
rm sites-available/${prefix}*
mkdir -p logins
rm logins/*

names=""
defaultSet=""

for i in loadbalancing/*; do

	# skip non-files
	[ -f "$i" ] || continue;

	# reset config
	name=""; domains=""
	default=false
	backendsHttp=""; backendsHttps=""
    backendsHttpFallback=""; backendsHttpsFallback=""
	forwardHttp2Https=false; forwardHttps2Http=false
    forwardHttp=""; forwardHttps="";
	httpsInternalHttp=false
    enableFallback=false
    fallbackErrorCodes=""
	login=""; password=""; authFile=""
	disabled=""; staticSite=""

	# read config
	. "$i"

	if [ -n "$disabled" ]; then
		continue;
	fi

	# check sanity
	if [ "$name" = "" ]; then
		echo "ERROR: no name specfied for $i. skipping ... "
		continue;
	fi
	if echo "$names" | grep "^$name "; then
		echo "ERROR: duplicate name $name in $i. skipping ..."
		continue;
	fi
	names=$(echo "$names";echo "$name already defined in $i")
	if $default; then
		if [ -n "$defaultSet" ]; then
			echo "ERROR: default server already set as "$defaultSet". skipping $i ..."
			continue;
		else
			defaultSet="$name"
		fi
	fi
	if [ "$domains" = "" ]; then
		echo "ERROR: no domains specfied for $name. skipping $i"
		continue;
	fi
    if ( ( [ "$backendsHttp" = "" ] && [ "$forwardHttp" = "" ] ) || $forwardHttp2Https ) && ( ( [ "$backendsHttps" = "" ] && [ "$forwardHttps" = "" ] ) || $forwardHttps2Http ); then
		echo "ERROR: neither http or https backend for $name. what do you actually want? skipping $i ..." 
		continue;
	fi
	if $forwardHttp2Https && $forwardHttps2Http; then
		echo "ERROR: both forward http⇒https and https⇒http enabled. are you crazy?? skipping $i ..." 
		continue;
	fi
    if $forwardHttp2Https && [ "$forwardHttp" != "" ]; then
        echo "ERROR: you have forwardHttp2Https and forwardHttp enabled. Not sure what to do... skipping $i ..."
        continue;
    fi
    if $forwardHttps2Http && [ "$forwardHttps" != "" ]; then
        echo "ERROR: you have forwardHttps2Http and forwardHttps enabled. Not sure what to do... skipping $i ..."
        continue;
    fi
    if $default && [ "$forwardHttps" != "" ]; then
        echo "ERROR: sorry, but wildcard forwarding doesn't work with ssl... skipping $i ..."
        continue;
    fi
    if $enableFallback && [ "$fallbackErrorCodes" = "" ]; then
        echo "ERROR: Fallback is enabled but no error codes for fallback are defined. skipping $i ..."
        continue;
    fi
    if $enableFallback && ( ( [ "$backendsHttp" != "" ] && [ "$backendsHttpFallback" = "" ] ) || ( [ "$backendsHttps" != "" ] && [ "$backendsHttpsFallback" = "" ] ) ); then
        echo "ERROR: Fallback is enabled but not all required backends are configured. skipping $i ..."
        continue;
    fi

	if [ -n "$login" ]; then
		# generate authontication-file (htpasswd) for HTTP basic authentication
		authFile=`pwd`/logins/htpasswd_$name
		htpasswd -nb $login $password >> $authFile
	fi

	# generate nginx config file
	fname="$prefix$name"
	echo "generating config file for $name ..."

	{
		# http part
		if [ -n "$backendsHttp" ]; then
			echo "
				upstream upstream_$name {
					# send requests from single ips to a single backend server
					ip_hash;
					# backends"
			echo -n "$backendsHttp" | sed 's/\(\S*\)/\1\n/g' | sed 's/\*/ /' | { while read backend weight; do
				add=""
				if [ -n "$weight" ]; then
					if echo "$weight" | grep -q '[0-9]*'; then
						add="$add	weight=$weight"
					else
						echo "WARNING: weight for backend $backend is $weight (non-numeric). No weight applied!"
					fi
				fi
				echo "					server $backend$add;"
			done; }
            if [ -n "$backendsHttpFallback" ]; then
			    echo "                }
			    upstream upstream_${name}_fallback {
			    	# send requests from single ips to a single backend server
			    	ip_hash;
			    	# backends"
			    echo -n "$backendsHttpFallback" | sed 's/\(\S*\)/\1\n/g' | sed 's/\*/ /' | { while read backend weight; do
			    	add=""
			    	if [ -n "$weight" ]; then
			    		if echo "$weight" | grep -q '[0-9]*'; then
			    			add="$add	weight=$weight"
			    		else
			    			echo "WARNING: weight for backend $backend is $weight (non-numeric). No weight applied!"
			    		fi
			    	fi
			    	echo "					server $backend$add;"
			    done; }
            fi
			echo "
				}
				server {
					listen 80"$( $default && echo ' default_server default' )";
					server_name $domains;
					access_log  /var/log/nginx/access_$fname.log;
					error_log  /var/log/nginx/error_$fname.log;"
            if $enableFallback; then
                echo "                    recursive_error_pages on;
                    proxy_intercept_errors on;"
            fi
			if [ -n "$staticSite" ]; then
				echo "
					location / {
						root /etc/nginx/loadbalancing/static;
						try_files \$uri /$staticSite;"
				if [ -n "$authFile" ]; then
					echo "					auth_basic \"Please authenticate for $name\";"
					echo "					auth_basic_user_file	$authFile;"
				fi
				echo "
					}
					location = /$staticSite {"
				if [ -n "$authFile" ]; then
					echo "					auth_basic \"Please authenticate for $name\";"
					echo "					auth_basic_user_file	$authFile;"
				fi
				echo "
						return 503;
					}
					error_page 503 @maintenance;
					location @maintenance {
						root /etc/nginx/loadbalancing/static;
						rewrite ^.*$ /$staticSite break;
					}"
			else
				echo "
					location / {
						proxy_pass  http://upstream_$name;
						proxy_next_upstream error invalid_header timeout http_502 http_504;
						proxy_redirect off;
						proxy_set_header   Host             \$host;
						proxy_set_header   X-Real-IP        \$remote_addr;
						proxy_set_header   X-Forwarded-For  \$proxy_add_x_forwarded_for;
						client_max_body_size       32m;
						client_body_buffer_size    1m;
						proxy_connect_timeout      3; # timeout for connection to backend
						proxy_send_timeout         5; # timeout between write-requests of a single connection
						proxy_read_timeout         120;"
					if [ -n "$authFile" ]; then
						echo "					    auth_basic \"Please authenticate for $name\";"
						echo "					    auth_basic_user_file	$authFile;"
					fi
					if $enableFallback; then
						echo "					    error_page $fallbackErrorCodes = @fallback;"
					fi
				echo "
					}"
                if $enableFallback; then
				    echo "
				    location @fallback {
				    	proxy_pass  http://upstream_${name}_fallback;
				    	proxy_next_upstream error invalid_header timeout http_502 http_504;
				    	proxy_redirect off;
				    	proxy_set_header   Host             \$host;
				    	proxy_set_header   X-Real-IP        \$remote_addr;
				    	proxy_set_header   X-Forwarded-For  \$proxy_add_x_forwarded_for;
				    	client_max_body_size       32m;
				    	client_body_buffer_size    1m;
				    	proxy_connect_timeout      3; # timeout for connection to backend
				    	proxy_send_timeout         5; # timeout between write-requests of a single connection
				    	proxy_read_timeout         120;"
				    if [ -n "$authFile" ]; then
				    	echo "					    auth_basic \"Please authenticate for $name\";"
				    	echo "					    auth_basic_user_file	$authFile;"
				    fi
				    echo "
				    }"
                fi
			fi
			echo "
				}
			"
		elif $forwardHttp2Https; then
			echo "
				server {
					listen 80"$( $default && echo ' default_server default' )";
					access_log  /var/log/nginx/access_$fname.log;
					error_log  /var/log/nginx/error_$fname.log;
					server_name $domains;
					rewrite		^	https://\$server_name\$request_uri? permanent;
				}"
        elif [ -n "$forwardHttp" ]; then
			echo "
				server {
					listen 80"$( $default && echo ' default_server default' )";
					access_log  /var/log/nginx/access_$fname.log;
					error_log  /var/log/nginx/error_$fname.log;
					server_name $domains;
					rewrite		^	${forwardHttp}\$request_uri? permanent;
				}"
		fi

		# https part
		if [ -n "$backendsHttps" ]; then
			echo "
				upstream upstreamSecure_$name {
					# send requests from single ips to a single backend server
					ip_hash;
					# backends"
			echo -n "$backendsHttps" | sed 's/\(\S*\)/\1\n/g' | sed 's/\*/ /' | { while read backend weight; do
				add=""
				if ! ( $httpsInternalHttp || echo "$backend" | grep -qF ':' ) ; then
					add=":443"
				fi
				if [ -n "$weight" ]; then
					if echo "$weight" | grep -q '[0-9]*'; then
						add="$add	weight=$weight"
					else
						echo "WARNING: weight for backend $backend is $weight (non-numeric). No weight applied!"
					fi
				fi
				echo "					server $backend$add;"
			done; }
            if [ -n "$backendsHttpsFallback" ]; then
			    echo "                }
			    upstream upstreamSecure_${name}_fallback {
			    	# send requests from single ips to a single backend server
			    	ip_hash;
			    	# backends"
			    echo -n "$backendsHttpsFallback" | sed 's/\(\S*\)/\1\n/g' | sed 's/\*/ /' | { while read backend weight; do
			    	add=""
				    if ! ( $httpsInternalHttp || echo "$backend" | grep -qF ':' ) ; then
				    	add=":443"
				    fi
			    	if [ -n "$weight" ]; then
			    		if echo "$weight" | grep -q '[0-9]*'; then
			    			add="$add	weight=$weight"
			    		else
			    			echo "WARNING: weight for backend $backend is $weight (non-numeric). No weight applied!"
			    		fi
			    	fi
			    	echo "					server $backend$add;"
			    done; }
            fi
			echo "
				}
				server {
					listen 443"$( $default && echo ' default_server' )";
					access_log  /var/log/nginx/access_$fname.log;
					error_log  /var/log/nginx/error_$fname.log;
					server_name $domains;
					ssl on;
					ssl_certificate		"/etc/ssl/private/_mibaby_de_bundle.pem";
					ssl_certificate_key	"/etc/ssl/private/_mibaby_de.pem";
					#ssl_client_certificate  "/etc/ssl/private/CA-bundle.pem";
					add_header       X-Forwarded-Ssl	on;
					add_header       X-Forwarded-Proto	https;
					add_header       X-Forwarded-Port	443;"
            if $enableFallback; then
                echo "                    recursive_error_pages on;
                    proxy_intercept_errors on;"
            fi
			if [ -n "$staticSite" ]; then
				echo "
					location / {
						root /etc/nginx/loadbalancing/static;
						try_files \$uri /$staticSite;"
				if [ -n "$authFile" ]; then
					echo "					auth_basic \"Please authenticate for $name\";"
					echo "					auth_basic_user_file	$authFile;"
				fi
				echo "
					}
					location = /$staticSite {"
				if [ -n "$authFile" ]; then
					echo "					auth_basic \"Please authenticate for $name\";"
					echo "					auth_basic_user_file	$authFile;"
				fi
				echo "
						return 503;
					}
					error_page 503 @maintenance;
					location @maintenance {
						root /etc/nginx/loadbalancing/static;
						rewrite ^.*$ /$staticSite break;
					}"
			else
				echo "
					location / {
						proxy_pass  http$( $httpsInternalHttp || echo -n s )://upstreamSecure_$name;
						proxy_next_upstream error invalid_header timeout http_502 http_504;
						proxy_redirect off;
						proxy_set_header   Host             \$host;
						proxy_set_header   X-Real-IP        \$remote_addr;
						proxy_set_header   X-Forwarded-For  \$proxy_add_x_forwarded_for;
						client_max_body_size       32m;
						client_body_buffer_size    1m;
						proxy_connect_timeout      3; # timeout for connection to backend
						proxy_send_timeout         5; # timeout between write-requests of a single connection
						proxy_read_timeout         120; # timeout between read-requests of a single connection"
					if [ -n "$authFile" ]; then
						echo "					    auth_basic \"Please authenticate for $name\";"
						echo "					    auth_basic_user_file	$authFile;"
					fi
					if $enableFallback; then
						echo "					    error_page $fallbackErrorCodes = @fallback;"
					fi
					echo "
					}"
                if $enableFallback; then
				    echo "
				    location @fallback {
					    proxy_pass  http$( $httpsInternalHttp || echo -n s )://upstreamSecure_${name}_fallback;
				    	proxy_next_upstream error invalid_header timeout http_502 http_504;
				    	proxy_redirect off;
				    	proxy_set_header   Host             \$host;
				    	proxy_set_header   X-Real-IP        \$remote_addr;
				    	proxy_set_header   X-Forwarded-For  \$proxy_add_x_forwarded_for;
				    	client_max_body_size       32m;
				    	client_body_buffer_size    1m;
				    	proxy_connect_timeout      3; # timeout for connection to backend
				    	proxy_send_timeout         5; # timeout between write-requests of a single connection
				    	proxy_read_timeout         120;"
				    if [ -n "$authFile" ]; then
				    	echo "					    auth_basic \"Please authenticate for $name\";"
				    	echo "					    auth_basic_user_file	$authFile;"
				    fi
				    echo "
				    }"
                fi
			fi
			echo "
				}
			"
		elif $forwardHttps2Http; then
			echo "
				server {
					listen 443"$( $default && echo ' default_server default' )";
					access_log  /var/log/nginx/access_$fname.log;
					error_log  /var/log/nginx/error_$fname.log;
					ssl_certificate		"/etc/ssl/private/_mibaby_de_bundle.pem";
					ssl_certificate_key	"/etc/ssl/private/_mibaby_de.pem";
					#ssl_client_certificate  "/etc/ssl/private/CA-bundle.pem";
					server_name $domains;
					rewrite		^	http://\$server_name\$request_uri? permanent;
				}"
        elif [ -n "$forwardHttps" ]; then
			echo "
				server {
					listen 443;
					access_log  /var/log/nginx/access_$fname.log;
					error_log  /var/log/nginx/error_$fname.log;
					ssl_certificate		"/etc/ssl/private/_mibaby_de_bundle.pem";
					ssl_certificate_key	"/etc/ssl/private/_mibaby_de.pem";
					#ssl_client_certificate  "/etc/ssl/private/CA-bundle.pem";
					server_name $domains;
					rewrite		^	${forwardHttps}\$request_uri? permanent;
				}"
		fi
	} > sites-available/$fname
	ln -s ../sites-available/$fname sites-enabled/$fname
	
done

echo "Testing configuration. if it succeeds, use \"service nginx reload\" or \"service nginx restart\""
service nginx configtest
