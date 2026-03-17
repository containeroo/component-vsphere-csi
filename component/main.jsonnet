local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.vsphere_csi;

local reservedConfigurationKeys = [
  'global',
  'labels',
  'net_permissions',
  'snapshot',
  'topology_category',
];

local configuration = std.get(params, 'configuration', {});
local globalConfiguration = std.get(configuration, 'global', {});
local netPermissions = std.get(configuration, 'net_permissions', {});
local topologyCategories = std.get(configuration, 'topology_category', {});
local vcenters = {
  [vc]: configuration[vc]
  for vc in std.objectFields(configuration)
  if !std.member(reservedConfigurationKeys, vc)
};

local quoted(value) = std.escapeStringJson(value);

local renderScalar(value) =
  if std.type(value) == 'null' then null
  else if std.type(value) == 'array' then quoted(std.join(', ', [ std.toString(entry) for entry in value ]))
  else if std.type(value) == 'boolean' then quoted(if value then 'true' else 'false')
  else if std.type(value) == 'number' then quoted(std.toString(value))
  else if std.type(value) == 'string' then quoted(value)
  else error 'Unsupported vSphere CSI config value type %s' % std.type(value);

local renderSection(name, values) =
  if values == null || std.length(std.objectFields(values)) == 0 then
    []
  else
    [ '[%s]' % name ] + [
      '%s = %s' % [ key, renderScalar(values[key]) ]
      for key in std.sort(std.objectFields(values))
      if values[key] != null
    ] + [ '' ];

local renderNamedSection(kind, name, values) =
  if values == null || std.length(std.objectFields(values)) == 0 then
    []
  else
    [ '[%s "%s"]' % [ kind, name ] ] + [
      '%s = %s' % [ key, renderScalar(values[key]) ]
      for key in std.sort(std.objectFields(values))
      if values[key] != null
    ] + [ '' ];

local configLines =
  renderSection('Global', globalConfiguration) +
  renderSection('Labels', std.get(configuration, 'labels', {})) +
  renderSection('Snapshot', std.get(configuration, 'snapshot', {})) +
  std.flattenArrays([
    renderNamedSection('NetPermissions', name, netPermissions[name])
    for name in std.sort(std.objectFields(netPermissions))
  ]) +
  std.flattenArrays([
    renderNamedSection('TopologyCategory', name, topologyCategories[name])
    for name in std.sort(std.objectFields(topologyCategories))
  ]) +
  std.flattenArrays([
    renderNamedSection('VirtualCenter', vc, vcenters[vc])
    for vc in std.sort(std.objectFields(vcenters))
  ]);

local configSecretContents = std.join('\n', configLines);

local imageRef(image) = '%s/%s:%s' % [ image.registry, image.repository, image.tag ];

local withResources(base, resources) =
  if resources == null || std.length(std.objectFields(resources)) == 0 then
    base
  else
    base { resources: resources };

local metadata(name, namespace=null, extra={}) = {
  name: name,
  [if namespace != null then 'namespace']: namespace,
} + extra;

local controllerPodLabels = {
  app: 'vsphere-csi-controller',
  role: 'vsphere-csi',
};

local nodePodLabels = {
  app: 'vsphere-csi-node',
  role: 'vsphere-csi',
};

assert std.length(std.objectFields(vcenters)) > 0 :
       'vsphere_csi.configuration must define at least one vCenter section besides the reserved keys %s' %
       std.join(', ', reservedConfigurationKeys);

