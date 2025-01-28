{% if pillar["atlassian-confluence"] is defined %}
{% from 'atlassian-confluence/map.jinja' import confluence with context %}

nginx_install:
  pkg.installed:
    - pkgs:
      - nginx

nginx_files_1:
  file.managed:
    - name: /etc/nginx/nginx.conf
    - contents: |
        worker_processes 4;
        worker_rlimit_nofile 40000;
        events {
            worker_connections 8192;
            use epoll;
            multi_accept on;
        }
        http {
            include /etc/nginx/mime.types;
            default_type application/octet-stream;
            sendfile on;
            tcp_nopush on;
            tcp_nodelay on;
            gzip on;
            gzip_comp_level 4;
            gzip_types text/plain text/css application/x-javascript text/xml application/xml application/xml+rss text/javascript;
            gzip_vary on;
            gzip_proxied any;
            client_max_body_size 1000m;
            server {
                listen 80;
                return 301 https://$host$request_uri;
            }
            server {
                listen 443 ssl;
                server_name {{ pillar["atlassian-confluence"]["http_proxyName"] }};
                ssl_certificate /opt/acme/cert/atlassian-confluence_{{ pillar["atlassian-confluence"]["http_proxyName"] }}_fullchain.cer;
                ssl_certificate_key /opt/acme/cert/atlassian-confluence_{{ pillar["atlassian-confluence"]["http_proxyName"] }}_key.key;
                client_body_buffer_size 128k;
                location / {
                    proxy_pass http://localhost:{{ pillar["atlassian-confluence"]["http_port"] }};
                    proxy_set_header X-Forwarded-Host $host;
                    proxy_set_header X-Forwarded-Server $host;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                }
            }
        }

nginx_files_2:
  file.absent:
    - name: /etc/nginx/sites-enabled/default

nginx_cert:
  cmd.run:
    - shell: /bin/bash
    - name: "/opt/acme/home/{{ pillar["atlassian-confluence"]["acme_account"] }}/verify_and_issue.sh atlassian-confluence {{ pillar["atlassian-confluence"]["http_proxyName"] }}"

nginx_reload:
  cmd.run:
    - runas: root
    - name: service nginx configtest && service nginx restart

nginx_reload_cron:
  cron.present:
    - name: /usr/sbin/service nginx configtest && /usr/sbin/service nginx restart
    - identifier: nginx_reload
    - user: root
    - minute: 15
    - hour: 6

confluence-dependencies:
  pkg.installed:
    - pkgs:
      - libxslt1.1
      - xsltproc
      - openjdk-17-jdk

confluence:
  file.managed:
    - name: /etc/systemd/system/atlassian-confluence.service
    - source: salt://atlassian-confluence/files/atlassian-confluence.service
    - template: jinja
    - defaults:
        config: {{ confluence }}

  module.wait:
    - name: service.systemctl_reload
    - watch:
      - file: confluence

  group.present:
    - name: {{ confluence.group }}

  user.present:
    - name: {{ confluence.user }}
    - home: {{ confluence.dirs.home }}
    - gid: {{ confluence.group }}
    - require:
      - group: confluence
      - file: confluence-dir

  service.running:
    - name: atlassian-confluence
    - enable: True
    - require:
      - user: confluence
  {%- if "addon" in pillar["atlassian-confluence"] %}
      - file: addon
    {%- if "javaopts" in pillar["atlassian-confluence"]["addon"] %}
      - file: addon-javaopts
addon-javaopts:
  file.replace:
    - name: '/opt/atlassian/confluence/scripts/env.sh'
    - pattern: '^ *export JAVA_OPTS=.*$'
    - repl: 'export JAVA_OPTS="{{ pillar["atlassian-confluence"]["addon"]["javaopts"] }} ${JAVA_OPTS}"'
    - append_if_not_found: True
    - require:
      - file: confluence-script-env.sh
    {%- endif %}
addon:
  file.managed:
    - name: {{ pillar["atlassian-confluence"]["addon"]["target"] }}
    - source: {{ pillar["atlassian-confluence"]["addon"]["source"] }}
    - require:
      - archive: confluence-install
  {%- endif %}

confluence-graceful-down:
  service.dead:
    - name: atlassian-confluence
    - require:
      - module: confluence
    - prereq:
      - file: confluence-install

confluence-install:
  archive.extracted:
    - name: {{ confluence.dirs.extract }}
    - source: {{ confluence.url }}
    - source_hash: {{ confluence.url_hash }}
    - if_missing: {{ confluence.dirs.current_install }}
    - options: z
    - keep: True
    - require:
      - file: confluence-extractdir

  file.symlink:
    - name: {{ confluence.dirs.install }}
    - target: {{ confluence.dirs.current_install }}
    - require:
      - archive: confluence-install
    - watch_in:
      - service: confluence

