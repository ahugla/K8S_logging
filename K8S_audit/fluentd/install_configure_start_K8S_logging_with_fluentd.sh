#!/bin/bash



# Set Parameter
# -------------
VRLI_IP=vrli.cpod-vrealize.az-fkd.cloud-garage.net



cd /tmp



# install fluentd
# ---------------
yum install -y gem
gem install fluentd
fluentd --setup /etc/fluent         # pour demarrer: fluentd -c /etc/fluent/fluent.conf -p /etc/fluent/plugin



# Install Log Insight gem
# -----------------------
wget https://github.com/vmware/fluent-plugin-vmware-loginsight/releases/download/v1.0.0/fluent-plugin-vmware-loginsight-1.0.0.gem
gem install fluent-plugin-vmware-loginsight-1.0.0.gem
#   LE NOM DU GEM LOG INSIGHT (gem list) : fluent-plugin-vmware-loginsight    =>  dans le fichier de conf : @type vmware_loginsight


# Ruby builds these plugins in ‘/usr/local/rvm/gems/ruby-3.0.0/gems/’, which means you would need to specify the full path of the gem directory where the plugins were built when starting Fluentd.
# To make things easier, I copied the plugin files to ‘/etc/fluent/plugin’, which is the default directory that Fluentd looks for plugins. No extra parameters needed on startup.
cp -r /usr/local/rvm/gems/ruby-3.0.0/gems/* /etc/fluent/plugin/




# configure fluentd
# -----------------
cat > /etc/fluent/fluent.conf << EOF

<source>
  @id in_tail_kube_apiserver_logs
  @type tail
  path /var/log/kube-apiserver.log
  pos_file /var/log/fluentd-kube-apiserver.log.pos
  tag kubernetes.apiserver
  read_from_head true
  format json
</source>

<source>
  @id in_tail_kube_scheduler_logs
  @type tail
  path /var/log/kube-scheduler.log
  pos_file /var/log/fluentd-kube-scheduler.log.pos
  tag kubernetes.scheduler
  read_from_head true
  format json
</source>

<source>
  @id in_tail_kube_controller_manager_logs
  @type tail
  path /var/log/kube-controller-manager.log
  pos_file /var/log/fluentd-kube-controller-manager.log.pos
  tag kubernetes.controller
  read_from_head true
  format json
</source>

<source>
  @id in_tail_kubelet_logs
  @type tail
  path /var/log/kubelet.log
  pos_file /var/log/fluentd-kublet.log.pos
  tag kubernetes.kublet
  read_from_head true
  format json
</source>

<source>
  @id in_tail_kube_proxy_logs
  @type tail
  path /var/log/kube-proxy.log
  pos_file /var/log/fluentd-kube-proxy.log.pos
  tag kubernetes.kubeproxy
  read_from_head true
  format json
</source>

<filter kubernetes.apiserver>
  @type record_transformer
  <record>
  log_type kube_apiserver
  </record>
</filter>

<filter kubernetes.scheduler>
  @type record_transformer
  <record>
  log_type kube_scheduler
  </record>
</filter>

<filter kubernetes.controller>
  @type record_transformer
  <record>
  log_type kube_controller
  </record>
</filter>

<filter kubernetes.kublet>
  @type record_transformer
  <record>
  log_type kube_kublet
  </record>
</filter>

<filter kubernetes.kubeproxy>
  @type record_transformer
  <record>
  log_type kube_proxy
  </record>
</filter>

<match kubernetes.*>
  @type vmware_loginsight
  host <LOGINSIGHT-IP>
  port 9543
  scheme https
  ssl_verify false
  raise_on_error true
  log_text_keys ["annotations_authorization_k8s_io_reason"]
</match>
EOF



# configure VRLI IP address
# -------------------------
sed -i -e 's/<LOGINSIGHT-IP>/'$VRLI_IP'/g'  /etc/fluent/fluent.conf



# create configMap pointing to fluent.conf
# ----------------------------------------
kubectl -n kube-system create configmap loginsight-fluentd-config --from-file=/etc/fluent/fluent.conf



# create DaemonSet yaml
# ---------------------
cat > loginsight-fluent.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: fluentd-loginsight-logging
  name: fluentd-loginsight-logging
  namespace: kube-system

---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: fluentd-clusterrole
rules:
- apiGroups: [""]
  resources: ["namespaces", "pods"]
  verbs: ["list", "get", "watch"]

---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: fluentd-clusterrole
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluentd-clusterrole
subjects:
  - kind: ServiceAccount
    name: fluentd-loginsight-logging
    namespace: kube-system

---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd-loginsight-logging
  namespace: kube-system
  labels:
    k8s-app: fluentd-loginsight-logging
    app: fluentd-loginsight-logging
    version: v1
    kubernetes.io/cluster-service: "true"
spec:
 selector:
   matchLabels:
     name: fluentd-loginsight-logging
 template:
   metadata:
     labels:
       name: fluentd-loginsight-logging
       app: fluentd-loginsight-logging
       version: v1
       kubernetes.io/cluster-service: "true"
   spec:
     serviceAccount: fluentd-loginsight-logging
     serviceAccountName: fluentd-loginsight-logging
     tolerations:
     - key: node-role.kubernetes.io/master
       effect: NoSchedule
     containers:
     - name: fluentd-loginsight
       image: projects.registry.vmware.com/vrealize_loginsight/fluentd:1.0
       command: ["fluentd", "-c", "/etc/fluent/fluent.conf", "-p", "/fluentd/plugins"]    # -p reference le plugin log insight a utilier DANS le container!!!!
       env:
       - name: FLUENTD_ARGS
         value: --no-supervisor -q
       resources:
         limits:
           memory: 500Mi
         requests:
           cpu: 100m
           memory: 200Mi
       volumeMounts:
       - name: varlog
         mountPath: /var/log
         readOnly: false
       - name: config-volume
         mountPath: /etc/fluent
         readOnly: true
     volumes:
     - name: varlog
       hostPath:
         path: /var/log
     - name: config-volume
       configMap:
         name: loginsight-fluentd-config
EOF



# deploy DaemonSet yaml
# ---------------------
kubectl apply -f loginsight-fluent.yaml



# MARCHE MAIS PB C EST QUE Y A PAS DE LOG DANS /VAR/LOG/KUBE.....LOG
#  NORMAL C EST SYSTEMD ET CA LOG DIFFEREMMENT
#  SOIR SYSTEMD DEPOSE DANS /VAR/LOG/JOURNAL   SOIT IL GARDE EN MEMOIRE ....=>  PASSER PAR UN PLUGIN FLUENT POUR SYSTEMD