{
  '00_namespace': {
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: metadata(params.namespace),
  },

  '01_csidriver': {
    apiVersion: 'storage.k8s.io/v1',
    kind: 'CSIDriver',
    metadata: metadata(params.csidriver_name),
    spec: {
      attachRequired: true,
      podInfoOnMount: false,
    },
  },

  '02_controller-serviceaccount': {
    apiVersion: 'v1',
    kind: 'ServiceAccount',
    metadata: metadata('vsphere-csi-controller', params.namespace),
  },

  '03_controller-clusterrole': {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRole',
    metadata: metadata('vsphere-csi-controller-role'),
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'nodes', 'pods' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'configmaps' ],
        verbs: [ 'get', 'list', 'watch', 'create' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'persistentvolumeclaims' ],
        verbs: [ 'get', 'list', 'watch', 'update' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'persistentvolumeclaims/status' ],
        verbs: [ 'patch' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'persistentvolumes' ],
        verbs: [ 'get', 'list', 'watch', 'create', 'update', 'delete', 'patch' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'events' ],
        verbs: [ 'get', 'list', 'watch', 'create', 'update', 'patch' ],
      },
      {
        apiGroups: [ 'coordination.k8s.io' ],
        resources: [ 'leases' ],
        verbs: [ 'get', 'watch', 'list', 'delete', 'update', 'create' ],
      },
      {
        apiGroups: [ 'storage.k8s.io' ],
        resources: [ 'storageclasses', 'csinodes' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ 'storage.k8s.io' ],
        resources: [ 'volumeattachments' ],
        verbs: [ 'get', 'list', 'watch', 'patch' ],
      },
      {
        apiGroups: [ 'cns.vmware.com' ],
        resources: [ 'triggercsifullsyncs' ],
        verbs: [ 'create', 'get', 'update', 'watch', 'list' ],
      },
      {
        apiGroups: [ 'cns.vmware.com' ],
        resources: [ 'cnsvspherevolumemigrations' ],
        verbs: [ 'create', 'get', 'list', 'watch', 'update', 'delete' ],
      },
      {
        apiGroups: [ 'cns.vmware.com' ],
        resources: [ 'cnsvolumeinfoes' ],
        verbs: [ 'create', 'get', 'list', 'watch', 'delete' ],
      },
      {
        apiGroups: [ 'apiextensions.k8s.io' ],
        resources: [ 'customresourcedefinitions' ],
        verbs: [ 'get', 'create', 'update' ],
      },
      {
        apiGroups: [ 'storage.k8s.io' ],
        resources: [ 'volumeattachments/status' ],
        verbs: [ 'patch' ],
      },
      {
        apiGroups: [ 'cns.vmware.com' ],
        resources: [ 'cnsvolumeoperationrequests' ],
        verbs: [ 'create', 'get', 'list', 'update', 'delete' ],
      },
      {
        apiGroups: [ 'snapshot.storage.k8s.io' ],
        resources: [ 'volumesnapshots' ],
        verbs: [ 'get', 'list' ],
      },
      {
        apiGroups: [ 'snapshot.storage.k8s.io' ],
        resources: [ 'volumesnapshotclasses' ],
        verbs: [ 'watch', 'get', 'list' ],
      },
      {
        apiGroups: [ 'snapshot.storage.k8s.io' ],
        resources: [ 'volumesnapshotcontents' ],
        verbs: [ 'create', 'get', 'list', 'watch', 'update', 'delete', 'patch' ],
      },
      {
        apiGroups: [ 'snapshot.storage.k8s.io' ],
        resources: [ 'volumesnapshotcontents/status' ],
        verbs: [ 'update', 'patch' ],
      },
      {
        apiGroups: [ 'cns.vmware.com' ],
        resources: [ 'csinodetopologies' ],
        verbs: [ 'get', 'update', 'watch', 'list' ],
      },
    ],
  },

  '04_controller-clusterrolebinding': {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: metadata('vsphere-csi-controller-binding'),
    subjects: [
      {
        kind: 'ServiceAccount',
        name: 'vsphere-csi-controller',
        namespace: params.namespace,
      },
    ],
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'ClusterRole',
      name: 'vsphere-csi-controller-role',
    },
  },

  '05_node-serviceaccount': {
    apiVersion: 'v1',
    kind: 'ServiceAccount',
    metadata: metadata('vsphere-csi-node', params.namespace),
  },

  '06_node-clusterrole': {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRole',
    metadata: metadata('vsphere-csi-node-cluster-role'),
    rules: [
      {
        apiGroups: [ 'cns.vmware.com' ],
        resources: [ 'csinodetopologies' ],
        verbs: [ 'create', 'watch', 'get', 'patch' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'nodes' ],
        verbs: [ 'get' ],
      },
    ],
  },

  '07_node-clusterrolebinding': {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: metadata('vsphere-csi-node-cluster-role-binding'),
    subjects: [
      {
        kind: 'ServiceAccount',
        name: 'vsphere-csi-node',
        namespace: params.namespace,
      },
    ],
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'ClusterRole',
      name: 'vsphere-csi-node-cluster-role',
    },
  },

  '08_node-role': {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'Role',
    metadata: metadata('vsphere-csi-node-role', params.namespace),
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'configmaps' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
    ],
  },

  '09_node-rolebinding': {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'RoleBinding',
    metadata: metadata('vsphere-csi-node-binding', params.namespace),
    subjects: [
      {
        kind: 'ServiceAccount',
        name: 'vsphere-csi-node',
        namespace: params.namespace,
      },
    ],
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'Role',
      name: 'vsphere-csi-node-role',
    },
  },

  '10_feature-states-configmap': {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: metadata(params.feature_states_configmap_name, params.namespace),
    data: params.feature_states,
  },

  '11_vsphere-config-secret': {
    apiVersion: 'v1',
    kind: 'Secret',
    metadata: metadata(params.config_secret_name, params.namespace),
    stringData: {
      'csi-vsphere.conf': configSecretContents,
    },
    type: 'Opaque',
  },

  '12_controller-service': {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: metadata('vsphere-csi-controller', params.namespace, {
      labels: {
        app: 'vsphere-csi-controller',
      },
    }),
    spec: {
      selector: {
        app: 'vsphere-csi-controller',
      },
      ports: [
        {
          name: 'ctlr',
          port: 2112,
          protocol: 'TCP',
          targetPort: 2112,
        },
        {
          name: 'syncer',
          port: 2113,
          protocol: 'TCP',
          targetPort: 2113,
        },
      ],
    },
  },

  '13_controller-deployment': {
    apiVersion: 'apps/v1',
    kind: 'Deployment',
    metadata: metadata('vsphere-csi-controller', params.namespace),
    spec: {
      replicas: params.controller.replicas,
      strategy: {
        type: 'RollingUpdate',
        rollingUpdate: {
          maxUnavailable: params.controller.max_unavailable,
          maxSurge: params.controller.max_surge,
        },
      },
      selector: {
        matchLabels: {
          app: 'vsphere-csi-controller',
        },
      },
      template: {
        metadata: {
          labels: controllerPodLabels,
        },
        spec: {
          priorityClassName: params.controller.priority_class_name,
          affinity: {
            podAntiAffinity: {
              requiredDuringSchedulingIgnoredDuringExecution: [
                {
                  labelSelector: {
                    matchExpressions: [
                      {
                        key: 'app',
                        operator: 'In',
                        values: [ 'vsphere-csi-controller' ],
                      },
                    ],
                  },
                  topologyKey: 'kubernetes.io/hostname',
                },
              ],
            },
          },
          serviceAccountName: 'vsphere-csi-controller',
          nodeSelector: params.controller.node_selector,
          tolerations: params.controller.tolerations,
          dnsPolicy: 'Default',
          containers: [
            withResources({
              name: 'csi-attacher',
              image: imageRef(params.images.csi_attacher),
              args: [
                '--v=4',
                '--timeout=300s',
                '--csi-address=$(ADDRESS)',
                '--leader-election',
                '--leader-election-lease-duration=120s',
                '--leader-election-renew-deadline=60s',
                '--leader-election-retry-period=30s',
                '--kube-api-qps=100',
                '--kube-api-burst=100',
              ],
              env: [
                {
                  name: 'ADDRESS',
                  value: '/csi/csi.sock',
                },
              ],
              volumeMounts: [
                {
                  mountPath: '/csi',
                  name: 'socket-dir',
                },
              ],
            }, std.get(params.controller.resources, 'csi_attacher', {})),
            withResources({
              name: 'csi-resizer',
              image: imageRef(params.images.csi_resizer),
              args: [
                '--v=4',
                '--timeout=300s',
                '--handle-volume-inuse-error=false',
                '--csi-address=$(ADDRESS)',
                '--kube-api-qps=100',
                '--kube-api-burst=100',
                '--leader-election',
                '--leader-election-lease-duration=120s',
                '--leader-election-renew-deadline=60s',
                '--leader-election-retry-period=30s',
              ],
              env: [
                {
                  name: 'ADDRESS',
                  value: '/csi/csi.sock',
                },
              ],
              volumeMounts: [
                {
                  mountPath: '/csi',
                  name: 'socket-dir',
                },
              ],
            }, std.get(params.controller.resources, 'csi_resizer', {})),
            withResources({
              name: 'vsphere-csi-controller',
              image: imageRef(params.images.driver),
              imagePullPolicy: params.controller.image_pull_policy,
              args: [
                '--fss-name=%s' % params.feature_states_configmap_name,
                '--fss-namespace=$(CSI_NAMESPACE)',
              ],
              env: [
                {
                  name: 'CSI_ENDPOINT',
                  value: 'unix:///csi/csi.sock',
                },
                {
                  name: 'X_CSI_MODE',
                  value: 'controller',
                },
                {
                  name: 'X_CSI_SPEC_DISABLE_LEN_CHECK',
                  value: 'true',
                },
                {
                  name: 'X_CSI_SERIAL_VOL_ACCESS_TIMEOUT',
                  value: '3m',
                },
                {
                  name: 'VSPHERE_CSI_CONFIG',
                  value: '/etc/cloud/csi-vsphere.conf',
                },
                {
                  name: 'LOGGER_LEVEL',
                  value: 'PRODUCTION',
                },
                {
                  name: 'INCLUSTER_CLIENT_QPS',
                  value: '100',
                },
                {
                  name: 'INCLUSTER_CLIENT_BURST',
                  value: '100',
                },
                {
                  name: 'CSI_NAMESPACE',
                  valueFrom: {
                    fieldRef: {
                      fieldPath: 'metadata.namespace',
                    },
                  },
                },
              ],
              volumeMounts: [
                {
                  mountPath: '/etc/cloud',
                  name: 'vsphere-config-volume',
                  readOnly: true,
                },
                {
                  mountPath: '/csi',
                  name: 'socket-dir',
                },
              ],
              ports: [
                {
                  name: 'healthz',
                  containerPort: 9808,
                  protocol: 'TCP',
                },
                {
                  name: 'prometheus',
                  containerPort: 2112,
                  protocol: 'TCP',
                },
              ],
              livenessProbe: {
                httpGet: {
                  path: '/healthz',
                  port: 'healthz',
                },
                initialDelaySeconds: 30,
                timeoutSeconds: 10,
                periodSeconds: 180,
                failureThreshold: 3,
              },
            }, std.get(params.controller.resources, 'vsphere_csi_controller', {})),
            withResources({
              name: 'liveness-probe',
              image: imageRef(params.images.liveness_probe),
              args: [
                '--v=4',
                '--csi-address=/csi/csi.sock',
              ],
              volumeMounts: [
                {
                  name: 'socket-dir',
                  mountPath: '/csi',
                },
              ],
            }, std.get(params.controller.resources, 'liveness_probe', {})),
            withResources({
              name: 'vsphere-syncer',
              image: imageRef(params.images.syncer),
              imagePullPolicy: params.controller.image_pull_policy,
              args: [
                '--leader-election',
                '--leader-election-lease-duration=120s',
                '--leader-election-renew-deadline=60s',
                '--leader-election-retry-period=30s',
                '--fss-name=%s' % params.feature_states_configmap_name,
                '--fss-namespace=$(CSI_NAMESPACE)',
              ],
              ports: [
                {
                  name: 'prometheus',
                  containerPort: 2113,
                  protocol: 'TCP',
                },
              ],
              env: [
                {
                  name: 'FULL_SYNC_INTERVAL_MINUTES',
                  value: std.toString(params.controller.full_sync_interval_minutes),
                },
                {
                  name: 'VSPHERE_CSI_CONFIG',
                  value: '/etc/cloud/csi-vsphere.conf',
                },
                {
                  name: 'LOGGER_LEVEL',
                  value: 'PRODUCTION',
                },
                {
                  name: 'INCLUSTER_CLIENT_QPS',
                  value: '100',
                },
                {
                  name: 'INCLUSTER_CLIENT_BURST',
                  value: '100',
                },
                {
                  name: 'GODEBUG',
                  value: 'x509sha1=1',
                },
                {
                  name: 'CSI_NAMESPACE',
                  valueFrom: {
                    fieldRef: {
                      fieldPath: 'metadata.namespace',
                    },
                  },
                },
              ],
              volumeMounts: [
                {
                  mountPath: '/etc/cloud',
                  name: 'vsphere-config-volume',
                  readOnly: true,
                },
              ],
            }, std.get(params.controller.resources, 'vsphere_syncer', {})),
            withResources({
              name: 'csi-provisioner',
              image: imageRef(params.images.csi_provisioner),
              args: [
                '--v=4',
                '--timeout=300s',
                '--csi-address=$(ADDRESS)',
                '--kube-api-qps=100',
                '--kube-api-burst=100',
                '--leader-election',
                '--leader-election-lease-duration=120s',
                '--leader-election-renew-deadline=60s',
                '--leader-election-retry-period=30s',
                '--default-fstype=%s' % params.controller.default_fstype,
              ],
              env: [
                {
                  name: 'ADDRESS',
                  value: '/csi/csi.sock',
                },
              ],
              volumeMounts: [
                {
                  mountPath: '/csi',
                  name: 'socket-dir',
                },
              ],
            }, std.get(params.controller.resources, 'csi_provisioner', {})),
            withResources({
              name: 'csi-snapshotter',
              image: imageRef(params.images.csi_snapshotter),
              args: [
                '--v=4',
                '--kube-api-qps=100',
                '--kube-api-burst=100',
                '--timeout=300s',
                '--csi-address=$(ADDRESS)',
                '--leader-election',
                '--leader-election-lease-duration=120s',
                '--leader-election-renew-deadline=60s',
                '--leader-election-retry-period=30s',
              ],
              env: [
                {
                  name: 'ADDRESS',
                  value: '/csi/csi.sock',
                },
              ],
              volumeMounts: [
                {
                  mountPath: '/csi',
                  name: 'socket-dir',
                },
              ],
            }, std.get(params.controller.resources, 'csi_snapshotter', {})),
          ],
          volumes: [
            {
              name: 'vsphere-config-volume',
              secret: {
                secretName: params.config_secret_name,
              },
            },
            {
              name: 'socket-dir',
              emptyDir: {},
            },
          ],
        },
      },
    },
  },

  '14_node-daemonset': {
    apiVersion: 'apps/v1',
    kind: 'DaemonSet',
    metadata: metadata('vsphere-csi-node', params.namespace),
    spec: {
      selector: {
        matchLabels: {
          app: 'vsphere-csi-node',
        },
      },
      updateStrategy: {
        type: 'RollingUpdate',
        rollingUpdate: {
          maxUnavailable: params.node.max_unavailable,
        },
      },
      template: {
        metadata: {
          labels: nodePodLabels,
        },
        spec: {
          priorityClassName: params.node.priority_class_name,
          nodeSelector: params.node.node_selector,
          serviceAccountName: 'vsphere-csi-node',
          hostNetwork: true,
          dnsPolicy: 'ClusterFirstWithHostNet',
          containers: [
            withResources({
              name: 'node-driver-registrar',
              image: imageRef(params.images.csi_node_driver_registrar),
              args: [
                '--v=5',
                '--csi-address=$(ADDRESS)',
                '--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)',
              ],
              env: [
                {
                  name: 'ADDRESS',
                  value: '/csi/csi.sock',
                },
                {
                  name: 'DRIVER_REG_SOCK_PATH',
                  value: '/var/lib/kubelet/plugins/%s/csi.sock' % params.csidriver_name,
                },
              ],
              volumeMounts: [
                {
                  name: 'plugin-dir',
                  mountPath: '/csi',
                },
                {
                  name: 'registration-dir',
                  mountPath: '/registration',
                },
              ],
              livenessProbe: {
                exec: {
                  command: [
                    '/csi-node-driver-registrar',
                    '--kubelet-registration-path=/var/lib/kubelet/plugins/%s/csi.sock' % params.csidriver_name,
                    '--mode=kubelet-registration-probe',
                  ],
                },
                initialDelaySeconds: 3,
              },
            }, std.get(params.node.resources, 'node_driver_registrar', {})),
            withResources({
              name: 'vsphere-csi-node',
              image: imageRef(params.images.driver),
              imagePullPolicy: params.node.image_pull_policy,
              args: [
                '--fss-name=%s' % params.feature_states_configmap_name,
                '--fss-namespace=$(CSI_NAMESPACE)',
              ],
              env: [
                {
                  name: 'NODE_NAME',
                  valueFrom: {
                    fieldRef: {
                      fieldPath: 'spec.nodeName',
                    },
                  },
                },
                {
                  name: 'CSI_ENDPOINT',
                  value: 'unix:///csi/csi.sock',
                },
                {
                  name: 'MAX_VOLUMES_PER_NODE',
                  value: std.toString(params.node.max_volumes_per_node),
                },
                {
                  name: 'X_CSI_MODE',
                  value: 'node',
                },
                {
                  name: 'X_CSI_SPEC_REQ_VALIDATION',
                  value: 'false',
                },
                {
                  name: 'X_CSI_SPEC_DISABLE_LEN_CHECK',
                  value: 'true',
                },
                {
                  name: 'LOGGER_LEVEL',
                  value: 'PRODUCTION',
                },
                {
                  name: 'GODEBUG',
                  value: 'x509sha1=1',
                },
                {
                  name: 'CSI_NAMESPACE',
                  valueFrom: {
                    fieldRef: {
                      fieldPath: 'metadata.namespace',
                    },
                  },
                },
                {
                  name: 'NODEGETINFO_WATCH_TIMEOUT_MINUTES',
                  value: std.toString(params.node.nodegetinfo_watch_timeout_minutes),
                },
              ],
              securityContext: {
                privileged: true,
                capabilities: {
                  add: [ 'SYS_ADMIN' ],
                },
                allowPrivilegeEscalation: true,
              },
              volumeMounts: [
                {
                  name: 'plugin-dir',
                  mountPath: '/csi',
                },
                {
                  name: 'pods-mount-dir',
                  mountPath: '/var/lib/kubelet',
                  mountPropagation: 'Bidirectional',
                },
                {
                  name: 'device-dir',
                  mountPath: '/dev',
                },
                {
                  name: 'blocks-dir',
                  mountPath: '/sys/block',
                },
                {
                  name: 'sys-devices-dir',
                  mountPath: '/sys/devices',
                },
              ],
              ports: [
                {
                  name: 'healthz',
                  containerPort: 9808,
                  protocol: 'TCP',
                },
              ],
              livenessProbe: {
                httpGet: {
                  path: '/healthz',
                  port: 'healthz',
                },
                initialDelaySeconds: 10,
                timeoutSeconds: 5,
                periodSeconds: 5,
                failureThreshold: 3,
              },
            }, std.get(params.node.resources, 'vsphere_csi_node', {})),
            withResources({
              name: 'liveness-probe',
              image: imageRef(params.images.liveness_probe),
              args: [
                '--v=4',
                '--csi-address=/csi/csi.sock',
              ],
              volumeMounts: [
                {
                  name: 'plugin-dir',
                  mountPath: '/csi',
                },
              ],
            }, std.get(params.node.resources, 'liveness_probe', {})),
          ],
          volumes: [
            {
              name: 'registration-dir',
              hostPath: {
                path: '/var/lib/kubelet/plugins_registry',
                type: 'Directory',
              },
            },
            {
              name: 'plugin-dir',
              hostPath: {
                path: '/var/lib/kubelet/plugins/%s' % params.csidriver_name,
                type: 'DirectoryOrCreate',
              },
            },
            {
              name: 'pods-mount-dir',
              hostPath: {
                path: '/var/lib/kubelet',
                type: 'Directory',
              },
            },
            {
              name: 'device-dir',
              hostPath: {
                path: '/dev',
              },
            },
            {
              name: 'blocks-dir',
              hostPath: {
                path: '/sys/block',
                type: 'Directory',
              },
            },
            {
              name: 'sys-devices-dir',
              hostPath: {
                path: '/sys/devices',
                type: 'Directory',
              },
            },
          ],
          tolerations: params.node.tolerations,
        },
      },
    },
  },
}