confluence-server-xsl:
  file.managed:
    - name: {{ confluence.dirs.temp }}/server.xsl
    - source: salt://atlassian-confluence/files/server.xsl
    - template: jinja
    - require:
      - file: confluence-tempdir

  cmd.run:
    - name: |
        xsltproc \
          --stringparam pHttpPort "{{ confluence.get('http_port', '') }}" \
          --stringparam pHttpScheme "{{ confluence.get('http_scheme', '') }}" \
          --stringparam pHttpProxyName "{{ confluence.get('http_proxyName', '') }}" \
          --stringparam pHttpProxyPort "{{ confluence.get('http_proxyPort', '') }}" \
          --stringparam pAjpPort "{{ confluence.get('ajp_port', '') }}" \
          -o "{{ confluence.dirs.temp }}/server.xml" "{{ confluence.dirs.temp }}/server.xsl" server.xml
    - cwd: {{ confluence.dirs.install }}/conf
    - require:
      - file: confluence-server-xsl
      - file: confluence-install

confluence-server-xml:
  file.managed:
    - name: {{ confluence.dirs.install }}/conf/server.xml
    - source: {{ confluence.dirs.temp }}/server.xml
    - require:
      - cmd: confluence-server-xsl
    - watch_in:
      - service: confluence

confluence-dir:
  file.directory:
    - name: {{ confluence.dir }}
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

confluence-home:
  file.directory:
    - name: {{ confluence.dirs.home }}
    - user: {{ confluence.user }}
    - group: {{ confluence.group }}
    - require:
      - file: confluence-dir
      - user: confluence
      - group: confluence
    - use:
      - file: confluence-dir

confluence-extractdir:
  file.directory:
    - name: {{ confluence.dirs.extract }}
    - use:
      - file: confluence-dir

confluence-tempdir:
  file.directory:
    - name: {{ confluence.dirs.temp }}
    - use:
      - file: confluence-dir

confluence-conf-standalonedir:
  file.directory:
    - name: {{ confluence.dirs.install }}/conf/Standalone
    - user: {{ confluence.user }}
    - group: {{ confluence.group }}
    - use:
      - file: confluence-dir

confluence-scriptdir:
  file.directory:
    - name: {{ confluence.dirs.scripts }}
    - use:
      - file: confluence-dir

{% for file in [ 'env.sh', 'start.sh', 'stop.sh' ] %}
confluence-script-{{ file }}:
  file.managed:
    - name: {{ confluence.dirs.scripts }}/{{ file }}
    - source: salt://atlassian-confluence/files/{{ file }}
    - user: {{ confluence.user }}
    - group: {{ confluence.group }}
    - mode: 755
    - template: jinja
    - defaults:
        config: {{ confluence }}
    - require:
      - file: confluence-scriptdir
      - user: confluence
    - watch_in:
      - service: confluence
{% endfor %}

{% if confluence.get('crowd') %}
confluence-crowd-properties:
  file.managed:
    - name: {{ confluence.dirs.install }}/confluence/WEB-INF/classes/crowd.properties
    - require:
      - file: confluence-install
    - watch_in:
      - service: confluence
    - contents: |
{%- for key, val in confluence.crowd.items() %}
        {{ key }}: {{ val }}
{%- endfor %}
{% endif %}

{% for chmoddir in ['bin', 'work', 'temp', 'logs'] %}
confluence-permission-{{ chmoddir }}:
  file.directory:
    - name: {{ confluence.dirs.install }}/{{ chmoddir }}
    - user: {{ confluence.user }}
    - group: {{ confluence.group }}
    - recurse:
      - user
      - group
    - require:
      - file: confluence-install
    - require_in:
      - service: confluence
{% endfor %}

confluence-disable-ConfluenceAuthenticator:
  file.replace:
    - name: {{ confluence.dirs.install }}/confluence/WEB-INF/classes/seraph-config.xml
    - pattern: |
        ^(\s*)[\s<!-]*(<authenticator class="com\.atlassian\.confluence\.user\.ConfluenceAuthenticator"\/>)[\s>-]*$
    - repl: |
        {% if confluence.crowdSSO %}\1<!-- \2 -->{% else %}\1\2{% endif %}
    - watch_in:
      - service: confluence

confluence-enable-ConfluenceCrowdSSOAuthenticator:
  file.replace:
    - name: {{ confluence.dirs.install }}/confluence/WEB-INF/classes/seraph-config.xml
    - pattern: |
        ^(\s*)[\s<!-]*(<authenticator class="com\.atlassian\.confluence\.user\.ConfluenceCrowdSSOAuthenticator"\/>)[\s>-]*$
    - repl: |
        {% if confluence.crowdSSO %}\1\2{% else %}\1<!-- \2 -->{% endif %}
    - watch_in:
      - service: confluence
{% endif %}
